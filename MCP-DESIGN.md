# Plan: C# MCP Server — Git Archive Branch Diffs

## Context

AI agents need to create and consume branch diff archives to review changesets in isolation. Other git operations (log, status, blame, etc.) are already covered by existing git MCPs — this server only exposes the archive creation and consumption workflow.

The server must work on **Windows, Linux, and macOS**. The existing repository already has cross-platform support: `Git-ArchiveBranchDiffs.ps1` (PowerShell) and `Git-ArchiveBranchDiffs.sh` (bash wrapper that auto-installs `pwsh` on Linux/macOS if missing).

This plan document will live in the repository as `MCP-DESIGN.md` alongside the implementation.

---

## Scope: 10 Tools + 7 Prompts + Resources

### Creation & bulk consumption

| Tool | Description |
|---|---|
| `git_archive_diffs` | Create a ZIP archive of files that differ between two refs (supports `branch`, `workingTree`, and `staged` modes) |
| `git_archive_three_way` | Create a three-way ZIP archive (base + left + right) |
| `git_archive_read` | Return the contents of an archive as structured JSON |
| `git_archive_list` | List all archives created in the current session, including annotations |

### Analysis (zoom-in workflow)

Large changesets defeat naive "read everything" reviews. These tools let an AI triage, search, and drill into an archive efficiently — avoiding the context flood of `git_archive_read` on 200-file branches.

| Tool | Description |
|---|---|
| `git_archive_summary` | Lightweight scope overview — file counts, line totals, change type breakdown, top directories, binary count. First call after creating an archive. |
| `git_archive_search` | Regex search across every file in the archive, with configurable context lines, result limits, and glob filter. |
| `git_archive_diff_file` | Examine one file in detail — returns both sides plus the unified diff hunk from CHANGES.patch. |
| `git_archive_compare` | Compare two archives to see what changed between reviews (added / removed / changed / unchanged). |
| `git_archive_annotate` | Attach notes to an archive (`status=reviewed`, `issues=3`, free-form `notes=...`) that persist across calls and appear in `git_archive_list`. |
| `git_archive_apply_patch` | Replay CHANGES.patch onto the working tree using `git apply --3way`. WARNING: mutates the working tree. |

### Resources

Every archive created during the session is also exposed as an MCP resource under the `archive:///` URI scheme. Reading a resource returns the `git_archive_summary` output (plus metadata and annotations) as JSON — **not** the full contents, to stay lightweight. Clients that subscribe receive `notifications/resources/list_changed` when new archives are created, so the archive list stays live without polling. For full contents, clients should call `git_archive_read`.

---

## Why This Tool (vs Raw Git Exploration)

The tool descriptions should convey these advantages so AI agents understand when to reach for archive tools vs ad-hoc git commands:

1. **One call for the whole changeset** — A 50-file diff requires 100+ `git show` calls to get both sides. `git_archive_diffs` + `git_archive_read` does it in 2 calls.

2. **Pre-built review document** — HISTORY.md includes churn summary (top files by insertions+deletions), per-commit file breakdowns, and contributor info. Assembling this from raw git requires `git log`, `git diff --stat`, `git shortlog`, and `git diff-tree` per commit.

3. **CHANGES.patch included** — The unified diff for the entire changeset is ready to read or apply, without constructing the right `git diff` invocation.

4. **Snapshot isolation** — The archive is frozen at creation time. The branch can move, rebase, or be deleted — the archive remains valid. Raw git exploration is live and can shift during a long analysis.

5. **Iterative review** — Create the archive once, then call `git_archive_read` repeatedly with different `fileFilter` patterns as you drill into different areas. Use `git_archive_list` to see what you've already created. The archive persists across tool calls — no need to recreate it.

