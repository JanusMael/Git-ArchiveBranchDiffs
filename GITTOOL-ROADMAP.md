# GitTool Roadmap

Thinking about `GitTool` as a general-purpose git abstraction layer rather than just an archival helper.

`GitTool` wraps git CLI operations into **typed PowerShell static methods** — turning raw string output into structured objects. Below is the full inventory of methods, organized by theme.

## Commit & History

| Method | Status | Notes |
|--------|--------|-------|
| `GetLog(range, limit, paths)` | Done | Returns `GitLogEntry[]`; wired into `WriteHistoryFile` |
| `GetBlame(revision, filePath)` | Done | Returns `GitBlameLine[]` via `--porcelain` |
| `GetCommitFiles(commitHash)` | Done | Returns `GitDiff[]`; wired into HISTORY.md per-commit lists |
| `GetContributors(range)` | Done | Returns `GitContributor[]` via `shortlog -sne` |

## Branch & Ref Operations

| Method | Status | Notes |
|--------|--------|-------|
| `GetBranches(includeRemotes)` | Done | Wired into `Get-GitCompletionCandidates` |
| `GetTags()` | Done | Wired into completion |
| `GetStashes()` | Done | Wired into completion |
| `GetMergeBase(ref1, ref2)` | Done | Extracted from 3 duplicated call sites |
| `IsAncestor(ancestor, descendant)` | Done | Wired into entry-point preflight |

## Working State

| Method | Status | Notes |
|--------|--------|-------|
| `GetStatus()` | Done | Returns `GitStatusEntry[]`; wired into `-workingTree`/`-staged` fast-fail |
| `GetStagedFiles()` | Done | Returns `hashtable[]` pairing `GitStatusEntry` with `GitDiffStat` |
| `GetConflicts()` | Done | Convenience filter: `GetStatus()` where `IsConflicted()` |

## Repo Metadata

| Method | Status | Notes |
|--------|--------|-------|
| `IsShallowClone()` | Done | Extracted from entry-point inline check |
| `GetRepoRoot()` | Done | Wired into subdirectory launch support |
| `IsGitRoot(directoryPath)` | Done | Accepts both `.git` directory and worktree `.git` file |
| `GetConfig(key)` | Deferred | Typed config lookup (user.name, core.autocrlf, etc.) |
| `GetWorktrees()` | Deferred | Worktree paths + checked-out branches |
| `GetSubmodules()` | Deferred | Submodule paths, URLs, current commit |

## Diff & Comparison

| Method | Status | Notes |
|--------|--------|-------|
| `GetDiffStat(left, right)` | Done | Returns `GitDiffStat[]`; wired into HISTORY.md churn table |
| `GetFileDiff(left, right, filePath)` | Done | Unified diff text for a single file |
| `GetFileAtRevision(revision, path)` | Done | Alias for `GetFileContent` with cleaner name |
| `CompareFiles(rev1, path1, rev2, path2)` | Done | Cross-revision single-file diff via blob comparison |

## Supporting Classes

| Class | Purpose |
|-------|---------|
| `GitLogEntry` | Structured commit (hash, author, date, subject) |
| `GitBlameLine` | Per-line blame annotation |
| `GitContributor` | Author + commit count from shortlog |
| `GitDiffStat` | Per-file insertions/deletions/binary flag |
| `GitStatusEntry` | Porcelain v1 status (index + worktree flags) |
| `GitDiffFile` | Left/right file pair in an archive |

## Archive Pipeline Integration

Several GitTool methods are wired into the archive pipeline:

- **Entry point**: `IsAncestor` preflight, `GetRepoRoot` subdirectory launch, `GetStatus` fast-fail for `-workingTree`/`-staged`
- **HISTORY.md**: `GetLog` for commits, `GetDiffStat` for churn summary, `GetCommitFiles` for per-commit file lists
- **CHANGES.patch**: `WritePatchFile` produces unified diff included in every archive
- **Completion**: `GetBranches`/`GetTags`/`GetStashes` power tab-completion

## Deferred Items

These are intentionally deferred — useful but no immediate integration point:

- `GetConfig` — would support future features like auto-detecting line endings
- `GetWorktrees` — would support multi-worktree awareness
- `GetSubmodules` — would support submodule-aware archiving
