# GitTool Roadmap

Thinking about `GitTool` as a general-purpose git abstraction layer rather than just an archival helper.

Currently `GitTool` wraps: diff, file content retrieval, branch/commit resolution, remote detection, commit dates, hash validation, repo validation, and cleanup. The theme is **"typed PowerShell interface over git CLI operations"** — turning raw string output into structured objects.

Here are static methods that fit thematically:

## Commit & History

- `GetLog([string]$range, [int]$limit)` — structured commit objects (hash, author, date, subject, body)
- `GetBlame([string]$revision, [string]$filePath)` — line-by-line authorship with commit metadata
- `GetCommitFiles([string]$commitHash)` — files touched by a single commit (already close to what HISTORY.md does internally)
- `GetContributors([string]$range)` — unique authors/committers with commit counts

## Branch & Ref Operations

- `GetBranches([bool]$includeRemotes)` — typed branch objects with tracking info, ahead/behind counts
- `GetTags()` — tag objects with annotated vs lightweight, tagger, date
- `GetStashes()` — stash entries with index, message, parent commit
- `GetMergeBase([string]$ref1, [string]$ref2)` — already computed in multiple places, deserves its own method
- `IsAncestor([string]$ancestor, [string]$descendant)` — `git merge-base --is-ancestor`

## Working State

- `GetStatus()` — structured file status objects (staged, modified, untracked, conflicted)
- `GetStagedFiles()` — just the staged subset, with diff stats
- `GetConflicts()` — files in conflict with conflict type (both-modified, deleted-by-us, etc.)

## Repo Metadata

- `GetConfig([string]$key)` — typed config lookup (user.name, core.autocrlf, etc.)
- `IsShallowClone()` — already done inline, should be a method
- `GetWorktrees()` — list of worktrees with paths and checked-out branches
- `GetSubmodules()` — submodule paths, URLs, and current commit
- `GetRepoRoot()` — `git rev-parse --show-toplevel` (inverse of `IsGitRoot`)

## Diff & Comparison

- `GetDiffStat([string]$left, [string]$right)` — insertions/deletions per file (structured `--stat`)
- `GetFileDiff([string]$left, [string]$right, [string]$filePath)` — unified diff for a single file
- `GetFileAtRevision([string]$revision, [string]$path)` — already exists as `GetFileContent`, but a cleaner name
- `CompareFiles([string]$rev1, [string]$path1, [string]$rev2, [string]$path2)` — cross-revision single-file diff

## Prioritized

The ones I'd actually prioritize:

1. **`GetMergeBase`** — already duplicated in `WriteHistoryFile`, `ForThreeWay`, and `GitDiff`
2. **`IsShallowClone`** — already done inline at the entry point
3. **`GetStatus`** — would enable the `-workingTree` / `-staged` features to show a preview of what's changed before archiving
4. **`GetLog` with structured output** — `WriteHistoryFile` manually parses `git log` output; this would clean that up

The first two are pure refactors (extract existing code). The latter two would expand the tool's utility beyond archival.
