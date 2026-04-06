#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    Unit tests for Git-ArchiveBranchDiffs.ps1

    Dot-sources the script (which skips the entry point via guard)
    to load classes and functions, then tests them directly.

    Usage:
        pwsh -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester ./Tests"
#>

Describe "Git-ArchiveBranchDiffs" {

    BeforeAll {
        $script:SkipEntryPoint = $true
        . (Join-Path $PSScriptRoot ".." "Git-ArchiveBranchDiffs.ps1")
    }

    Describe "GitDiff.Parse" {

        It "parses an Added file" {
            $diff = [GitDiff]::Parse("A`tsrc/newfile.txt")
            $diff.Status | Should -Be ([GitDiffStatus]::Added)
            $diff.FilePath | Should -Be "src/newfile.txt"
        }

        It "parses a Deleted file" {
            $diff = [GitDiff]::Parse("D`tsrc/old.txt")
            $diff.Status | Should -Be ([GitDiffStatus]::Deleted)
            $diff.OriginalFilePath | Should -Be "src/old.txt"
        }

        It "parses a Modified file" {
            $diff = [GitDiff]::Parse("M`tsrc/file.txt")
            $diff.Status | Should -Be ([GitDiffStatus]::Modified)
            $diff.FilePath | Should -Be "src/file.txt"
        }

        It "parses a Rename with similarity score" {
            $diff = [GitDiff]::Parse("R095`told.txt`tnew.txt")
            $diff.Status | Should -Be ([GitDiffStatus]::Renamed)
            $diff.OriginalFilePath | Should -Be "old.txt"
            $diff.FilePath | Should -Be "new.txt"
            $diff.RenameToken | Should -Be "R095"
        }

        It "parses a Copy" {
            $diff = [GitDiff]::Parse("C`tsrc/a.txt`tsrc/b.txt")
            $diff.Status | Should -Be ([GitDiffStatus]::Copy)
        }

        It "returns null for empty input" {
            { [GitDiff]::Parse("") } | Should -Throw
        }
    }

    Describe "DiffTokenFileInfo - Added" {

        BeforeAll {
            $script:diff = [GitDiff]::Parse("A`tsrc/newfile.txt")
        }

        It "creates a token file" {
            $script:diff.TokenFileInfo | Should -Not -BeNullOrEmpty
        }

        It "has '-added' suffix on the placeholder path" {
            $script:diff.TokenFileInfo.FilePath | Should -Be "src/newfile.txt-added"
        }

        It "places the placeholder on the Left side" {
            $script:diff.TokenFileInfo.Comparand | Should -Be ([DiffComparand]::Left)
        }

        It "has an empty temp file as content (not the real file)" {
            $script:diff.TokenFileInfo.ContentFilePath | Should -Not -Be "src/newfile.txt"
            (Test-Path $script:diff.TokenFileInfo.ContentFilePath) | Should -BeTrue
            (Get-Item $script:diff.TokenFileInfo.ContentFilePath).Length | Should -Be 0
        }
    }

    Describe "DiffTokenFileInfo - Deleted" {

        BeforeAll {
            $script:diff = [GitDiff]::Parse("D`tsrc/old.txt")
        }

        It "creates a token file" {
            $script:diff.TokenFileInfo | Should -Not -BeNullOrEmpty
        }

        It "has '-deleted' suffix on the placeholder path" {
            $script:diff.TokenFileInfo.FilePath | Should -Be "src/old.txt-deleted"
        }

        It "places the placeholder on the Right side" {
            $script:diff.TokenFileInfo.Comparand | Should -Be ([DiffComparand]::Right)
        }
    }

    Describe "DiffTokenFileInfo - Renamed" {

        BeforeAll {
            $script:diff = [GitDiff]::Parse("R095`told.txt`tnew.txt")
        }

        It "creates a token file" {
            $script:diff.TokenFileInfo | Should -Not -BeNullOrEmpty
        }

        It "has the rename token as suffix on the original path" {
            $script:diff.TokenFileInfo.FilePath | Should -Be "old.txt-R095"
        }

        It "places the placeholder on the Left side" {
            $script:diff.TokenFileInfo.Comparand | Should -Be ([DiffComparand]::Left)
        }

        It "points ContentFilePath to the original file path" {
            $script:diff.TokenFileInfo.ContentFilePath | Should -Be "old.txt"
        }
    }

    Describe "DiffTokenFileInfo - Modified has no token" {

        It "does not create a token for Modified files" {
            $diff = [GitDiff]::Parse("M`tsrc/file.txt")
            $diff.TokenFileInfo | Should -BeNullOrEmpty
        }

        It "does not create a token for Copy files" {
            $diff = [GitDiff]::Parse("C`tsrc/a.txt`tsrc/b.txt")
            $diff.TokenFileInfo | Should -BeNullOrEmpty
        }
    }

    Describe "GitDiffStatus enum values" {

        It "Added maps to A" {
            [int][GitDiffStatus]::Added | Should -Be ([int][GitDiffStatusRaw]::A)
        }

        It "Deleted maps to D" {
            [int][GitDiffStatus]::Deleted | Should -Be ([int][GitDiffStatusRaw]::D)
        }

        It "Modified maps to M" {
            [int][GitDiffStatus]::Modified | Should -Be ([int][GitDiffStatusRaw]::M)
        }

        It "Renamed maps to R" {
            [int][GitDiffStatus]::Renamed | Should -Be ([int][GitDiffStatusRaw]::R)
        }
    }

    Describe "GitDiff constructor - edge cases" {

        It "handles manifest entry (status X) with null originalFilePath" {
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                $diff = [GitDiff]::new("X", $null, $tempFile)
                $diff.Status | Should -Be ([GitDiffStatus]::Unknown)
                $diff.TokenFileInfo | Should -Not -BeNullOrEmpty
                $diff.TokenFileInfo.Comparand | Should -Be ([DiffComparand]::Manifest)
            }
            finally {
                Remove-Item $tempFile -ErrorAction SilentlyContinue
            }
        }

        It "throws on null statusRaw" {
            { [GitDiff]::new($null, "a.txt", "a.txt") } | Should -Throw
        }

        It "coerces null filePath to empty string (PowerShell [string] behavior)" {
            $diff = [GitDiff]::new("M", "a.txt", $null)
            $diff.FilePath | Should -Be ""
        }

        It "for Added, FilePath equals OriginalFilePath" {
            $diff = [GitDiff]::Parse("A`tnewfile.txt")
            $diff.FilePath | Should -Be $diff.OriginalFilePath
        }
    }

    Describe "IsPossibleCommitHash" {

        It "accepts a valid short hash" {
            [GitTool]::IsPossibleCommitHash("abcd1234") | Should -BeTrue
        }

        It "accepts a full 40-char hash" {
            [GitTool]::IsPossibleCommitHash("a" * 40) | Should -BeTrue
        }

        It "rejects a branch name" {
            [GitTool]::IsPossibleCommitHash("main") | Should -BeFalse
        }

        It "rejects a hash that is too short" {
            [GitTool]::IsPossibleCommitHash("abc") | Should -BeFalse
        }

        It "accepts uppercase hex (PowerShell -match is case-insensitive)" {
            [GitTool]::IsPossibleCommitHash("ABCD1234") | Should -BeTrue
        }

        It "rejects strings with non-hex characters" {
            [GitTool]::IsPossibleCommitHash("ghijklmn") | Should -BeFalse
        }
    }

    Describe "Helper functions" {

        It "Get-ExtensionEquals matches case-insensitively" {
            Get-ExtensionEquals "file.ZIP" ".zip" | Should -BeTrue
        }

        It "Get-ExtensionEquals rejects mismatched extensions" {
            Get-ExtensionEquals "file.tar" ".zip" | Should -BeFalse
        }

        It "Get-DateTimeAndZone returns a string" {
            $dto = [System.DateTimeOffset]::Now
            $result = Get-DateTimeAndZone $dto
            $result | Should -BeOfType [string]
        }
    }

    Describe "RevisionKind enum" {

        It "has Commit, WorkTree, and Staged values" {
            [RevisionKind]::Commit | Should -Be ([RevisionKind]::Commit)
            [RevisionKind]::WorkTree | Should -Be ([RevisionKind]::WorkTree)
            [RevisionKind]::Staged | Should -Be ([RevisionKind]::Staged)
        }
    }

    Describe "GitBranch factory methods" {

        It "ForWorkTree creates a branch with WorkTree kind" {
            $branch = [GitBranch]::ForWorkTree()
            $branch.Kind | Should -Be ([RevisionKind]::WorkTree)
            $branch.BranchName | Should -Be "WORKING-TREE"
            $branch.CommitHash | Should -BeNullOrEmpty
        }

        It "ForStaged creates a branch with Staged kind" {
            $branch = [GitBranch]::ForStaged()
            $branch.Kind | Should -Be ([RevisionKind]::Staged)
            $branch.BranchName | Should -Be "STAGED"
            $branch.CommitHash | Should -BeNullOrEmpty
        }

        It "ForWorkTree GetTimestamp returns (uncommitted)" {
            $branch = [GitBranch]::ForWorkTree()
            $branch.GetTimestamp() | Should -Be "(uncommitted)"
        }

        It "ForStaged GetDirectorySafeName returns STAGED" {
            $branch = [GitBranch]::ForStaged()
            $branch.GetDirectorySafeName() | Should -Be "STAGED"
        }
    }

    Describe "GetDirectorySafeName with special characters" {

        It "replaces forward slashes" {
            $branch = [GitBranch]::ForWorkTree()
            # Use reflection to set BranchName for testing
            $branch.BranchName = "feature/my-branch"
            $branch.GetDirectorySafeName() | Should -Be "feature_my-branch"
        }

        It "replaces tilde and caret" {
            $branch = [GitBranch]::ForWorkTree()
            $branch.BranchName = "HEAD~5"
            $branch.GetDirectorySafeName() | Should -Be "HEAD_5"
        }

        It "replaces stash notation characters" {
            $branch = [GitBranch]::ForWorkTree()
            $branch.BranchName = "stash@{0}"
            $branch.GetDirectorySafeName() | Should -Be "stash__0_"
        }
    }

    Describe "Get-GitCompletionCandidates" {

        It "returns an array" {
            $result = Get-GitCompletionCandidates
            $result | Should -BeOfType [string]
        }

        It "filters by prefix" {
            # Should return empty for a prefix that doesn't match any branch/tag/stash
            $result = @(Get-GitCompletionCandidates "zzz_nonexistent_prefix_12345")
            $result.Count | Should -Be 0
        }
    }

    Describe "GitTool.GetMergeBase" {

        It "returns null for empty inputs" {
            [GitTool]::GetMergeBase("", "abc123") | Should -BeNullOrEmpty
            [GitTool]::GetMergeBase("abc123", "") | Should -BeNullOrEmpty
        }

        It "returns null for nonexistent commits" {
            [GitTool]::GetMergeBase("0000000000000000000000000000000000000000", "0000000000000000000000000000000000000001") | Should -BeNullOrEmpty
        }

        It "returns a string for valid commits in this repo" {
            # HEAD and HEAD should share a merge-base (HEAD itself)
            $head = git rev-parse HEAD 2>$null
            if($null -ne $head) {
                $result = [GitTool]::GetMergeBase($head, $head)
                $result | Should -Not -BeNullOrEmpty
                $result.Length | Should -BeGreaterOrEqual 4
            }
        }
    }

    Describe "GitTool.IsShallowClone" {

        It "returns a boolean" {
            $result = [GitTool]::IsShallowClone()
            $result | Should -BeOfType [bool]
        }
    }

    Describe "GitDiffFile allows null diff" {

        It "accepts null diff parameter for three-way mode" {
            $tempFile = [System.IO.Path]::GetTempFileName()
            try {
                $fi = [System.IO.FileInfo]::new($tempFile)
                $diffFile = [GitDiffFile]::new($null, $fi, $fi)
                $diffFile.Diff | Should -BeNullOrEmpty
                $diffFile.LeftFile | Should -Not -BeNullOrEmpty
            }
            finally {
                Remove-Item $tempFile -ErrorAction SilentlyContinue
            }
        }
    }

    Describe "GitTool.IsAncestor" {

        It "returns false for empty inputs" {
            [GitTool]::IsAncestor("", "HEAD") | Should -BeFalse
            [GitTool]::IsAncestor("HEAD", "") | Should -BeFalse
        }

        It "returns true when ancestor equals descendant (reflexive)" {
            $head = git rev-parse HEAD 2>$null
            if($null -ne $head) {
                [GitTool]::IsAncestor($head, $head) | Should -BeTrue
            }
        }

        It "returns false for nonexistent commits" {
            [GitTool]::IsAncestor("0000000000000000000000000000000000000000", "HEAD") | Should -BeFalse
        }
    }

    Describe "GitTool.GetRepoRoot" {

        It "returns a non-empty path when inside a git repo" {
            $result = [GitTool]::GetRepoRoot()
            $result | Should -Not -BeNullOrEmpty
            Test-Path $result | Should -BeTrue
        }
    }

    Describe "GitTool.GetBranches" {

        It "returns an array including the current branch" {
            $branches = [GitTool]::GetBranches($false)
            $branches | Should -Not -BeNullOrEmpty
            $current = git rev-parse --abbrev-ref HEAD 2>$null
            if($null -ne $current -and $current -ne "HEAD") {
                $branches | Should -Contain $current
            }
        }

        It "includes remote branches when includeRemotes is true" {
            $local = @([GitTool]::GetBranches($false))
            $all = @([GitTool]::GetBranches($true))
            $all.Count | Should -BeGreaterOrEqual $local.Count
        }
    }

    Describe "GitTool.GetTags" {

        It "returns an array (possibly empty)" {
            $result = [GitTool]::GetTags()
            ,$result | Should -BeOfType [System.Array]
        }
    }

    Describe "GitTool.GetStashes" {

        It "returns an array (possibly empty)" {
            $result = [GitTool]::GetStashes()
            ,$result | Should -BeOfType [System.Array]
        }
    }

    Describe "GitLogEntry.Parse" {

        It "parses a well-formed log line" {
            $fs = [GitLogEntry]::FieldSeparator
            $line = "abcdef1234567890abcdef1234567890abcdef12${fs}abcdef1${fs}Jane Doe${fs}jane@example.com${fs}2024-01-15T10:30:00+00:00${fs}Initial commit"
            $entry = [GitLogEntry]::Parse($line)
            $entry | Should -Not -BeNullOrEmpty
            $entry.Hash | Should -Be "abcdef1234567890abcdef1234567890abcdef12"
            $entry.ShortHash | Should -Be "abcdef1"
            $entry.AuthorName | Should -Be "Jane Doe"
            $entry.AuthorEmail | Should -Be "jane@example.com"
            $entry.Subject | Should -Be "Initial commit"
            $entry.AuthorDate.Year | Should -Be 2024
        }

        It "returns null for empty input" {
            [GitLogEntry]::Parse("") | Should -BeNullOrEmpty
            [GitLogEntry]::Parse($null) | Should -BeNullOrEmpty
        }

        It "returns null for malformed input (too few fields)" {
            [GitLogEntry]::Parse("only one field") | Should -BeNullOrEmpty
        }

        It "falls back to DateTimeOffset.MinValue for unparseable dates" {
            $fs = [GitLogEntry]::FieldSeparator
            $line = "h${fs}h${fs}n${fs}e${fs}not-a-date${fs}subj"
            $entry = [GitLogEntry]::Parse($line)
            $entry | Should -Not -BeNullOrEmpty
            $entry.AuthorDate | Should -Be ([System.DateTimeOffset]::MinValue)
        }

        It "GetLogFormat contains field separators" {
            $fmt = [GitLogEntry]::GetLogFormat()
            $fmt | Should -Match "%H"
            $fmt | Should -Match "%h"
            $fmt | Should -Match "%an"
            $fmt | Should -Match "%ae"
            $fmt | Should -Match "%aI"
            $fmt | Should -Match "%s"
        }

        It "ToString includes hash and subject" {
            $fs = [GitLogEntry]::FieldSeparator
            $line = "abc${fs}abc${fs}Jane${fs}j@e.com${fs}2024-01-15T10:30:00+00:00${fs}Fix bug"
            $entry = [GitLogEntry]::Parse($line)
            $entry.ToString() | Should -Match "abc"
            $entry.ToString() | Should -Match "Fix bug"
        }
    }

    Describe "GitTool.GetLog" {

        It "returns an empty array for empty range" {
            $result = @([GitTool]::GetLog(""))
            $result.Count | Should -Be 0
        }

        It "returns entries for HEAD with a limit" {
            $result = @([GitTool]::GetLog("HEAD", 3))
            $result.Count | Should -BeLessOrEqual 3
            $result.Count | Should -BeGreaterThan 0
            $result[0].Hash.Length | Should -Be 40
            $result[0].ShortHash.Length | Should -BeGreaterOrEqual 4
        }

        It "respects path filter" {
            $unfiltered = @([GitTool]::GetLog("HEAD", 10, $null))
            $filtered = @([GitTool]::GetLog("HEAD", 10, @("nonexistent-xyzzy-file.txt")))
            $filtered.Count | Should -Be 0
            $unfiltered.Count | Should -BeGreaterThan 0
        }
    }

    Describe "GitContributor.Parse" {

        It "parses a standard shortlog line" {
            $c = [GitContributor]::Parse("    42`tJane Doe <jane@example.com>")
            $c | Should -Not -BeNullOrEmpty
            $c.CommitCount | Should -Be 42
            $c.Name | Should -Be "Jane Doe"
            $c.Email | Should -Be "jane@example.com"
        }

        It "parses a line without email brackets" {
            $c = [GitContributor]::Parse("  5`tSomeone")
            $c | Should -Not -BeNullOrEmpty
            $c.CommitCount | Should -Be 5
            $c.Name | Should -Be "Someone"
        }

        It "returns null for empty input" {
            [GitContributor]::Parse("") | Should -BeNullOrEmpty
            [GitContributor]::Parse($null) | Should -BeNullOrEmpty
        }

        It "returns null for malformed input" {
            [GitContributor]::Parse("not a number") | Should -BeNullOrEmpty
        }

        It "ToString round-trips with count and name" {
            $c = [GitContributor]::Parse("    3`tAlice <alice@test.com>")
            $s = $c.ToString()
            $s | Should -Match "3"
            $s | Should -Match "Alice"
        }
    }

    Describe "GitTool.GetContributors" {

        It "returns empty for empty range" {
            @([GitTool]::GetContributors("")).Count | Should -Be 0
        }

        It "returns at least one contributor for HEAD" {
            $result = @([GitTool]::GetContributors("HEAD"))
            $result.Count | Should -BeGreaterThan 0
            $result[0].CommitCount | Should -BeGreaterThan 0
            $result[0].Name | Should -Not -BeNullOrEmpty
        }
    }

    Describe "GitTool.GetBlame" {

        It "returns empty for empty inputs" {
            @([GitTool]::GetBlame("", "x.txt")).Count | Should -Be 0
            @([GitTool]::GetBlame("HEAD", "")).Count | Should -Be 0
        }

        It "returns empty for nonexistent file" {
            @([GitTool]::GetBlame("HEAD", "definitely-no-such-file-xyzzy.txt")).Count | Should -Be 0
        }

        It "returns blame lines for a known file at HEAD" {
            $result = @([GitTool]::GetBlame("HEAD", "Git-ArchiveBranchDiffs.ps1"))
            $result.Count | Should -BeGreaterThan 0
            $result[0].CommitHash.Length | Should -Be 40
            $result[0].LineNumber | Should -BeGreaterOrEqual 1
            $result[0].Content | Should -Not -BeNullOrEmpty
            $result[0].AuthorName | Should -Not -BeNullOrEmpty
        }
    }

    Describe "GitBlameLine.ToString" {

        It "includes short hash and content" {
            $bl = [GitBlameLine]::new("abcdef1234567890abcdef1234567890abcdef12", 5, "Author", "a@b.com", [System.DateTimeOffset]::Now, "some code")
            $s = $bl.ToString()
            $s | Should -Match "abcdef12"
            $s | Should -Match "some code"
            $s | Should -Match "5:"
        }
    }

    Describe "GitTool.GetStagedFiles" {

        It "returns an array (possibly empty)" {
            $result = [GitTool]::GetStagedFiles()
            ,$result | Should -BeOfType [System.Array]
        }

        It "each entry has Status and DiffStat keys" {
            $result = [GitTool]::GetStagedFiles()
            foreach($entry in $result) {
                $entry.ContainsKey("Status") | Should -BeTrue
                $entry.ContainsKey("DiffStat") | Should -BeTrue
                $entry.Status.GetType().Name | Should -Be "GitStatusEntry"
            }
        }
    }

    Describe "GitTool.GetConflicts" {

        It "returns an empty array when not in a merge conflict" {
            $result = @([GitTool]::GetConflicts())
            $result.Count | Should -Be 0
        }
    }

    Describe "GitTool.GetFileAtRevision" {

        It "returns bytes for a known file at HEAD" {
            $result = [GitTool]::GetFileAtRevision("HEAD", "Git-ArchiveBranchDiffs.ps1")
            $result.Length | Should -BeGreaterThan 0
        }

        It "returns empty for a nonexistent file" {
            $result = [GitTool]::GetFileAtRevision("HEAD", "nonexistent-xyzzy-file.txt")
            $result.Length | Should -Be 0
        }
    }

    Describe "GitTool.CompareFiles" {

        It "returns empty for empty inputs" {
            [GitTool]::CompareFiles("", "x", "HEAD", "y") | Should -Be ""
            [GitTool]::CompareFiles("HEAD", "x", "", "y") | Should -Be ""
            [GitTool]::CompareFiles("HEAD", "", "HEAD", "y") | Should -Be ""
            [GitTool]::CompareFiles("HEAD", "x", "HEAD", "") | Should -Be ""
        }

        It "returns empty when comparing the same file at the same revision" {
            [GitTool]::CompareFiles("HEAD", "Git-ArchiveBranchDiffs.ps1", "HEAD", "Git-ArchiveBranchDiffs.ps1") | Should -Be ""
        }

        It "returns diff when comparing different revisions of the same file" {
            $parent = git rev-parse "HEAD~1" 2>$null
            if($LASTEXITCODE -eq 0 -and $null -ne $parent) {
                $stats = @([GitTool]::GetDiffStat("HEAD~1", "HEAD"))
                if($stats.Count -gt 0) {
                    $path = $stats[0].FilePath
                    $diff = [GitTool]::CompareFiles("HEAD~1", $path, "HEAD", $path)
                    $diff | Should -Not -BeNullOrEmpty
                    $diff | Should -Match "diff --git"
                }
            }
        }
    }

    Describe "GitTool.GetFileDiff" {

        It "returns empty string for empty inputs" {
            [GitTool]::GetFileDiff("", "HEAD", "x.txt") | Should -Be ""
            [GitTool]::GetFileDiff("HEAD", "", "x.txt") | Should -Be ""
            [GitTool]::GetFileDiff("HEAD", "HEAD", "") | Should -Be ""
        }

        It "returns empty string when comparing HEAD to itself" {
            [GitTool]::GetFileDiff("HEAD", "HEAD", "Git-ArchiveBranchDiffs.ps1") | Should -Be ""
        }

        It "returns empty string for a path that does not exist" {
            [GitTool]::GetFileDiff("HEAD~1", "HEAD", "definitely-not-a-real-file-xyzzy.txt") | Should -Be ""
        }

        It "returns unified diff text for a changed file" {
            $parent = git rev-parse "HEAD~1" 2>$null
            if($LASTEXITCODE -eq 0 -and $null -ne $parent) {
                # Find any file changed in the last commit
                $stats = @([GitTool]::GetDiffStat("HEAD~1", "HEAD"))
                if($stats.Count -gt 0) {
                    $path = $stats[0].FilePath
                    $diff = [GitTool]::GetFileDiff("HEAD~1", "HEAD", $path)
                    $diff | Should -Not -BeNullOrEmpty
                    $diff | Should -Match "diff --git"
                }
            }
        }
    }

    Describe "GitDiffStat.Parse" {

        It "parses a text file stat line" {
            $stat = [GitDiffStat]::Parse("10`t3`tsrc/file.txt")
            $stat.Insertions | Should -Be 10
            $stat.Deletions | Should -Be 3
            $stat.FilePath | Should -Be "src/file.txt"
            $stat.IsBinary | Should -BeFalse
            $stat.OriginalFilePath | Should -BeNullOrEmpty
        }

        It "flags binary files with dashes" {
            $stat = [GitDiffStat]::Parse("-`t-`timage.png")
            $stat.IsBinary | Should -BeTrue
            $stat.Insertions | Should -Be 0
            $stat.Deletions | Should -Be 0
        }

        It "handles zero-change entries" {
            $stat = [GitDiffStat]::Parse("0`t0`tempty.txt")
            $stat.Insertions | Should -Be 0
            $stat.Deletions | Should -Be 0
            $stat.IsBinary | Should -BeFalse
        }

        It "extracts rename arrow (old => new)" {
            $stat = [GitDiffStat]::Parse("5`t2`told.txt => new.txt")
            $stat.OriginalFilePath | Should -Be "old.txt"
            $stat.FilePath | Should -Be "new.txt"
        }

        It "returns null for empty input" {
            [GitDiffStat]::Parse("") | Should -BeNullOrEmpty
            [GitDiffStat]::Parse($null) | Should -BeNullOrEmpty
        }

        It "returns null for too-few fields" {
            [GitDiffStat]::Parse("10`t3") | Should -BeNullOrEmpty
        }

        It "ToString shows +/- for text files" {
            $stat = [GitDiffStat]::Parse("10`t3`tsrc/file.txt")
            $stat.ToString() | Should -Match "\+10"
            $stat.ToString() | Should -Match "-3"
        }

        It "ToString shows (binary) for binary files" {
            $stat = [GitDiffStat]::Parse("-`t-`timage.png")
            $stat.ToString() | Should -Match "\(binary\)"
        }
    }

    Describe "GitTool.GetDiffStat" {

        It "returns empty for empty inputs" {
            @([GitTool]::GetDiffStat("", "HEAD")).Count | Should -Be 0
            @([GitTool]::GetDiffStat("HEAD", "")).Count | Should -Be 0
        }

        It "returns empty for HEAD compared to itself" {
            $result = @([GitTool]::GetDiffStat("HEAD", "HEAD"))
            $result.Count | Should -Be 0
        }

        It "returns GitDiffStat objects for HEAD~1..HEAD" {
            $parent = git rev-parse "HEAD~1" 2>$null
            if($LASTEXITCODE -eq 0 -and $null -ne $parent) {
                $stats = @([GitTool]::GetDiffStat("HEAD~1", "HEAD"))
                foreach($s in $stats) {
                    $s.GetType().Name | Should -Be "GitDiffStat"
                    $s.FilePath | Should -Not -BeNullOrEmpty
                }
            }
        }
    }

    Describe "GitTool.GetCommitFiles" {

        It "returns empty for null or empty hash" {
            @([GitTool]::GetCommitFiles($null)).Count | Should -Be 0
            @([GitTool]::GetCommitFiles("")).Count | Should -Be 0
        }

        It "returns empty for nonexistent commit" {
            @([GitTool]::GetCommitFiles("0000000000000000000000000000000000000000")).Count | Should -Be 0
        }

        It "returns GitDiff entries for HEAD" {
            $head = git rev-parse HEAD 2>$null
            if($null -ne $head) {
                $diffs = @([GitTool]::GetCommitFiles($head))
                $diffs.Count | Should -BeGreaterThan 0
                foreach($d in $diffs) {
                    $d.GetType().Name | Should -Be "GitDiff"
                    $d.FilePath | Should -Not -BeNullOrEmpty
                }
            }
        }
    }

    Describe "GitStatusEntry.Parse" {

        It "parses a modified-in-worktree entry" {
            $entry = [GitStatusEntry]::Parse(" M src/file.txt")
            $entry.IndexStatus | Should -Be " "
            $entry.WorkTreeStatus | Should -Be "M"
            $entry.FilePath | Should -Be "src/file.txt"
            $entry.OriginalFilePath | Should -BeNullOrEmpty
        }

        It "parses a staged-added entry" {
            $entry = [GitStatusEntry]::Parse("A  new.txt")
            $entry.IndexStatus | Should -Be "A"
            $entry.WorkTreeStatus | Should -Be " "
            $entry.IsStaged() | Should -BeTrue
        }

        It "parses a rename entry" {
            $entry = [GitStatusEntry]::Parse("R  old.txt -> new.txt")
            $entry.IndexStatus | Should -Be "R"
            $entry.OriginalFilePath | Should -Be "old.txt"
            $entry.FilePath | Should -Be "new.txt"
        }

        It "parses an untracked entry" {
            $entry = [GitStatusEntry]::Parse("?? unknown.txt")
            $entry.IsUntracked() | Should -BeTrue
            $entry.IsStaged() | Should -BeFalse
        }

        It "detects conflicts (UU)" {
            $entry = [GitStatusEntry]::Parse("UU conflict.txt")
            $entry.IsConflicted() | Should -BeTrue
        }

        It "detects conflicts (AA)" {
            $entry = [GitStatusEntry]::Parse("AA both-added.txt")
            $entry.IsConflicted() | Should -BeTrue
        }

        It "does not flag a plain modification as conflict" {
            $entry = [GitStatusEntry]::Parse(" M file.txt")
            $entry.IsConflicted() | Should -BeFalse
        }

        It "returns null for too-short lines" {
            [GitStatusEntry]::Parse("ab") | Should -BeNullOrEmpty
        }

        It "returns null for null input" {
            [GitStatusEntry]::Parse($null) | Should -BeNullOrEmpty
        }

        It "ToString round-trips a basic entry" {
            $entry = [GitStatusEntry]::Parse(" M src/file.txt")
            $entry.ToString() | Should -Be " M src/file.txt"
        }

        It "ToString includes rename arrow" {
            $entry = [GitStatusEntry]::Parse("R  old.txt -> new.txt")
            $entry.ToString() | Should -Be "R  old.txt -> new.txt"
        }
    }

    Describe "GitTool.GetStatus" {

        It "returns an array of GitStatusEntry" {
            $result = [GitTool]::GetStatus()
            ,$result | Should -BeOfType [System.Array]
            foreach($entry in $result) {
                $entry.GetType().Name | Should -Be "GitStatusEntry"
            }
        }
    }

    Describe "TempDirectoryScope" {

        It "creates a temp directory that exists" {
            $temp = [TempDirectoryScope]::new($null)
            try {
                $temp.GetTempPath() | Should -Not -BeNullOrEmpty
                Test-Path $temp.GetTempPath() | Should -BeTrue
            }
            finally {
                $temp.Cleanup()
            }
        }

        It "GetEmptyTempFile creates a zero-byte file" {
            $temp = [TempDirectoryScope]::new($null)
            try {
                $path = $temp.GetEmptyTempFile()
                Test-Path $path | Should -BeTrue
                (Get-Item $path).Length | Should -Be 0
            }
            finally {
                $temp.Cleanup()
            }
        }

        It "Cleanup removes the temp directory" {
            $temp = [TempDirectoryScope]::new($null)
            $path = $temp.GetTempPath()
            $temp.Cleanup()
            Test-Path $path | Should -BeFalse
        }
    }
}
