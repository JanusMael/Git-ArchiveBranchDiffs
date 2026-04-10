using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace GitArchiveMcp;

public sealed partial class ArchiveService
{
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(120);
    private readonly string _scriptDirectory;
    private readonly bool _pwshAvailable;

    public ArchiveService()
    {
        _scriptDirectory = ResolveScriptDirectory();
        _pwshAvailable = CheckPwsh();
    }

    public async Task<ArchiveResult> CreateArchiveAsync(
        string leftRef,
        string? rightRef,
        string mode,
        bool threeWay,
        string? outputDirectory,
        string? archiveFileName,
        CancellationToken ct = default)
    {
        ValidateRef(leftRef, nameof(leftRef));
        if (rightRef is not null)
            ValidateRef(rightRef, nameof(rightRef));

        outputDirectory ??= Path.Combine(Path.GetTempPath(), "GitArchiveMcp", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(outputDirectory);

        ValidatePath(outputDirectory);

        var scriptArgs = new List<string>
        {
            "-nonInteractive",
            "-leftBranch", leftRef,
            "-outputDirectory", outputDirectory
        };

        if (archiveFileName is not null)
        {
            scriptArgs.Add("-archiveFileName");
            scriptArgs.Add(archiveFileName);
        }

        switch (mode)
        {
            case "workingTree":
                scriptArgs.Add("-workingTree");
                break;
            case "staged":
                scriptArgs.Add("-staged");
                break;
            default:
                if (rightRef is null)
                    throw new ArgumentException("rightRef is required when mode is 'branch'");
                scriptArgs.Add("-rightBranch");
                scriptArgs.Add(rightRef);
                break;
        }

        if (threeWay)
            scriptArgs.Add("-threeWay");

        var (command, args) = BuildInvocation([.. scriptArgs]);
        var result = await RunProcessAsync(command, args, ct);

        if (result.ExitCode != 0)
            throw new InvalidOperationException(
                $"Archive creation failed (exit code {result.ExitCode}):\n{result.StandardError}");

        // Find the created ZIP in the output directory
        var zipFiles = Directory.GetFiles(outputDirectory, "*.zip");
        if (zipFiles.Length == 0)
            throw new InvalidOperationException(
                $"No ZIP file found in output directory after archive creation.\nStdout: {result.StandardOutput}\nStderr: {result.StandardError}");

        var zipPath = zipFiles[0];
        var fileInfo = new FileInfo(zipPath);

        int fileCount;
        using (var zip = ZipFile.OpenRead(zipPath))
            fileCount = zip.Entries.Count;

        return new ArchiveResult(
            zipPath,
            leftRef,
            rightRef ?? (mode == "workingTree" ? "WORKING-TREE" : "STAGED"),
            mode,
            threeWay,
            fileInfo.Length,
            fileCount);
    }

    public ArchiveReadResult ReadArchive(
        string archivePath,
        bool includeContents,
        string? fileFilter)
    {
        ValidatePath(archivePath);

        if (!File.Exists(archivePath))
            throw new FileNotFoundException($"Archive not found: {archivePath}");

        var directories = new HashSet<string>();
        var files = new List<ArchiveFileEntry>();
        string? history = null;
        string? patch = null;

        using var zip = ZipFile.OpenRead(archivePath);

        foreach (var entry in zip.Entries)
        {
            // Zip-slip protection
            if (entry.FullName.Contains("..") || Path.IsPathRooted(entry.FullName))
                continue;

            // Track directories
            var dir = Path.GetDirectoryName(entry.FullName)?.Replace('\\', '/');
            if (!string.IsNullOrEmpty(dir))
                directories.Add(dir + "/");

            // Skip directories (entries ending with /)
            if (string.IsNullOrEmpty(entry.Name))
                continue;

            // Apply file filter
            if (fileFilter is not null && !MatchesGlob(entry.FullName, fileFilter))
            {
                // Always include HISTORY.md and CHANGES.patch regardless of filter
                if (entry.Name is not "HISTORY.md" and not "CHANGES.patch")
                    continue;
            }

            // Extract HISTORY.md and CHANGES.patch as top-level fields
            if (entry.Name == "HISTORY.md" && !entry.FullName.Contains('/'))
            {
                using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
                history = reader.ReadToEnd();
                continue;
            }

            if (entry.Name == "CHANGES.patch" && !entry.FullName.Contains('/'))
            {
                using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
                patch = reader.ReadToEnd();
                continue;
            }

            var isPlaceholder = IsPlaceholderFile(entry.Name);

            string? content = null;
            if (includeContents && !isPlaceholder && entry.Length > 0)
            {
                if (entry.Length > 100 * 1024)
                {
                    content = "[truncated — file exceeds 100KB]";
                }
                else if (IsBinaryEntry(entry))
                {
                    content = "[binary file]";
                }
                else
                {
                    using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
                    content = reader.ReadToEnd();
                }
            }

            files.Add(new ArchiveFileEntry(
                entry.FullName.Replace('\\', '/'),
                entry.Length,
                isPlaceholder,
                content));
        }

        return new ArchiveReadResult(
            archivePath,
            [.. directories.OrderBy(d => d)],
            files,
            history,
            patch);
    }

    private static bool IsPlaceholderFile(string fileName)
    {
        return fileName.EndsWith("-added", StringComparison.Ordinal)
            || fileName.EndsWith("-deleted", StringComparison.Ordinal)
            || PlaceholderRenamePattern().IsMatch(fileName);
    }

    [GeneratedRegex(@"-[RC]\d{3}$")]
    private static partial Regex PlaceholderRenamePattern();

    private static bool IsBinaryEntry(ZipArchiveEntry entry)
    {
        using var stream = entry.Open();
        var buffer = new byte[Math.Min(8192, entry.Length)];
        var bytesRead = stream.Read(buffer, 0, buffer.Length);
        return buffer.AsSpan(0, bytesRead).Contains((byte)0);
    }

    private static bool MatchesGlob(string path, string pattern)
    {
        // Simple glob: * matches anything within a segment, ** matches across segments
        var regexPattern = "^" + Regex.Escape(pattern)
            .Replace("\\*\\*", ".*")
            .Replace("\\*", "[^/]*")
            .Replace("\\?", "[^/]") + "$";
        return Regex.IsMatch(path, regexPattern, RegexOptions.IgnoreCase);
    }

    private (string command, string[] args) BuildInvocation(string[] scriptArgs)
    {
        if (_pwshAvailable)
        {
            var ps1Path = Path.Combine(_scriptDirectory, "Git-ArchiveBranchDiffs.ps1");
            return ("pwsh", [ps1Path, .. scriptArgs]);
        }

        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            var shPath = Path.Combine(_scriptDirectory, "Git-ArchiveBranchDiffs.sh");
            return ("bash", [shPath, .. scriptArgs]);
        }

        throw new InvalidOperationException(
            "pwsh (PowerShell Core) is required but not found on PATH. " +
            "Install from https://github.com/PowerShell/PowerShell");
    }

