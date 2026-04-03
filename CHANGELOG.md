# Changelog

All notable changes to Git-ArchiveBranchDiffs are documented in this file.

---

## [Unreleased]

### Bug Fixes

- **Fixed binary file corruption** — Replaced PowerShell `>` redirect (which applied text encoding) with `System.Diagnostics.Process` for binary-safe stdout capture, preventing silent corruption of images, executables, and other binary files in the archive
- **Fixed wrong-directory branch detection** — Moved `Pop-Location` after right-branch resolution so `GetCurrentBranch()` runs inside the repository directory instead of wherever the script was launched from; previously the right branch always fell back to HEAD in interactive mode
- **Fixed strict mode crash in `CreateZipImpl`** — Added missing `$lastWriteTime` parameter that was referenced but never declared, causing a terminating error under `Set-StrictMode -Version Latest`
- **Fixed spurious error messages for manifest entries** — Manifest diffs intentionally pass `$null` for `originalFilePath`; the null-check now skips validation for manifest status (`X`), eliminating false red error text on every run
- **Fixed placeholder files not being truly empty** — `GetEmptyTempFile` now uses `[System.IO.File]::Create().Close()` instead of `Set-Content` which wrote a newline, so added/deleted placeholders are now zero bytes as intended
- **Fixed `Write-Fail` not halting execution** — `Write-Fail` now throws a terminating error instead of just printing red text, preventing the script from continuing with invalid state after precondition failures
- **Fixed rename token format** — Changed from verbose `renamed-095` to concise `R095` format matching the README documentation (e.g., `file.cs-R095` instead of `file.cs-renamed-095`)
- **Fixed temp directory leak on early exit** — Main execution logic is now wrapped in `try/finally` ensuring temp directory cleanup happens even when the script exits early due to validation errors
- **[bash] Fixed silent fallthrough on unknown platforms** — Unknown platform/architecture now prints an error and exits instead of continuing with empty variables producing a malformed download URL
- **[bash] Fixed arguments not forwarded to PowerShell** — Changed from passing only `$1` to forwarding all arguments via `"$@"`, so flags like `-nonInteractive` now reach the `.ps1` script
- **[bash] Fixed unquoted variables** — All variable expansions are now quoted to prevent word-splitting bugs with paths containing spaces
- **[bash] Fixed unsafe `eval` for archive extraction** — Replaced `eval "$unarchive"` string-building pattern with a direct `case` on archive extension, eliminating injection risk
- **[bash] Fixed `sudo` in CYGWIN/MINGW extraction** — Windows environments don't have `sudo`; extraction now uses `unzip` or `powershell.exe` directly without `sudo`
- **[bash] Fixed no error checking on download** — `curl` now uses `-fSL` flags to fail on HTTP errors (404, 500) instead of silently saving error pages as archives; `set -euo pipefail` catches all command failures

### Added

- **`-nonInteractive` switch** — Enables fully scripted/CI usage with no prompts; auto-detects repository (current directory), left branch (default remote), right branch (current branch), and output directory (current directory)
- **Tab completion for parameters** — `-repositoryPath` completes to directories containing `.git`; `-leftBranch` and `-rightBranch` complete to local and remote branch names using `ArgumentCompleter` attributes
- **Rich console output** — Styled banner, section dividers with unicode box-drawing characters, green checkmark status indicators for resolved inputs, and cyan arrow progress indicators
- **Summary table** — Box-drawn results table displayed after archive creation showing left/right branches, archive filename, file size, elapsed time, and output path
- **"No differences" message** — Clear yellow message when the compared branches are identical, replacing silent null return
- **[bash] `pwsh` on PATH detection** — Script now checks if `pwsh` is already installed globally before attempting download, skipping the entire install process
- **[bash] ARM64 / aarch64 architecture support** — Detects `aarch64`/`arm64` via `uname -m` and selects the correct PowerShell package (e.g., `osx-arm64.tar.gz` for Apple Silicon)
- **[bash] Temp download cleanup** — Downloaded `.tar.gz`/`.zip` archive is removed from `/tmp` after successful extraction

### Removed

- **Interactive ZIP file naming prompt** — Removed the rarely-used "Do you want to name the ZIP file?" prompt; the `-archiveFileName` parameter is still available for scripted use
- **Redundant success messages** — Removed inline success messages from `ArchiveBranchDiffs` method (replaced by the summary table)

### Changed

- **README.md** — Complete rewrite with table of contents, parameter reference table with defaults, non-interactive mode documentation and examples, output format diagram, placeholder file reference table, tab completion guide, expanded diff tool recommendations, and troubleshooting section
- **"Branch not found" messaging** — Changed from red `Write-Fail` (which now throws) to yellow `Write-Warn` since falling back to HEAD is a warning, not a fatal error
- **Error handling in file write** — Changed catch block in `WriteFileImpl` from `Write-Fail` (now fatal) to `Write-Warn` to allow the script to continue when individual files fail to write
- **[bash] Updated PowerShell version** — Bumped from 7.3.4 (end-of-life) to 7.4.7 (current stable LTS)
- **[bash] Rewrote script structure** — Flattened from function wrapper to top-level script; added `set -euo pipefail` strict mode; uses `BASH_SOURCE` for reliable script directory detection
