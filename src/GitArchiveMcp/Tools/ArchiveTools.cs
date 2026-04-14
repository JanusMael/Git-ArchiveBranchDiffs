using System.ComponentModel;
using System.Text.Json;
using ModelContextProtocol.Server;

namespace GitArchiveMcp.Tools;

[McpServerToolType]
public static class ArchiveTools
{
    private static readonly JsonSerializerOptions JsonOptions = JsonDefaults.Options;

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
        "using different file filters. Use git_archive_list to see previously created archives. " +
        "Archive filenames include a version stamp and short commit hashes so re-running after " +
        "new commits creates a distinct file instead of overwriting. Use git_archive_compare to " +
        "diff two snapshots of the same branch comparison.")]
    public static async Task<string> CreateArchive(
        ArchiveService archiveService,
        ArchiveSession session,
        [Description("Base ref — branch, tag, or commit (e.g. 'main', 'v1.0.0')")] string leftRef,
        [Description("Feature ref — branch, tag, or commit. Omit when mode is 'workingTree' or 'staged'.")] string? rightRef = null,
        [Description("Comparison mode: 'branch' (default, requires rightRef), 'workingTree' (uncommitted changes), or 'staged' (indexed changes)")] string mode = "branch",
        [Description("Directory to write the ZIP to. Defaults to a temp directory.")] string? outputDirectory = null,
        [Description("Custom filename for the ZIP. Auto-generated with version stamp and commit hashes if omitted.")] string? archiveFileName = null,
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
        "via git_archive_read. " +
        "Archive filenames include a version stamp and short commit hashes so re-running after " +
        "new commits creates a distinct file instead of overwriting.")]
    public static async Task<string> CreateThreeWayArchive(
        ArchiveService archiveService,
        ArchiveSession session,
        [Description("Base ref — branch, tag, or commit (e.g. 'main')")] string leftRef,
        [Description("Feature ref — branch, tag, or commit")] string rightRef,
        [Description("Directory to write the ZIP to. Defaults to a temp directory.")] string? outputDirectory = null,
        [Description("Custom filename for the ZIP. Auto-generated with version stamp and commit hashes if omitted.")] string? archiveFileName = null,
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

    [McpServerTool(Name = "git_archive_summary"),
     Description(
        "Get a quick overview of a diff archive without reading file contents. Returns total " +
        "file count, lines added/removed, change type breakdown (additions, deletions, " +
        "modifications, renames), top directories by file count, and binary file count. " +
        "Use this as a first step after creating an archive to understand the scope and decide " +
        "which areas to drill into with git_archive_search or git_archive_diff_file. Much " +
        "faster than git_archive_read for initial triage — especially on archives with " +
        "hundreds of files.")]
    public static string GetSummary(
        ArchiveService archiveService,
        [Description("Path to the ZIP archive")] string archivePath)
    {
        var result = archiveService.GetSummary(archivePath);
        return JsonSerializer.Serialize(result, JsonOptions);
    }

    [McpServerTool(Name = "git_archive_diff_file"),
     Description(
        "Examine a single file from a diff archive in detail. Given a file path (e.g. " +
        "'src/App.cs'), returns both the left (base) and right (feature) versions side-by-side, " +
        "plus the relevant unified diff hunk from CHANGES.patch. Use this after " +
        "git_archive_summary or git_archive_search to drill into a specific file without " +
        "loading the entire archive. The path should be the logical file path within the " +
        "repository (without the branch directory prefix). Returns the change type (added, " +
        "deleted, modified, renamed) and both versions' content.")]
    public static string GetDiffFile(
        ArchiveService archiveService,
        [Description("Path to the ZIP archive")] string archivePath,
        [Description("Logical file path within the repo (e.g. 'src/App.cs'), without branch directory prefix")] string filePath)
    {
        var result = archiveService.GetDiffFile(archivePath, filePath);
        return JsonSerializer.Serialize(result, JsonOptions);
    }

    [McpServerTool(Name = "git_archive_search"),
     Description(
        "Search for a pattern across all files in a diff archive. Returns matching lines with " +
        "file path, line number, and surrounding context lines. Searches both left and right " +
        "versions of files, skipping binary files and placeholder files. Use this to find " +
        "where a function is called, locate TODO/FIXME comments, check for debug code, or " +
        "trace how a pattern appears across the changeset. Supports regex patterns and result " +
        "limiting. Pair with git_archive_diff_file to examine matches in full context.")]
    public static string SearchArchive(
        ArchiveService archiveService,
        [Description("Path to the ZIP archive")] string archivePath,
        [Description("Regex pattern to search for (e.g. 'TODO|FIXME', 'console\\.log')")] string pattern,
        [Description("Number of context lines before and after each match. Defaults to 2.")] int contextLines = 2,
        [Description("Maximum number of matches to return. Defaults to 50.")] int maxResults = 50,
        [Description("Optional glob pattern to filter which files to search (e.g. '*.cs')")] string? fileFilter = null)
    {
        var result = archiveService.SearchArchive(archivePath, pattern, contextLines, maxResults, fileFilter);
        return JsonSerializer.Serialize(result, JsonOptions);
    }

    [McpServerTool(Name = "git_archive_annotate"),
     Description(
        "Attach or read notes on a diff archive to track your review progress. Add annotations " +
        "like 'status=reviewed', 'issues=3', or 'notes=auth flow needs rework' to help you " +
        "remember where you left off. Annotations persist for the session and appear in " +
        "git_archive_list output. Use this to track which archives you have reviewed, flag " +
        "issues found, or leave notes for follow-up. Call with just archivePath to read " +
        "existing annotations, or with key and value to add/update one.")]
    public static string Annotate(
        ArchiveSession session,
        [Description("Path to the ZIP archive to annotate")] string archivePath,
        [Description("Annotation key (e.g. 'status', 'issues', 'notes'). Omit to read all annotations.")] string? key = null,
        [Description("Annotation value (e.g. 'reviewed', '3', 'auth flow needs rework')")] string? value = null)
    {
        if (key is not null && value is not null)
            session.Annotate(archivePath, key, value);

        var annotations = session.GetAnnotations(archivePath);
        var result = new ArchiveAnnotations(archivePath, annotations);
        return JsonSerializer.Serialize(result, JsonOptions);
    }

    [McpServerTool(Name = "git_archive_compare"),
     Description(
        "Compare two diff archives to see what changed between them. Useful for incremental " +
        "code review: if you reviewed an archive earlier and the developer has pushed more " +
        "commits, create a new archive and compare it to the old one to see only the " +
        "new/changed files. Returns lists of files that were added, removed, changed, or " +
        "unchanged between the two archives. This saves you from re-reviewing the entire " +
        "changeset when only a few files have been updated.")]
    public static string CompareArchives(
        ArchiveService archiveService,
        [Description("Path to the older/previous archive")] string olderArchivePath,
        [Description("Path to the newer/current archive")] string newerArchivePath)
    {
        var result = archiveService.CompareArchives(olderArchivePath, newerArchivePath);
        return JsonSerializer.Serialize(result, JsonOptions);
    }

    [McpServerTool(Name = "git_archive_apply_patch"),
     Description(
        "Apply the unified diff (CHANGES.patch) from a diff archive to the current working " +
        "tree using git apply --3way. Use this to replay a changeset onto your branch — for " +
        "example, to apply changes from a review archive or port fixes between branches. " +
        "WARNING: This modifies your working tree. Returns the result including any conflicts " +
        "or rejected hunks. The --3way flag enables merge conflict markers for hunks that " +
        "don't apply cleanly, so you can resolve them manually.")]
    public static async Task<string> ApplyPatch(
        ArchiveService archiveService,
        [Description("Path to the ZIP archive containing CHANGES.patch")] string archivePath,
        CancellationToken ct = default)
    {
        var result = await archiveService.ApplyPatchAsync(archivePath, ct);
        return JsonSerializer.Serialize(result, JsonOptions);
    }
}