    private static async Task<ProcessResult> RunProcessAsync(
        string command, string[] args, CancellationToken ct)
    {
        var timeout = TimeSpan.FromSeconds(
            int.TryParse(Environment.GetEnvironmentVariable("GITMCP_TIMEOUT_SECONDS"), out var t) ? t : (int)DefaultTimeout.TotalSeconds);

        var psi = new ProcessStartInfo
        {
            FileName = command,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        foreach (var arg in args)
            psi.ArgumentList.Add(arg);

        using var process = Process.Start(psi)
            ?? throw new InvalidOperationException($"Failed to start process: {command}");

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);

        var stdoutTask = process.StandardOutput.ReadToEndAsync(cts.Token);
        var stderrTask = process.StandardError.ReadToEndAsync(cts.Token);

        await process.WaitForExitAsync(cts.Token);

        return new ProcessResult(
            process.ExitCode,
            await stdoutTask,
            await stderrTask);
    }

    private static void ValidateRef(string refName, string paramName)
    {
        if (string.IsNullOrWhiteSpace(refName))
            throw new ArgumentException("Ref name cannot be empty", paramName);

        if (!SafeRefPattern().IsMatch(refName))
            throw new ArgumentException(
                $"Invalid ref name: '{refName}'. Only alphanumeric characters, /, ., -, _, ~, ^, @, {{, }}, and : are allowed.",
                paramName);
    }

    [GeneratedRegex(@"^[a-zA-Z0-9/_.\-~^@{}:]+$")]
    private static partial Regex SafeRefPattern();

    private static void ValidatePath(string path)
    {
        if (path.Contains(".."))
            throw new ArgumentException($"Path traversal not allowed: {path}");
    }

