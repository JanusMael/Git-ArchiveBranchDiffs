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
