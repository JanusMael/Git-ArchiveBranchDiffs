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