    private static string ResolveScriptDirectory()
    {
        // 1. Environment variable override
        var envPath = Environment.GetEnvironmentVariable("GITMCP_SCRIPT_PATH");
        if (!string.IsNullOrEmpty(envPath))
        {
            if (File.Exists(envPath))
                return Path.GetDirectoryName(envPath)!;
            if (Directory.Exists(envPath) && File.Exists(Path.Combine(envPath, "Git-ArchiveBranchDiffs.ps1")))
                return envPath;
        }

        // 2. Same directory as the executable
        var assemblyDir = AppContext.BaseDirectory;
        if (File.Exists(Path.Combine(assemblyDir, "Git-ArchiveBranchDiffs.ps1")))
            return assemblyDir;

        // 3. Walk up from the executable to find the script
        var dir = assemblyDir;
        for (var i = 0; i < 10; i++)
        {
            var parent = Directory.GetParent(dir);
            if (parent is null) break;
            dir = parent.FullName;
            if (File.Exists(Path.Combine(dir, "Git-ArchiveBranchDiffs.ps1")))
                return dir;
        }

        throw new FileNotFoundException(
            "Could not find Git-ArchiveBranchDiffs.ps1. " +
            "Set GITMCP_SCRIPT_PATH environment variable to the script location.");
    }

