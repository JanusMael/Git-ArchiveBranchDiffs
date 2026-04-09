using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using ModelContextProtocol.Server;

namespace GitArchiveMcp.Tools;

[McpServerToolType]
public static class ArchiveTools
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    [McpServerTool(Name = "git_archive_diffs"),
     Description(
        "Create a self-contained ZIP archive of all files that differ between two git refs " +
        "(branches, tags, or commits). The archive contains both sides of every changed file " +
        "organized in left/right directories, a HISTORY.md with commit log and churn summary, " +
        "and a CHANGES.patch with the unified diff. " +
        "Supports three modes: 'branch' (compare two committed refs), 'workingTree' " +
        "(uncommitted changes vs a ref), and 'staged' (indexed changes vs a ref). " +
        "Use this instead of multiple git show/git diff calls when you need to review a " +
        "complete changeset — one call captures everything. " +
        "Also ideal for session resumption: archive the base branch vs HEAD to understand " +
        "all committed changes, or use workingTree mode to also capture in-progress work. " +
        "The archive persists on disk and can be read multiple times with git_archive_read " +
        "using different file filters. Use git_archive_list to see previously created archives.")]
    public static async Task<string> CreateArchive(
        ArchiveService archiveService,
        ArchiveSession session,
        [Description("Base ref — branch, tag, or commit (e.g. 'main', 'v1.0.0')")] string leftRef,
        [Description("Feature ref — branch, tag, or commit. Omit when mode is 'workingTree' or 'staged'.")] string? rightRef = null,
        [Description("Comparison mode: 'branch' (default, requires rightRef), 'workingTree' (uncommitted changes), or 'staged' (indexed changes)")] string mode = "branch",
        [Description("Directory to write the ZIP to. Defaults to a temp directory.")] string? outputDirectory = null,
        [Description("Custom filename for the ZIP. Auto-generated if omitted.")] string? archiveFileName = null,
        CancellationToken ct = default)
    {
        var result = await archiveService.CreateArchiveAsync(
            leftRef, rightRef, mode, threeWay: false, outputDirectory, archiveFileName, ct);

        session.Add(new ArchiveRecord(
            result.ArchivePath, result.LeftRef, result.RightRef, result.ThreeWay,
            result.Mode, result.SizeBytes, result.FileCount, DateTimeOffset.UtcNow));

        return JsonSerializer.Serialize(result, JsonOptions);
    }

    [McpServerTool(Name = "git_archive_three_way"),
     Description(
        "Create a three-way diff archive showing the merge-base alongside both branches. " +
        "The archive contains base/, left/, and right/ directories so you can see what each " +
        "side changed independently. Use this when you need to understand conflicting changes " +
        "or review a merge. Like git_archive_diffs, the archive persists for iterative review " +
        "via git_archive_read.")]
    public static async Task<string> CreateThreeWayArchive(
        ArchiveService archiveService,
        ArchiveSession session,
        [Description("Base ref — branch, tag, or commit (e.g. 'main')")] string leftRef,
        [Description("Feature ref — branch, tag, or commit")] string rightRef,
        [Description("Directory to write the ZIP to. Defaults to a temp directory.")] string? outputDirectory = null,
        [Description("Custom filename for the ZIP. Auto-generated if omitted.")] string? archiveFileName = null,
        CancellationToken ct = default)
    {
        var result = await archiveService.CreateArchiveAsync(
            leftRef, rightRef, "branch", threeWay: true, outputDirectory, archiveFileName, ct);

        session.Add(new ArchiveRecord(
            result.ArchivePath, result.LeftRef, result.RightRef, result.ThreeWay,
            result.Mode, result.SizeBytes, result.FileCount, DateTimeOffset.UtcNow));

        return JsonSerializer.Serialize(result, JsonOptions);
    }

    [McpServerTool(Name = "git_archive_read"),
     Description(
        "Read and return the contents of a diff archive as structured JSON. Returns every " +
        "changed file's content from both sides, the commit history summary (HISTORY.md), and " +
        "the unified patch (CHANGES.patch) — all in one response. Files suffixed -added, " +
        "-deleted, or -R0xx are placeholders marking additions, deletions, and renames. " +
        "You can call this repeatedly on the same archive with different fileFilter patterns " +
        "to drill into specific areas of a changeset without recreating the archive. " +
        "Particularly efficient for session resumption — reading one archive gives you the " +
        "complete picture of a branch's changes instead of dozens of individual git commands. " +
        "Use git_archive_list to find archives from earlier in this session.")]
    public static string ReadArchive(
        ArchiveService archiveService,
        [Description("Path to the ZIP archive (from git_archive_diffs, git_archive_list, or any path)")] string archivePath,
        [Description("Include file text contents (true) or just the file tree (false). Defaults to true.")] bool includeContents = true,
        [Description("Glob pattern to filter files (e.g. '*.cs', 'src/**'). Omit to include all files.")] string? fileFilter = null)
    {
        var result = archiveService.ReadArchive(archivePath, includeContents, fileFilter);
        return JsonSerializer.Serialize(result, JsonOptions);
    }

    [McpServerTool(Name = "git_archive_list"),
     Description(
        "List all diff archives created during this session. Returns the path, creation time, " +
        "refs compared, and file count for each archive. Check here first when resuming work " +
        "or starting a new task on a branch — a prior invocation may have already created an " +
        "archive, saving you from recreating it. Pass the archivePath to git_archive_read to " +
        "review its contents.")]
    public static string ListArchives(ArchiveSession session)
    {
        return JsonSerializer.Serialize(session.List(), JsonOptions);
    }
}
