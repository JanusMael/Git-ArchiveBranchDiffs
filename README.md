# Git-ArchiveBranchDiffs

Create a self-contained ZIP archive of just the files that differ between two git branches — perfect for offline code review without needing a pull request.

- **No PR required** — compare any two related branches, tags, or commits
- **Working tree & staged diffs** — archive uncommitted or staged changes
- **Three-way diffs** — see what each side changed relative to the merge-base
- **Offline review** — extract the archive and use your favorite diff tool
- **Cross-platform** — runs on Windows, Linux, and macOS
- **Binary-safe** — handles text and binary files without corruption
- **Tab completion** — branches, tags, stashes, and repo paths auto-complete in PowerShell
- **Subdirectory launch** — run from anywhere inside a git repo

---

## Table of Contents

- [Quick Start](#quick-start)
- [Parameters](#parameters)
- [Comparison Modes](#comparison-modes)
- [Non-Interactive Mode](#non-interactive-mode)
- [Output Format](#output-format)
- [Placeholder Files](#placeholder-files)
- [Tab Completion](#tab-completion)
- [Diff Tool Recommendations](#diff-tool-recommendations)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Quick Start

> **Prerequisite**: `git` must be on your `PATH`

### Windows (PowerShell)

```powershell
# Interactive — prompts for each input
pwsh ./Git-ArchiveBranchDiffs.ps1

# With parameters
pwsh ./Git-ArchiveBranchDiffs.ps1 -repositoryPath "C:\repos\myRepo" -leftBranch main -rightBranch feature/my-branch -outputDirectory "C:\output"

# Non-interactive — uses smart defaults
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive

# Archive uncommitted working tree changes
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive -workingTree

# Archive staged changes only
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive -staged

# Three-way diff showing merge-base
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive -threeWay

# Compare two tags
pwsh ./Git-ArchiveBranchDiffs.ps1 -leftBranch v1.0.0 -rightBranch v2.0.0

# Compare a tag to a branch
pwsh ./Git-ArchiveBranchDiffs.ps1 -leftBranch v1.0.0 -rightBranch main
```

### Linux / macOS (Bash)

If PowerShell Core is not installed, the bash wrapper will download and install it automatically:

```bash
chmod +x ./Git-ArchiveBranchDiffs.sh
sudo bash ./Git-ArchiveBranchDiffs.sh
```

Or if `pwsh` is already installed:

```bash
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive
```

---

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-repositoryPath` | No | Current directory or auto-detected from subdirectory | Path to any directory inside a git repository |
| `-leftBranch` | No | Default remote branch (e.g., `origin/main`) | Branch, tag, or commit ref for the left side of the diff |
| `-rightBranch` | No | Currently checked-out branch | Branch, tag, or commit ref for the right side of the diff |
| `-outputDirectory` | No | Prompted (interactive) or current directory | Where the ZIP file will be created |
| `-archiveFileName` | No | Auto-generated from branch names | Custom name for the ZIP file |
| `-nonInteractive` | No | `$false` | Skip all prompts and use smart defaults |
| `-workingTree` | No | `$false` | Compare uncommitted working tree changes against the left branch |
| `-staged` | No | `$false` | Compare staged (indexed) changes against the left branch |
| `-threeWay` | No | `$false` | Produce a three-way diff with base, left, and right directories |

---

## Comparison Modes

The tool supports four comparison modes:

### Normal (default)

Compares two committed refs (branches, tags, or commit hashes). The archive contains left and right directories with the differing files.

```powershell
pwsh ./Git-ArchiveBranchDiffs.ps1 -leftBranch main -rightBranch feature/foo

# Tags work the same way
pwsh ./Git-ArchiveBranchDiffs.ps1 -leftBranch v1.0.0 -rightBranch v2.0.0
```

### Working Tree (`-workingTree`)

Compares uncommitted working tree changes against a branch. Useful for reviewing local changes before committing. Mutually exclusive with `-staged` and `-rightBranch`.

```powershell
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive -workingTree
```

### Staged (`-staged`)

Compares staged (indexed) changes against a branch. Useful for reviewing what will be included in the next commit. Mutually exclusive with `-workingTree` and `-rightBranch`.

```powershell
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive -staged
```

### Three-Way (`-threeWay`)

Produces a three-way diff with a `base/` directory showing the merge-base, plus left and right directories showing what each side changed. Mutually exclusive with `-workingTree` and `-staged`.

```powershell
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive -threeWay -leftBranch main -rightBranch feature/foo
```

---

## Non-Interactive Mode

The `-nonInteractive` switch enables fully scripted usage with no prompts. Smart defaults are applied for any parameter not explicitly provided:

| Parameter | Default When `-nonInteractive` |
|-----------|-------------------------------|
| `-repositoryPath` | Auto-detected from current directory (works from any subdirectory) |
| `-leftBranch` | Default remote branch via `git symbolic-ref` |
| `-rightBranch` | Currently checked-out branch (falls back to HEAD on detached HEAD) |
| `-outputDirectory` | Current working directory |
| `-archiveFileName` | `<leftBranch> ⟷ <rightBranch>.zip` |

### Examples

```powershell
# Run from inside a git repo (any subdirectory) — all defaults
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive

# Override just the output directory
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive -outputDirectory /tmp

# Fully specified (nonInteractive prevents any prompts for missing values)
pwsh ./Git-ArchiveBranchDiffs.ps1 -nonInteractive -repositoryPath /c/myRepo -leftBranch main -rightBranch feature/foo -outputDirectory /tmp
```

---

## Output Format

The tool creates a ZIP archive with this structure:

### Normal / Working Tree / Staged

```
archive.zip
├── leftBranch/                         # Files from the left (base) branch
│   ├── src/
│   │   ├── App.cs                      # Original version of modified file
│   │   └── NewFeature.cs-added         # Placeholder (file was added in right)
│   ├── OldName.cs-R095                 # Placeholder showing original name before rename
│   └── Removed.cs                      # Original content of deleted file
│
├── rightBranch/                        # Files from the right (feature) branch
│   ├── src/
│   │   ├── App.cs                      # Modified version
│   │   └── NewFeature.cs               # New file content
│   ├── NewName.cs                      # File after rename
│   └── Removed.cs-deleted              # Placeholder (file was deleted)
│
├── HISTORY.md                          # Commit log, churn summary, per-commit file lists
├── CHANGES.patch                       # Unified diff (git diff output)
│
└── manifest/                           # Metadata generated by the tool
    ├── Δ leftBranch ⟷ rightBranch      # Branch comparison info
    └── commit# abc1234.manifest        # Change summary and file list
```

### Three-Way (`-threeWay`)

```
3way archive.zip
├── base/                               # Files at the merge-base commit
│   └── ...
├── leftBranch/                         # Files from the left branch
│   └── ...
├── rightBranch/                        # Files from the right branch
│   └── ...
├── HISTORY.md
├── CHANGES.patch
└── manifest/
    └── ...
```

### HISTORY.md

The history file includes:

- **Churn Summary** — top 10 files by insertions + deletions, with binary file detection
- **Commit log** — per-side commit lists with per-commit file breakdowns (capped at 200 commits per side)

### CHANGES.patch

A unified diff (`git diff` output) covering all changed files. To apply the patch:

```bash
# Strict — fails on any context mismatch
git apply CHANGES.patch

# Forgiving — skips hunks that don't apply cleanly
git apply --3way CHANGES.patch

# Outside a git repo
patch -p1 < CHANGES.patch
```

---

## Placeholder Files

Placeholder files ensure both sides of the diff have a representative file for every change, so directory-diff tools can display them side-by-side.

| Git Status | Left Branch | Right Branch |
|------------|-------------|--------------|
| **Added** | `NewFile.cs-added` (zero bytes) | `NewFile.cs` (new content) |
| **Deleted** | `OriginalFile.cs` (original content) | `OriginalFile.cs-deleted` (zero bytes) |
| **Modified** | `File.cs` (original content) | `File.cs` (modified content) |
| **Renamed** | `OldName.cs-R095` (original content) | `NewName.cs` (same content, new name) |
| **Copied** | `Original.cs` (original content) | `CopiedFile.cs` (copied content) |

For renames, the suffix (e.g., `-R095`) is the raw git rename status code, indicating the similarity percentage.

---

## Tab Completion

When using PowerShell, tab completion is available for key parameters:

| Parameter | Completes To |
|-----------|-------------|
| `-repositoryPath` | Directories containing a `.git` folder |
| `-leftBranch` | Local and remote branch names, tags, and stash refs |
| `-rightBranch` | Local and remote branch names, tags, and stash refs |

```powershell
# Type and press Tab to cycle through matching branches
./Git-ArchiveBranchDiffs.ps1 -leftBranch ma<Tab>
# Completes to: main

./Git-ArchiveBranchDiffs.ps1 -rightBranch feat<Tab>
# Completes to: feature/my-branch

# Tags and stashes also complete
./Git-ArchiveBranchDiffs.ps1 -leftBranch v1.<Tab>
# Completes to: v1.0, v1.1, etc.
```

> **Note**: Branch completion uses the repository specified by `-repositoryPath`, or the current directory if not specified.

---

## Diff Tool Recommendations

Extract the archive and open the left/right branch directories in a directory-diff tool:

| Tool | Platform | Notes |
|------|----------|-------|
| [Beyond Compare](https://www.scootersoftware.com/) | Windows, Linux, macOS | Excellent rename detection, can treat placeholder-suffixed files as comparable |
| [Meld](http://meldmerge.org/) | Windows, Linux, macOS | Free and open-source |
| [VS Code](https://code.visualstudio.com/) | Windows, Linux, macOS | Use with a folder-diff extension |
| [WinMerge](https://winmerge.org/) | Windows | Free, lightweight |

---

## Troubleshooting

### `git not found`
Ensure `git` is installed and on your `PATH`. Verify with `git --version`.

### Branch not found / defaults to HEAD
- Check branch name spelling: `git branch -a` to list all branches
- Remote-only branches need a fetch first: `git fetch origin`
- The tool will try the remote version (e.g., `origin/branchName`) if the local branch isn't found

### "Left and right refer to the same commit"
The two refs resolve to the same commit hash. The tool exits early since there is nothing to compare. Verify you specified different branches.

### "Consider swapping -leftBranch and -rightBranch"
The tool detected that `rightBranch` is an ancestor of `leftBranch` (i.e., left has the newer commits). This usually means the arguments are reversed — the left branch should be the base (e.g., `main`) and the right branch should be the feature branch.

### "Working tree is clean — nothing to archive"
When using `-workingTree`, there are no uncommitted changes to archive. Make some changes first, or use normal mode to compare committed branches.

### "Index is empty — nothing to archive"
When using `-staged`, there are no staged changes. Stage files with `git add` first.

### `-threeWay` fails with "no common ancestor"
The two branches have unrelated histories (no merge-base). This can happen with orphan branches or repos initialized separately. Use normal mode instead.

### Permission denied
- **Windows**: Run PowerShell as Administrator
- **Linux/macOS**: Use `sudo` for the bash wrapper (needed for PowerShell Core installation)

### Empty archive / no differences
The branches may be identical. Verify differences exist: `git diff --stat <leftBranch>...<rightBranch>`

### PowerShell version issues
- **Windows**: PowerShell 5.1+ (built-in) or PowerShell Core 7.3.4+
- **Linux/macOS**: PowerShell Core 7.3.4+ (auto-installed by the bash wrapper)
- Check version: `$PSVersionTable.PSVersion`

---

## License

[MIT](LICENSE)