6. **Session resumption** — When resuming work on a branch (new session, context recovery, or picking up another agent's work), create an archive between the base branch and HEAD to get the complete picture of all committed changes — every modified file, the full commit history with per-commit file lists, and the unified patch — in 2 tool calls instead of crawling git log/show/diff commit-by-commit. This works from worktrees too — HEAD reflects the worktree's branch. For uncommitted work in progress, use `-workingTree` mode to also capture staged and unstaged changes. Check `git_archive_list` first in case a prior session already created one.

7. **Placeholder semantics** — Files suffixed `-added`, `-deleted`, `-R095` make change types immediately parseable without interpreting git status codes.

8. **Side-by-side structure** — Left and right directories mirror each other. An AI can compare `left/src/App.cs` to `right/src/App.cs` directly without resolving which ref to `git show` from.

---

## Permissions & Safety

### Input validation
- **Ref names**: Validate against `^[a-zA-Z0-9/_.\-~^@{}:]+$`. Reject anything with shell metacharacters (`;`, `|`, `&`, `$`, `` ` ``, `(`, `)`, `>`, `<`, `!`).
- **File paths**: Validate no `..` path traversal. Canonicalize before use.
- **Process arguments**: Always pass as elements in `ProcessStartInfo.ArgumentList`, never interpolated into a shell string. Never use `cmd /c` or `bash -c`.

### Output directory control
- Default to `Path.GetTempPath()/GitArchiveMcp/{session-GUID}/` — a dedicated temp subdirectory per session
- If the AI specifies `outputDirectory`, validate it exists and is writable
- Track created archives in an in-memory list so `git_archive_list` and `git_archive_read` can reference them

### Read scope
- `git_archive_read` accepts any ZIP path (the AI may have archives from earlier sessions or other sources)
- Validate the path is an absolute path to an existing `.zip` file
- ZIP entry paths are sanitized against zip-slip (reject entries with `..` or absolute paths)

### No repo mutation
- The server never modifies the git repository — no checkout, reset, clean, or write operations
- The PowerShell script only reads from git (diff, show, log, rev-parse)
- Archive creation writes only to the output directory, never into the repo

### Process isolation
- `pwsh` / `bash` spawned with `UseShellExecute = false`, `CreateNoWindow = true`
- Stderr is captured and included in error responses (not swallowed)
- Timeout: 120 seconds per archive creation (configurable), to prevent hangs on massive repos

---

## Cross-Platform Script Invocation

The MCP server must invoke the PowerShell script on all three platforms:

| Platform | Strategy |
|---|---|
| **Windows** | `pwsh Git-ArchiveBranchDiffs.ps1 ...` — `pwsh` is expected on PATH (ships with .NET dev environments) |
| **Linux/macOS** | Try `pwsh` first. If not found, fall back to `bash Git-ArchiveBranchDiffs.sh ...` which auto-installs `pwsh` and then runs the `.ps1` script |

Implementation in `ArchiveService`:

```csharp
private (string command, string[] args) BuildInvocation(string[] scriptArgs)
{
    string scriptDir = GetScriptDirectory(); // directory containing .ps1 and .sh

    if (CanRunPwsh()) // checks `pwsh --version` exit code
    {
        var ps1Path = Path.Combine(scriptDir, "Git-ArchiveBranchDiffs.ps1");
        return ("pwsh", [ps1Path, ..scriptArgs]);
    }

    if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
    {
        var shPath = Path.Combine(scriptDir, "Git-ArchiveBranchDiffs.sh");
        return ("bash", [shPath, ..scriptArgs]);
    }

    throw new InvalidOperationException(
        "pwsh (PowerShell Core) is required but not found on PATH.");
}
```

The `.sh` wrapper handles `pwsh` installation automatically, so the MCP server doesn't need to manage that.

**Script location**: The `.ps1` and `.sh` files are located relative to the MCP server assembly. At build time, the project will reference the repo-root scripts. The `ArchiveService` resolves the script directory by walking up from the assembly location to find `Git-ArchiveBranchDiffs.ps1`, or via a configurable `SCRIPT_PATH` environment variable.

---

## Architecture

```
Git-ArchiveBranchDiffs/               (existing repo root)
├── Git-ArchiveBranchDiffs.ps1        (existing — invoked by the MCP)
├── Git-ArchiveBranchDiffs.sh         (existing — fallback for Linux/macOS)
├── MCP-DESIGN.md                     (this plan, committed to repo)
├── src/
│   └── GitArchiveMcp/
│       ├── GitArchiveMcp.csproj      (.NET 10, Exe)
│       ├── Program.cs                (host + DI + tool/prompt/resource registration)
│       ├── ArchiveService.cs         (script invocation + ZIP reading + analysis)
│       ├── ArchiveSession.cs         (tracks archives + annotations + list-changed notifications)
│       ├── Tools/
│       │   └── ArchiveTools.cs       (10 MCP tools)
│       ├── Prompts/
│       │   └── ArchivePrompts.cs     (7 MCP prompts)
│       └── Resources/
│           └── ArchiveResources.cs   (dynamic list/read handlers for archive:/// resources)
```

The PowerShell script still does archive *creation*. All the new analysis functionality (summary/search/diff_file/compare/apply_patch) lives inside `ArchiveService.cs` and operates directly on the ZIP.

---

## Design Decisions

| Decision | Choice | Why |
|---|---|---|
| .NET version | **10.0** | User requirement |
| Archive creation | Shell out to `pwsh` / `bash` + existing scripts | Reuses all existing logic; cross-platform via `.sh` fallback |
| Archive reading | `System.IO.Compression.ZipFile` | .NET built-in, no extra deps |
| Transport | Stdio | CLI agent use case |
| Text file reading | UTF-8 with binary detection | Skip binary files, return text contents |
| Large file cap | Truncate files > 100KB in `git_archive_read` | Prevent blowing context windows |
| Session tracking | In-memory `ArchiveSession` singleton | Supports `git_archive_list` and iterative workflows |
| Versioned naming | Always pass `-versionedName` to PS1 | Prevents overwrites when branches advance between MCP calls |

---

## Archive Naming Convention

The MCP server always creates archives with **versioned filenames** to prevent overwrites when the same branch comparison is re-run after new commits.

**Format**: `{leftName} ⟷ {rightName} ({leftHash}..{rightHash} {version}).zip`

**Version timestamp** (adapted from [BuildVersion](../BuildVersion.cs)):
`Year.Quarter.MMdd.HHmm` computed from the **newer** commit's `CommitDate`.
Quarter = ⌈Month / 3⌉.

**Hash tokens**:
- Normal refs: 7-char short hash from the commit
- Working tree: `{HEAD-hash}+wt`
- Staged: `{HEAD-hash}+stg`

**Examples**:

| Mode | Filename |
|------|----------|
| Branch | `main ⟷ f_my-feature (abc1234..def5678 2026.2.0413.1430).zip` |
| Three-way | `3way main ⟷ f_my-feature (abc1234..def5678 2026.2.0413.1430).zip` |
| Working tree | `main ⟷ WORKING-TREE (abc1234..abc1234+wt 2026.2.0413.1502).zip` |
| Staged | `main ⟷ STAGED (abc1234..abc1234+stg 2026.2.0413.1502).zip` |

This enables `git_archive_compare` to diff two snapshots of the same branch comparison taken at different points in time. An explicit `-archiveFileName` parameter always takes precedence.

---

## Tool Specifications

### `git_archive_diffs`

**MCP Description** (what the AI sees):
> Create a self-contained ZIP archive of all files that differ between two git refs (branches, tags, or commits). The archive contains both sides of every changed file organized in left/right directories, a HISTORY.md with commit log and churn summary, and a CHANGES.patch with the unified diff. Supports three modes: "branch" (compare two committed refs), "workingTree" (uncommitted changes vs a ref), and "staged" (indexed changes vs a ref). Use this instead of multiple git show/git diff calls when you need to review a complete changeset — one call captures everything. Also ideal for session resumption: archive the base branch vs HEAD to understand all committed changes, or use workingTree mode to also capture in-progress work. The archive persists on disk and can be read multiple times with git_archive_read using different file filters. Use git_archive_list to see previously created archives.

**Parameters:**
- `leftRef` (required) — branch, tag, or commit (the base, e.g. `main`)
- `rightRef` (optional) — branch, tag, or commit (the feature side). Omit when using `workingTree` or `staged` mode.
- `mode` (optional, default `"branch"`) — comparison mode:
  - `"branch"` — compare two committed refs (requires `rightRef`)
  - `"workingTree"` — compare uncommitted working tree changes against `leftRef` (includes unstaged + untracked files)
  - `"staged"` — compare staged/indexed changes against `leftRef`
- `outputDirectory` (optional) — defaults to temp directory
- `archiveFileName` (optional) — auto-generated if omitted

**Returns:** JSON with `archivePath`, `leftRef`, `rightRef` (or `"WORKING-TREE"` / `"STAGED"`), `mode`, `fileCount`, `sizeBytes`

### `git_archive_three_way`

**MCP Description:**
> Create a three-way diff archive showing the merge-base alongside both branches. The archive contains base/, left/, and right/ directories so you can see what each side changed independently. Use this when you need to understand conflicting changes or review a merge. Like git_archive_diffs, the archive persists for iterative review via git_archive_read.

Same parameters as `git_archive_diffs`. Adds `-threeWay` flag internally.

### `git_archive_read`

**MCP Description:**
> Read and return the contents of a diff archive as structured JSON. Returns every changed file's content from both sides, the commit history summary (HISTORY.md), and the unified patch (CHANGES.patch) — all in one response. Files suffixed -added, -deleted, or -R0xx are placeholders marking additions, deletions, and renames. You can call this repeatedly on the same archive with different fileFilter patterns to drill into specific areas of a changeset without recreating the archive. Particularly efficient for session resumption — reading one archive gives you the complete picture of a branch's changes instead of dozens of individual git commands. Use git_archive_list to find archives from earlier in this session.

**Parameters:**
- `archivePath` (required) — path to a ZIP (from `git_archive_diffs`, `git_archive_list`, or any path)
- `includeContents` (optional, default true) — include file text contents or just the file tree
- `fileFilter` (optional) — glob pattern to filter files (e.g. `*.cs`, `src/**`)

**Returns:** JSON with:
```json
{
  "archivePath": "/tmp/main ⟷ feature.zip",
  "directories": ["main/", "feature/", "manifest/"],
  "files": [
    {
      "path": "main/src/App.cs",
      "sizeBytes": 1234,
      "isPlaceholder": false,
      "content": "using System;\n..."
    },
    {
      "path": "feature/src/App.cs",
      "sizeBytes": 1456,
      "isPlaceholder": false,
      "content": "using System;\n..."
    },
    {
      "path": "feature/src/NewFile.cs-added",
      "sizeBytes": 0,
      "isPlaceholder": true,
      "content": null
    }
  ],
  "history": "# HISTORY.md contents...",
  "patch": "diff --git a/src/App.cs..."
}
```

### `git_archive_list`

**MCP Description:**
> List all diff archives created during this session. Returns the path, creation time, refs compared, and file count for each archive. Check here first when resuming work or starting a new task on a branch — a prior invocation may have already created an archive, saving you from recreating it. Pass the archivePath to git_archive_read to review its contents.

**Parameters:** None

**Returns:** JSON array:
```json
[
  {
    "archivePath": "/tmp/GitArchiveMcp/.../main ⟷ feature.zip",
    "leftRef": "main",
    "rightRef": "feature/auth",
    "threeWay": false,
    "fileCount": 23,
    "sizeBytes": 45678,
    "createdAt": "2026-04-09T14:30:00Z"
  }
]
```

### `git_archive_summary`

**MCP Description:**
> Get a quick overview of a diff archive without reading file contents. Returns total file count, lines added/removed, change type breakdown (additions, deletions, modifications, renames), top directories by file count, and binary file count. Use this as a first step after creating an archive to understand the scope and decide which areas to drill into with git_archive_search or git_archive_diff_file. Much faster than git_archive_read for initial triage — especially on archives with hundreds of files.

**Parameters:** `archivePath`

**Returns:** `ArchiveSummary` with `fileCount`, `linesAdded`, `linesRemoved`, `filesAdded`, `filesDeleted`, `filesModified`, `filesRenamed`, `binaryFiles`, and a `topDirectories` array (up to 10 entries of `{directory, fileCount}`).

### `git_archive_diff_file`

**MCP Description:**
> Examine a single file from a diff archive in detail. Given a file path (e.g. 'src/App.cs'), returns both the left (base) and right (feature) versions side-by-side, plus the relevant unified diff hunk from CHANGES.patch. Use this after git_archive_summary or git_archive_search to drill into a specific file without loading the entire archive. The path should be the logical file path within the repository (without the branch directory prefix). Returns the change type (added, deleted, modified, renamed) and both versions' content.

**Parameters:** `archivePath`, `filePath` (logical repo path, no branch prefix)

**Returns:** `FileDiffResult` with `path`, `changeType` (added/deleted/modified/renamed), `left` and `right` `FileVersion` objects, and the extracted `diff` hunk.

### `git_archive_search`

**MCP Description:**
> Search for a pattern across all files in a diff archive. Returns matching lines with file path, line number, and surrounding context lines. Searches both left and right versions of files, skipping binary files and placeholder files. Use this to find where a function is called, locate TODO/FIXME comments, check for debug code, or trace how a pattern appears across the changeset. Supports regex patterns and result limiting. Pair with git_archive_diff_file to examine matches in full context.

**Parameters:** `archivePath`, `pattern` (regex), `contextLines` (default 2), `maxResults` (default 50), optional `fileFilter` glob

**Returns:** `SearchResult` with `totalMatches` and a `matches` array of `{filePath, lineNumber, line, context}`.

### `git_archive_compare`

**MCP Description:**
> Compare two diff archives to see what changed between them. Useful for incremental code review: if you reviewed an archive earlier and the developer has pushed more commits, create a new archive and compare it to the old one to see only the new/changed files.

**Parameters:** `olderArchivePath`, `newerArchivePath`

**Returns:** `ArchiveComparison` with `addedFiles`, `removedFiles`, `changedFiles`, and `unchangedFiles` arrays.

### `git_archive_annotate`

**MCP Description:**
> Attach or read notes on a diff archive to track your review progress. Add annotations like 'status=reviewed', 'issues=3', or 'notes=auth flow needs rework'. Annotations persist for the session and appear in git_archive_list output.

**Parameters:** `archivePath`, optional `key`, optional `value`

**Returns:** `ArchiveAnnotations` with all current annotations on the archive.

### `git_archive_apply_patch`

**MCP Description:**
> Apply the unified diff (CHANGES.patch) from a diff archive to the current working tree using git apply --3way. Use this to replay a changeset onto your branch. WARNING: This modifies your working tree. The --3way flag enables merge conflict markers for hunks that don't apply cleanly.

**Parameters:** `archivePath`

**Returns:** `PatchApplyResult` with `success`, `exitCode`, `standardOutput`, and `standardError`.

---

## Resources

Archives are also exposed via MCP resources so clients that browse resources (rather than call tools) can discover them.

| Aspect | Value |
|---|---|
| URI scheme | `archive:///{filename}` |
| MIME type | `application/json` |
| Contents | `git_archive_summary` output + session metadata + annotations |
| List source | `ArchiveSession.List()` — same store as `git_archive_list` |
| Change notifications | `notifications/resources/list_changed` fired best-effort when `ArchiveSession.Add` is called |

Resources intentionally return the summary, not the full archive contents. This keeps discovery lightweight; clients that need full contents should call `git_archive_read`. Registered via `WithListResourcesHandler` / `WithReadResourceHandler` in `Program.cs` — the handler-based approach is required because the archive list grows dynamically at runtime (attribute-scanned `[McpServerResource]` methods are static).

---

## Prompts (Canned Workflows)

The server exposes 7 MCP prompts — reusable templates that encode multi-step workflows. When an AI selects a prompt, it receives structured instructions that chain tool calls together with analysis guidance.

| Prompt | Arguments | Workflow |
|---|---|---|
| `review-changeset` | `leftRef`, `rightRef` | Archive → read → structured code review (summary, file-by-file, issues, test coverage) |
| `triage-changeset` | `leftRef`, `rightRef` | Archive → summary → search for risk patterns → diff_file on high-impact files → annotate findings. Designed for large changesets where reading everything is wasteful. |
| `incremental-review` | `leftRef`, `rightRef` | List prior archives → create new archive → compare → diff_file on changed/added files → annotate. Focuses review on the delta since the last archive was reviewed. |
| `resume-branch` | `baseBranch`, `featureBranch` (default HEAD) | Check list → archive committed changes → archive working tree → branch overview, completed work, in-progress, next steps |
| `compare-releases` | `fromTag`, `toTag` | Archive between tags → read → release notes (highlights, features, fixes, breaking changes, contributors) |
| `review-uncommitted` | `baseBranch` (default HEAD) | Archive in workingTree mode → read → pre-commit review (debug code, hardcoded values, security, commit message draft) |
| `review-staged` | `baseBranch` (default HEAD) | Archive in staged mode → read → focused review of exactly what will be committed, with completeness check and commit message suggestion |

Each prompt tells the AI exactly which tools to call, in what order, and how to structure its analysis output. The AI executes the tools and produces the formatted result.

### When to pick which review prompt

- **`review-changeset`** — smaller changesets where reading everything is tractable. Produces a full narrative review.
- **`triage-changeset`** — large changesets (>50 files) where the "read everything" approach would flood context. Uses summary + search + targeted diff_file to find high-impact issues first.
- **`incremental-review`** — follow-up review of a branch you already looked at. Compares archives and focuses only on what the developer changed since the last pass.

---

## Implementation Steps

### Step 1: Scaffold project
- Create `src/GitArchiveMcp/` directory
- `dotnet new console -n GitArchiveMcp -f net10.0`
- Add NuGet: `ModelContextProtocol`, `Microsoft.Extensions.Hosting`
- `Program.cs`: host builder + stdio transport + `WithTools<ArchiveTools>()`
- Register `ArchiveService` and `ArchiveSession` as singletons in DI

### Step 2: ArchiveSession
- In-memory list of `ArchiveRecord` (path, refs, timestamps, size)
- `Add(record)` called after successful archive creation
- `List()` returns all records
- Thread-safe (ConcurrentBag or lock)

### Step 3: ArchiveService
- `GetScriptDirectory()` — locate `.ps1`/`.sh` relative to assembly, with `SCRIPT_PATH` env var override
- `CanRunPwsh()` — check if `pwsh` is available on PATH
- `BuildInvocation()` — platform-aware command selection (see Cross-Platform section)
- `CreateArchiveAsync(left, right, outputDir, fileName?, threeWay)` — validate refs, spawn process, capture output, register in session
- `ReadArchiveAsync(archivePath, includeContents, fileFilter)` — open ZIP, enumerate entries, detect placeholders, read text files (skip binary), extract HISTORY.md and CHANGES.patch as top-level fields
- Binary detection: check for NUL bytes in first 8KB, or known binary extensions

### Step 4: ArchiveTools (4 tools)
- Wire `ArchiveService` and `ArchiveSession` via DI
- Input validation (ref pattern, path traversal, file existence)
- Each tool: validate → call service → return JSON

### Step 5: Commit plan as MCP-DESIGN.md
- Copy the final plan to `MCP-DESIGN.md` in the repo root

### Step 6: Test + document
- Manual test: create archive, list it, read it, read with filter
- Cross-platform test: verify on Windows (pwsh direct) and confirm `.sh` fallback path compiles
- Add MCP config examples to README
- Error cases: invalid refs, missing pwsh, non-existent archive path

---

## Critical Files

| File | Role |
|---|---|
| `Git-ArchiveBranchDiffs.ps1` | Invoked by ArchiveService to create archives |
| `Git-ArchiveBranchDiffs.sh` | Fallback invocation for Linux/macOS without `pwsh` |
| `MCP-DESIGN.md` | This design document (committed to repo) |
| `src/GitArchiveMcp/Program.cs` | Server entry point |
| `src/GitArchiveMcp/ArchiveService.cs` | Script invocation + ZIP reading |
| `src/GitArchiveMcp/ArchiveSession.cs` | Tracks archives for iterative workflows |
| `src/GitArchiveMcp/Tools/ArchiveTools.cs` | 4 MCP tool definitions |
| `src/GitArchiveMcp/Prompts/ArchivePrompts.cs` | 5 MCP prompt templates |

## Dependencies

- `ModelContextProtocol` NuGet (MCP server framework)
- `Microsoft.Extensions.Hosting` (host builder)
- `pwsh` on PATH — or `bash` on Linux/macOS (the `.sh` wrapper installs `pwsh`)
- `git` on PATH (used by the PowerShell script)

---

## Deployment Guide

### Prerequisites

| Requirement | Windows | Linux | macOS |
|---|---|---|---|
| .NET 10 SDK or Runtime | [Download](https://dotnet.microsoft.com/download/dotnet/10.0) | `sudo apt install dotnet-runtime-10.0` or [manual](https://dotnet.microsoft.com/download/dotnet/10.0) | `brew install dotnet` or [manual](https://dotnet.microsoft.com/download/dotnet/10.0) |
| Git | [Git for Windows](https://git-scm.com/) | `sudo apt install git` | `xcode-select --install` or `brew install git` |
| PowerShell Core | [Optional — bundled with .NET tools] | Auto-installed by `.sh` wrapper if missing | Auto-installed by `.sh` wrapper if missing |

### Option A: Run from source (development)

```bash
# Clone the repository
git clone https://github.com/<owner>/Git-ArchiveBranchDiffs.git
cd Git-ArchiveBranchDiffs

# Build and run
dotnet run --project src/GitArchiveMcp
```

The server starts on stdio. It locates `Git-ArchiveBranchDiffs.ps1` relative to the project directory.

### Option B: Publish as self-contained executable (recommended for distribution)

Self-contained builds bundle the .NET runtime — no SDK install needed on the target machine.

**Windows:**
```powershell
dotnet publish src/GitArchiveMcp -c Release -r win-x64 --self-contained -o publish/win-x64
# Output: publish/win-x64/GitArchiveMcp.exe
```

**Linux (x64):**
```bash
dotnet publish src/GitArchiveMcp -c Release -r linux-x64 --self-contained -o publish/linux-x64
chmod +x publish/linux-x64/GitArchiveMcp
# Output: publish/linux-x64/GitArchiveMcp
```

**Linux (ARM64, e.g. Raspberry Pi, Graviton):**
```bash
dotnet publish src/GitArchiveMcp -c Release -r linux-arm64 --self-contained -o publish/linux-arm64
```

**macOS (Apple Silicon):**
```bash
dotnet publish src/GitArchiveMcp -c Release -r osx-arm64 --self-contained -o publish/osx-arm64
# Output: publish/osx-arm64/GitArchiveMcp
```

**macOS (Intel):**
```bash
dotnet publish src/GitArchiveMcp -c Release -r osx-x64 --self-contained -o publish/osx-x64
```

### Option C: Publish as framework-dependent (smaller binary, requires .NET 10 runtime)

```bash
dotnet publish src/GitArchiveMcp -c Release -o publish/framework-dependent
# Run with: dotnet publish/framework-dependent/GitArchiveMcp.dll
```

### Script location

The MCP server needs to find the PowerShell script. It searches in this order:

1. `GITMCP_SCRIPT_PATH` environment variable (explicit override)
2. Same directory as the executable/assembly
3. Walking up from the executable to find `Git-ArchiveBranchDiffs.ps1` (works for dev/source layouts)

For published builds, copy `Git-ArchiveBranchDiffs.ps1` and `Git-ArchiveBranchDiffs.sh` alongside the executable, or set the environment variable.

### Verifying the deployment

```bash
# Test that the server starts (it will wait for stdio input, then Ctrl+C)
./GitArchiveMcp  # or: dotnet run --project src/GitArchiveMcp

# Test that git and pwsh are available
git --version
pwsh --version  # optional on Linux/macOS — .sh wrapper handles this
```

---

## Claude Code Integration Guide

### Step 1: Add the MCP server to your settings

Edit your Claude Code settings file to register the MCP server.

**Per-project** (`.claude/settings.json` in the repo root — committed, shared with team):
```json
{
  "mcpServers": {
    "git-archive": {
      "command": "dotnet",
      "args": ["run", "--project", "src/GitArchiveMcp"],
      "cwd": "."
    }
  }
}
```

**Per-user** (`~/.claude/settings.json` — not committed):
```json
{
  "mcpServers": {
    "git-archive": {
      "command": "/path/to/publish/GitArchiveMcp"
    }
  }
}
```

**With published executable (cross-platform examples):**

Windows:
```json
{
  "mcpServers": {
    "git-archive": {
      "command": "C:/tools/GitArchiveMcp/GitArchiveMcp.exe"
    }
  }
}
```

Linux/macOS:
```json
{
  "mcpServers": {
    "git-archive": {
      "command": "/usr/local/bin/GitArchiveMcp"
    }
  }
}
```

**With environment variable override:**
```json
{
  "mcpServers": {
    "git-archive": {
      "command": "GitArchiveMcp",
      "env": {
        "GITMCP_SCRIPT_PATH": "/path/to/Git-ArchiveBranchDiffs.ps1"
      }
    }
  }
}
```

### Step 2: Verify the connection

After adding the configuration, restart Claude Code. The MCP server will appear in the available tools. You can verify by asking Claude:

> "What git archive tools are available?"

Claude should see the 4 tools: `git_archive_diffs`, `git_archive_three_way`, `git_archive_read`, `git_archive_list`.

### Step 3: Example workflows

**Basic changeset review:**
> "Create a diff archive between main and my feature branch, then show me what changed"

Claude will:
1. Call `git_archive_diffs(leftRef: "main", rightRef: "feature/auth")`
2. Call `git_archive_read(archivePath: "<returned path>")`
3. Analyze the changeset from the structured response

**Filtered drill-down:**
> "Show me just the test file changes from that archive"

Claude will:
1. Call `git_archive_list()` to find the archive
2. Call `git_archive_read(archivePath: "...", fileFilter: "*Tests*")`

**Three-way merge review:**
> "Show me a three-way diff between main and feature/auth so I can see what each side changed"

Claude will:
1. Call `git_archive_three_way(leftRef: "main", rightRef: "feature/auth")`
2. Call `git_archive_read(archivePath: "<returned path>")`

### Step 4: Permissions

Claude Code will prompt you the first time each tool is invoked. You can pre-approve in settings:

```json
{
  "mcpServers": {
    "git-archive": {
      "command": "GitArchiveMcp",
      "alwaysAllow": ["git_archive_diffs", "git_archive_three_way", "git_archive_read", "git_archive_list"]
    }
  }
}
```

### Troubleshooting

| Issue | Fix |
|---|---|
| "MCP server not found" | Check that the `command` path is correct and the executable exists |
| "pwsh not found" error from archive creation | Install PowerShell Core, or ensure `Git-ArchiveBranchDiffs.sh` is alongside the `.ps1` (Linux/macOS) |
| "git not found" | Ensure `git` is on PATH |
| "Script not found" | Set `GITMCP_SCRIPT_PATH` env var to the full path of `Git-ArchiveBranchDiffs.ps1` |
| Archive creation timeout | Large repos may exceed the 120s default. Set `GITMCP_TIMEOUT_SECONDS` env var |
| Empty archive | The two refs may be identical. Check with `git diff --stat left...right` |

---

## Verification

1. `dotnet build` — compiles targeting .NET 10 with no warnings
2. Create archive: invoke `git_archive_diffs` with two known refs, verify ZIP exists at returned path
3. List archives: invoke `git_archive_list`, verify the created archive appears
4. Read archive: invoke `git_archive_read`, verify JSON contains expected file tree with contents
5. Read with filter: invoke `git_archive_read` with `fileFilter: "*.cs"`, verify only `.cs` files returned
6. Three-way: invoke `git_archive_three_way`, verify `base/` directory appears in read output
7. Cross-platform: on Windows verify `pwsh` direct invocation; on Linux verify `.sh` fallback path
8. Error cases: invalid ref names rejected, non-existent archive path returns clear error, binary files handled gracefully