    private static bool CheckPwsh()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "pwsh",
                ArgumentList = { "--version" },
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var process = Process.Start(psi);
            process?.WaitForExit(5000);
            return process?.ExitCode == 0;
        }
        catch
        {
            return false;
        }
    }

    public ArchiveSummary GetSummary(string archivePath)
    {
        ValidatePath(archivePath);

        if (!File.Exists(archivePath))
            throw new FileNotFoundException($"Archive not found: {archivePath}");

        int filesAdded = 0, filesDeleted = 0, filesModified = 0, filesRenamed = 0, binaryFiles = 0;
        int linesAdded = 0, linesRemoved = 0;
        var dirCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var fileEntries = new HashSet<string>();

        using var zip = ZipFile.OpenRead(archivePath);

        // Discover the top-level directory names (branch directories)
        var topDirs = new HashSet<string>();
        foreach (var entry in zip.Entries)
        {
            if (entry.FullName.Contains("..") || Path.IsPathRooted(entry.FullName))
                continue;
            var slash = entry.FullName.IndexOf('/');
            if (slash > 0)
                topDirs.Add(entry.FullName[..slash]);
        }

        // Remove known non-branch directories
        topDirs.Remove("manifest");

        foreach (var entry in zip.Entries)
        {
            if (string.IsNullOrEmpty(entry.Name))
                continue;
            if (entry.FullName.Contains("..") || Path.IsPathRooted(entry.FullName))
                continue;

            // Parse CHANGES.patch for line counts
            if (entry.Name == "CHANGES.patch" && !entry.FullName.Contains('/'))
            {
                using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
                string? line;
                while ((line = reader.ReadLine()) is not null)
                {
                    if (line.StartsWith('+') && !line.StartsWith("+++"))
                        linesAdded++;
                    else if (line.StartsWith('-') && !line.StartsWith("---"))
                        linesRemoved++;
                }
                continue;
            }

            // Skip manifest and top-level metadata files
            if (entry.FullName.StartsWith("manifest/") || !entry.FullName.Contains('/'))
                continue;

            // Track directory stats from the right/feature side only (avoid double-counting)
            var slash = entry.FullName.IndexOf('/');
            if (slash < 0) continue;
            var topDir = entry.FullName[..slash];

            // Use the second top-level directory as the "right" side for counting
            // (or first if only one exists, e.g. base/ in three-way)
            var sortedDirs = topDirs.OrderBy(d => d).ToList();
            var rightDir = sortedDirs.Count > 1 ? sortedDirs[^1] : sortedDirs.FirstOrDefault();

            if (!string.Equals(topDir, rightDir, StringComparison.OrdinalIgnoreCase))
                continue;

            // Get relative path (after branch directory)
            var relativePath = entry.FullName[(slash + 1)..];
            if (string.IsNullOrEmpty(relativePath))
                continue;

            fileEntries.Add(relativePath);

            // Classify change type
            if (IsPlaceholderFile(entry.Name))
            {
                if (entry.Name.EndsWith("-deleted", StringComparison.Ordinal))
                    filesDeleted++;
                else if (PlaceholderRenamePattern().IsMatch(entry.Name))
                    filesRenamed++;
                // -added placeholders on right side don't happen (the real file is there)
            }
            else
            {
                // Check if corresponding left-side placeholder exists
                var leftPath = sortedDirs.Count > 1 ? sortedDirs[0] + "/" + relativePath : null;
                var leftEntry = leftPath is not null ? zip.GetEntry(leftPath) : null;
                var leftPlaceholder = leftPath is not null
                    ? zip.GetEntry(leftPath + "-added")
                    : null;

                if (leftPlaceholder is not null)
                    filesAdded++;
                else
                    filesModified++;

                // Check if binary
                if (entry.Length > 0 && IsBinaryEntry(entry))
                    binaryFiles++;
            }

            // Track directory stats
            var dirSlash = relativePath.IndexOf('/');
            var dir = dirSlash > 0 ? relativePath[..dirSlash] : "(root)";
            dirCounts[dir] = dirCounts.GetValueOrDefault(dir) + 1;
        }

        var topDirectories = dirCounts
            .OrderByDescending(kv => kv.Value)
            .Take(10)
            .Select(kv => new DirectoryStat(kv.Key, kv.Value))
            .ToList();

        return new ArchiveSummary(
            archivePath,
            fileEntries.Count,
            linesAdded,
            linesRemoved,
            filesAdded,
            filesDeleted,
            filesModified,
            filesRenamed,
            binaryFiles,
            topDirectories);
    }

    public FileDiffResult GetDiffFile(string archivePath, string filePath)
    {
        ValidatePath(archivePath);
        ValidatePath(filePath);

        if (!File.Exists(archivePath))
            throw new FileNotFoundException($"Archive not found: {archivePath}");

        // Normalize path separators
        filePath = filePath.Replace('\\', '/').TrimStart('/');

        using var zip = ZipFile.OpenRead(archivePath);

        // Discover branch directories
        var topDirs = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in zip.Entries)
        {
            if (entry.FullName.Contains("..") || Path.IsPathRooted(entry.FullName))
                continue;
            var slash = entry.FullName.IndexOf('/');
            if (slash > 0)
            {
                var dir = entry.FullName[..slash];
                if (dir is not "manifest")
                    topDirs.Add(dir);
            }
        }

        // In three-way archives, skip "base" — use first and last as left/right
        var dirs = topDirs.Where(d => !d.Equals("base", StringComparison.OrdinalIgnoreCase)).ToList();
        if (dirs.Count < 2 && topDirs.Count >= 2)
            dirs = [.. topDirs]; // fallback to all

        var leftDir = dirs.Count > 0 ? dirs[0] : null;
        var rightDir = dirs.Count > 1 ? dirs[^1] : leftDir;

        // Find left and right entries
        FileVersion? leftVersion = null;
        FileVersion? rightVersion = null;
        string changeType = "modified";

        if (leftDir is not null)
        {
            var leftEntry = zip.GetEntry($"{leftDir}/{filePath}");
            var leftPlaceholder = zip.GetEntry($"{leftDir}/{filePath}-added");
            var leftRenamed = FindRenamedEntry(zip, leftDir, filePath);

            if (leftPlaceholder is not null)
            {
                changeType = "added";
            }
            else if (leftEntry is not null)
            {
                leftVersion = ReadFileVersion(leftEntry);
            }
            else if (leftRenamed is not null)
            {
                changeType = "renamed";
                leftVersion = ReadFileVersion(leftRenamed);
            }
        }

        if (rightDir is not null)
        {
            var rightEntry = zip.GetEntry($"{rightDir}/{filePath}");
            var rightPlaceholder = zip.GetEntry($"{rightDir}/{filePath}-deleted");

            if (rightPlaceholder is not null)
            {
                changeType = "deleted";
            }
            else if (rightEntry is not null)
            {
                rightVersion = ReadFileVersion(rightEntry);
            }
        }

        // Extract diff hunk from CHANGES.patch
        string? diffHunk = null;
        var patchEntry = zip.GetEntry("CHANGES.patch");
        if (patchEntry is not null)
        {
            using var reader = new StreamReader(patchEntry.Open(), Encoding.UTF8);
            diffHunk = ExtractDiffHunk(reader, filePath);
        }

        return new FileDiffResult(filePath, changeType, leftVersion, rightVersion, diffHunk);
    }

    public SearchResult SearchArchive(
        string archivePath, string pattern, int contextLines, int maxResults, string? fileFilter)
    {
        ValidatePath(archivePath);

        if (!File.Exists(archivePath))
            throw new FileNotFoundException($"Archive not found: {archivePath}");

        var regex = new Regex(pattern, RegexOptions.IgnoreCase, TimeSpan.FromSeconds(5));
        var matches = new List<SearchMatch>();
        int totalMatches = 0;

        using var zip = ZipFile.OpenRead(archivePath);

        foreach (var entry in zip.Entries)
        {
            if (string.IsNullOrEmpty(entry.Name))
                continue;
            if (entry.FullName.Contains("..") || Path.IsPathRooted(entry.FullName))
                continue;
            if (entry.FullName.StartsWith("manifest/"))
                continue;
            if (IsPlaceholderFile(entry.Name))
                continue;
            if (entry.Length == 0 || entry.Length > 100 * 1024)
                continue;

            var entryPath = entry.FullName.Replace('\\', '/');

            if (fileFilter is not null && !MatchesGlob(entryPath, fileFilter))
                continue;

            if (IsBinaryEntry(entry))
                continue;

            // Read all lines
            List<string> lines;
            using (var reader = new StreamReader(entry.Open(), Encoding.UTF8))
            {
                lines = [];
                string? line;
                while ((line = reader.ReadLine()) is not null)
                    lines.Add(line);
            }

            for (int i = 0; i < lines.Count; i++)
            {
                if (!regex.IsMatch(lines[i]))
                    continue;

                totalMatches++;

                if (matches.Count < maxResults)
                {
                    var contextStart = Math.Max(0, i - contextLines);
                    var contextEnd = Math.Min(lines.Count - 1, i + contextLines);
                    var context = new List<string>();
                    for (int c = contextStart; c <= contextEnd; c++)
                    {
                        if (c != i)
                            context.Add($"{c + 1}: {lines[c]}");
                    }

                    matches.Add(new SearchMatch(entryPath, i + 1, lines[i], context));
                }
            }
        }

        return new SearchResult(archivePath, pattern, totalMatches, matches);
    }

    public ArchiveComparison CompareArchives(string olderPath, string newerPath)
    {
        ValidatePath(olderPath);
        ValidatePath(newerPath);

        if (!File.Exists(olderPath))
            throw new FileNotFoundException($"Archive not found: {olderPath}");
        if (!File.Exists(newerPath))
            throw new FileNotFoundException($"Archive not found: {newerPath}");

        var olderFiles = GetFileChecksums(olderPath);
        var newerFiles = GetFileChecksums(newerPath);

        var added = newerFiles.Keys.Except(olderFiles.Keys).Order().ToList();
        var removed = olderFiles.Keys.Except(newerFiles.Keys).Order().ToList();
        var changed = new List<string>();
        var unchanged = new List<string>();

        foreach (var path in olderFiles.Keys.Intersect(newerFiles.Keys).Order())
        {
            if (olderFiles[path] == newerFiles[path])
                unchanged.Add(path);
            else
                changed.Add(path);
        }

        return new ArchiveComparison(olderPath, newerPath, added, removed, changed, unchanged);
    }

    public async Task<PatchApplyResult> ApplyPatchAsync(string archivePath, CancellationToken ct = default)
    {
        ValidatePath(archivePath);

        if (!File.Exists(archivePath))
            throw new FileNotFoundException($"Archive not found: {archivePath}");

        // Extract CHANGES.patch to a temp file
        string? patchContent = null;
        using (var zip = ZipFile.OpenRead(archivePath))
        {
            var patchEntry = zip.GetEntry("CHANGES.patch");
            if (patchEntry is null)
                throw new InvalidOperationException("Archive does not contain CHANGES.patch");

            using var reader = new StreamReader(patchEntry.Open(), Encoding.UTF8);
            patchContent = await reader.ReadToEndAsync(ct);
        }

        var tempPatch = Path.Combine(Path.GetTempPath(), $"GitArchiveMcp-{Guid.NewGuid():N}.patch");
        try
        {
            await File.WriteAllTextAsync(tempPatch, patchContent, ct);
            var result = await RunProcessAsync("git", ["apply", "--3way", tempPatch], ct);

            return new PatchApplyResult(
                result.ExitCode == 0,
                result.ExitCode,
                result.StandardOutput,
                result.StandardError);
        }
        finally
        {
            try { File.Delete(tempPatch); } catch { /* best effort */ }
        }
    }

    private static FileVersion? ReadFileVersion(ZipArchiveEntry entry)
    {
        if (entry.Length > 100 * 1024)
            return new FileVersion(entry.FullName.Replace('\\', '/'), entry.Length, "[truncated — file exceeds 100KB]");

        if (IsBinaryEntry(entry))
            return new FileVersion(entry.FullName.Replace('\\', '/'), entry.Length, "[binary file]");

        using var reader = new StreamReader(entry.Open(), Encoding.UTF8);
        return new FileVersion(entry.FullName.Replace('\\', '/'), entry.Length, reader.ReadToEnd());
    }

    private static ZipArchiveEntry? FindRenamedEntry(ZipArchive zip, string dir, string filePath)
    {
        var prefix = $"{dir}/{filePath}-R";
        return zip.Entries.FirstOrDefault(e =>
            e.FullName.StartsWith(prefix, StringComparison.Ordinal)
            && PlaceholderRenamePattern().IsMatch(e.Name));
    }

    private static string? ExtractDiffHunk(StreamReader reader, string filePath)
    {
        var sb = new StringBuilder();
        bool inTargetDiff = false;
        string? line;

        while ((line = reader.ReadLine()) is not null)
        {
            if (line.StartsWith("diff --git ", StringComparison.Ordinal))
            {
                if (inTargetDiff)
                    break; // hit next file's diff

                // Check if this diff block is for our file
                if (line.Contains($"a/{filePath}") || line.Contains($"b/{filePath}"))
                {
                    inTargetDiff = true;
                    sb.AppendLine(line);
                }
                continue;
            }

            if (inTargetDiff)
                sb.AppendLine(line);
        }

        return sb.Length > 0 ? sb.ToString().TrimEnd() : null;
    }

    private static Dictionary<string, long> GetFileChecksums(string archivePath)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        using var zip = ZipFile.OpenRead(archivePath);

        foreach (var entry in zip.Entries)
        {
            if (string.IsNullOrEmpty(entry.Name))
                continue;
            if (entry.FullName.Contains("..") || Path.IsPathRooted(entry.FullName))
                continue;
            if (entry.FullName.StartsWith("manifest/"))
                continue;

            // Strip the branch directory prefix to get the logical path
            var slash = entry.FullName.IndexOf('/');
            if (slash < 0) continue;
            var relativePath = entry.FullName[(slash + 1)..];
            if (string.IsNullOrEmpty(relativePath)) continue;

            result[relativePath] = $"{entry.Length}:{entry.Crc32}";
        }

        // Return as long-keyed dict for the comparison (reuse the string composite)
        return result.ToDictionary(kv => kv.Key, kv => (long)kv.Value.GetHashCode());
    }

    private record ProcessResult(int ExitCode, string StandardOutput, string StandardError);
}

public record ArchiveResult(
    string ArchivePath,
    string LeftRef,
    string RightRef,
    string Mode,
    bool ThreeWay,
    long SizeBytes,
    int FileCount);

public record ArchiveReadResult(
    string ArchivePath,
    IReadOnlyList<string> Directories,
    IReadOnlyList<ArchiveFileEntry> Files,
    string? History,
    string? Patch);

public record ArchiveFileEntry(
    string Path,
    long SizeBytes,
    bool IsPlaceholder,
    string? Content);

public record ArchiveSummary(
    string ArchivePath,
    int FileCount,
    int LinesAdded,
    int LinesRemoved,
    int FilesAdded,
    int FilesDeleted,
    int FilesModified,
    int FilesRenamed,
    int BinaryFiles,
    IReadOnlyList<DirectoryStat> TopDirectories);

public record DirectoryStat(string Directory, int FileCount);

public record FileDiffResult(
    string Path,
    string ChangeType,
    FileVersion? Left,
    FileVersion? Right,
    string? Diff);

public record FileVersion(string Path, long SizeBytes, string? Content);

public record SearchResult(
    string ArchivePath,
    string Pattern,
    int TotalMatches,
    IReadOnlyList<SearchMatch> Matches);

public record SearchMatch(
    string FilePath,
    int LineNumber,
    string Line,
    IReadOnlyList<string> Context);

public record ArchiveComparison(
    string OlderArchive,
    string NewerArchive,
    IReadOnlyList<string> AddedFiles,
    IReadOnlyList<string> RemovedFiles,
    IReadOnlyList<string> ChangedFiles,
    IReadOnlyList<string> UnchangedFiles);

public record PatchApplyResult(
    bool Success,
    int ExitCode,
    string StandardOutput,
    string StandardError);

public record ArchiveAnnotations(
    string ArchivePath,
    IReadOnlyDictionary<string, string> Annotations);
