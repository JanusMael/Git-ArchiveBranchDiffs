#Requires -Version 7.0
Set-StrictMode -Version Latest

<#
    Integration tests for Git-ArchiveBranchDiffs.ps1

    Creates throwaway git repos in a temp directory, runs the archive
    pipeline against them, verifies the results, then cleans up. If
    all tests pass, no files remain on disk.

    Usage:
        pwsh -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester ./Tests/Integration.Tests.ps1"
#>

Describe "Integration: Git-ArchiveBranchDiffs" -Tag "Integration" {

    BeforeAll {
        $script:SkipEntryPoint = $true
        . (Join-Path $PSScriptRoot ".." "Git-ArchiveBranchDiffs.ps1")

        # Root temp directory for all integration tests in this run.
        # Named to avoid collision with other processes.
        $script:IntegrationRoot = [System.IO.Path]::Combine(
            [System.IO.Path]::GetTempPath(),
            "ArchiveBranchDiffs-IntegrationTests-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
        )
        [System.IO.Directory]::CreateDirectory($script:IntegrationRoot) | Out-Null

        # Helper: creates a throwaway git repo with an initial commit and returns its path.
        function New-TestRepo {
            [OutputType([string])]
            param(
                [string]$Name = "repo"
            )
            [string]$repoPath = [System.IO.Path]::Combine($script:IntegrationRoot, $Name)
            [System.IO.Directory]::CreateDirectory($repoPath) | Out-Null

            Push-Location $repoPath
            try {
                git init --initial-branch=main 2>$null | Out-Null
                git config user.email "test@test.com" 2>$null
                git config user.name "Test User" 2>$null

                # Initial commit with a file
                Set-Content -Path "README.md" -Value "# Test Repo"
                git add README.md 2>$null | Out-Null
                git commit -m "Initial commit" 2>$null | Out-Null
            }
            finally {
                Pop-Location
            }
            return $repoPath
        }

        # Helper: creates a feature branch with changes and returns the branch name.
        function Add-FeatureBranch {
            [OutputType([string])]
            param(
                [Parameter(Mandatory)][string]$RepoPath,
                [string]$BranchName = "feature",
                [hashtable]$Files = @{}
            )
            Push-Location $RepoPath
            try {
                git checkout -b $BranchName 2>$null | Out-Null
                foreach($kv in $Files.GetEnumerator()) {
                    [string]$dir = [System.IO.Path]::GetDirectoryName($kv.Key)
                    if(-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path $dir)) {
                        New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    }
                    Set-Content -Path $kv.Key -Value $kv.Value
                    git add $kv.Key 2>$null | Out-Null
                }
                git commit -m "Add feature changes" 2>$null | Out-Null
                git checkout main 2>$null | Out-Null
            }
            finally {
                Pop-Location
            }
            return $BranchName
        }

        # Helper: runs the archive and returns the ZIP FileInfo.
        # Returns $null and sets $script:LastArchiveError on failure.
        function Invoke-Archive {
            [OutputType([System.IO.FileInfo])]
            param(
                [Parameter(Mandatory)][string]$RepoPath,
                [Parameter(Mandatory)][string]$LeftBranch,
                [Parameter(Mandatory)][string]$RightBranch,
                [string]$OutputDir = $null
            )
            if([string]::IsNullOrEmpty($OutputDir)) {
                $OutputDir = [System.IO.Path]::Combine($script:IntegrationRoot, "output-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))")
            }
            [System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

            Push-Location $RepoPath
            try {
                [System.IO.FileInfo]$result = $null
                try {
                    $result = [GitTool]::ArchiveBranchDiffs($LeftBranch, $RightBranch, $OutputDir, $null)
                }
                catch {
                    $script:LastArchiveError = $_
                    return $null
                }
                return $result
            }
            finally {
                Pop-Location
            }
        }

        # Helper: extracts a ZIP and returns the extraction directory path.
        function Expand-TestArchive {
            [OutputType([string])]
            param(
                [Parameter(Mandatory)][System.IO.FileInfo]$ZipFile
            )
            [string]$extractDir = [System.IO.Path]::Combine(
                $script:IntegrationRoot,
                "extracted-$([System.Guid]::NewGuid().ToString('N').Substring(0, 8))"
            )
            Expand-Archive -Path $ZipFile.FullName -DestinationPath $extractDir -Force
            return $extractDir
        }
    }

    AfterAll {
        # Zero-trace cleanup: remove the integration root entirely.
        if(Test-Path $script:IntegrationRoot) {
            # Retry loop to handle Windows file-locking on recently-written ZIPs.
            [int]$retries = 5
            for([int]$i = 0; $i -lt $retries; $i++) {
                try {
                    Remove-Item -Recurse -Force $script:IntegrationRoot -ErrorAction Stop
                    break
                }
                catch {
                    if($i -eq $retries - 1) { Write-Warning "Integration cleanup failed: $_" }
                    Start-Sleep -Milliseconds 500
                }
            }
        }
    }

    Describe "Basic two-branch archive" {

        It "creates a ZIP containing left/right files, HISTORY.md, and CHANGES.patch" {
            $repo = New-TestRepo -Name "basic-two-branch"
            $branch = Add-FeatureBranch -RepoPath $repo -BranchName "feature" -Files @{
                "src/hello.txt" = "Hello World"
                "src/utils.txt" = "Utility functions"
            }

            $zip = Invoke-Archive -RepoPath $repo -LeftBranch "main" -RightBranch "feature"
            $zip | Should -Not -BeNullOrEmpty
            $zip.Exists | Should -BeTrue
            $zip.Length | Should -BeGreaterThan 0

            # Extract and verify contents
            $extractDir = Expand-TestArchive -ZipFile $zip
            $allFiles = Get-ChildItem $extractDir -Recurse -File

            # Should have left dir (main), right dir (feature), plus metadata files
            $fileNames = $allFiles | ForEach-Object { $_.Name }
            $fileNames | Should -Contain "HISTORY.md"
            $fileNames | Should -Contain "CHANGES.patch"

            # Patch should contain real diff content, not stub files
            $patchFile = $allFiles | Where-Object { $_.Name -eq "CHANGES.patch" }
            $patchContent = Get-Content $patchFile.FullName -Raw
            $patchContent | Should -Match "diff --git"
            $patchContent | Should -Not -Match "-deleted"
            $patchContent | Should -Not -Match "-added"

            # HISTORY.md should contain churn summary
            $historyFile = $allFiles | Where-Object { $_.Name -eq "HISTORY.md" }
            $historyContent = Get-Content $historyFile.FullName -Raw
            $historyContent | Should -Match "Churn Summary"
            $historyContent | Should -Match "Insertions"
        }
    }

    Describe "File operations" {

        It "handles added, deleted, and modified files in the archive" {
            $repo = New-TestRepo -Name "file-ops"
            # Add a file that will be deleted and modified on the feature branch
            Push-Location $repo
            try {
                Set-Content -Path "to-delete.txt" -Value "will be deleted"
                Set-Content -Path "to-modify.txt" -Value "original content"
                git add to-delete.txt to-modify.txt 2>$null | Out-Null
                git commit -m "Add files for testing" 2>$null | Out-Null
            }
            finally { Pop-Location }

            $branch = Add-FeatureBranch -RepoPath $repo -BranchName "changes" -Files @{
                "to-modify.txt" = "modified content"
                "brand-new.txt" = "new file"
            }
            # Delete a file on the feature branch
            Push-Location $repo
            try {
                git checkout changes 2>$null | Out-Null
                git rm to-delete.txt 2>$null | Out-Null
                git commit -m "Delete file" 2>$null | Out-Null
                git checkout main 2>$null | Out-Null
            }
            finally { Pop-Location }

            $zip = Invoke-Archive -RepoPath $repo -LeftBranch "main" -RightBranch "changes"
            $zip | Should -Not -BeNullOrEmpty

            $extractDir = Expand-TestArchive -ZipFile $zip
            $allFiles = Get-ChildItem $extractDir -Recurse -File
            $fileNames = $allFiles | ForEach-Object { $_.Name }

            # Verify the deleted file has a stub marker
            $fileNames | Should -Contain "to-delete.txt-deleted"

            # Verify the added file has a stub marker
            $fileNames | Should -Contain "brand-new.txt-added"

            # Modified file should appear on both sides
            $modifiedFiles = $allFiles | Where-Object { $_.Name -eq "to-modify.txt" }
            $modifiedFiles.Count | Should -Be 2

            # Patch should reflect all three operations
            $patchFile = $allFiles | Where-Object { $_.Name -eq "CHANGES.patch" }
            $patchContent = Get-Content $patchFile.FullName -Raw
            $patchContent | Should -Match "to-delete\.txt"
            $patchContent | Should -Match "brand-new\.txt"
            $patchContent | Should -Match "to-modify\.txt"
        }
    }

    Describe "Ancestor preflight" {

        It "IsAncestor detects reflexive ancestor relationship" {
            $repo = New-TestRepo -Name "same-commit"
            Push-Location $repo
            try {
                [string]$headHash = git rev-parse HEAD 2>$null
                # Same commit is its own ancestor (reflexive)
                [GitTool]::IsAncestor($headHash, $headHash) | Should -BeTrue
                # Same hash → entry point would early-exit before archiving
                [string]::Equals(
                    [GitTool]::GetCommitHash("main"),
                    $headHash,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) | Should -BeTrue
            }
            finally { Pop-Location }
        }

        It "IsAncestor detects linear ancestry between branches" {
            $repo = New-TestRepo -Name "linear-ancestry"
            $branch = Add-FeatureBranch -RepoPath $repo -BranchName "child" -Files @{
                "child.txt" = "child content"
            }
            Push-Location $repo
            try {
                [string]$mainHash = git rev-parse main 2>$null
                [string]$childHash = git rev-parse child 2>$null
                [GitTool]::IsAncestor($mainHash, $childHash) | Should -BeTrue
                [GitTool]::IsAncestor($childHash, $mainHash) | Should -BeFalse
            }
            finally { Pop-Location }
        }
    }

    Describe "Subdirectory launch" {

        It "GetRepoRoot resolves from a subdirectory" {
            $repo = New-TestRepo -Name "subdir-launch"
            [string]$subDir = [System.IO.Path]::Combine($repo, "deeply", "nested")
            [System.IO.Directory]::CreateDirectory($subDir) | Out-Null

            Push-Location $subDir
            try {
                [string]$resolvedRoot = [GitTool]::GetRepoRoot()
                # Normalize path separators for comparison
                $resolvedRoot = $resolvedRoot.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
                $repo = $repo.Replace("/", [System.IO.Path]::DirectorySeparatorChar)
                $resolvedRoot | Should -Be $repo
            }
            finally { Pop-Location }
        }
    }

    Describe "Empty working tree fast-fail" {

        It "GetStatus returns empty when working tree is clean" {
            $repo = New-TestRepo -Name "clean-worktree"
            Push-Location $repo
            try {
                [GitStatusEntry[]]$status = [GitTool]::GetStatus()
                [GitStatusEntry[]]$dirty = @($status | Where-Object { $_.IsModifiedInWorkTree() -or $_.IsUntracked() })
                $dirty.Length | Should -Be 0
            }
            finally { Pop-Location }
        }

        It "GetStatus detects modified files" {
            $repo = New-TestRepo -Name "dirty-worktree"
            Push-Location $repo
            try {
                # Modify a tracked file without staging
                Set-Content -Path "README.md" -Value "Modified content"
                [GitStatusEntry[]]$status = [GitTool]::GetStatus()
                [GitStatusEntry[]]$dirty = @($status | Where-Object { $_.IsModifiedInWorkTree() })
                $dirty.Length | Should -BeGreaterThan 0
            }
            finally { Pop-Location }
        }

        It "GetStatus detects staged files" {
            $repo = New-TestRepo -Name "staged-worktree"
            Push-Location $repo
            try {
                Set-Content -Path "staged-file.txt" -Value "staged"
                git add staged-file.txt 2>$null | Out-Null
                [GitStatusEntry[]]$status = [GitTool]::GetStatus()
                [GitStatusEntry[]]$stagedEntries = @($status | Where-Object { $_.IsStaged() })
                $stagedEntries.Length | Should -BeGreaterThan 0
            }
            finally { Pop-Location }
        }
    }

    Describe "CHANGES.patch content" {

        It "patch excludes stub files and contains only real diffs" {
            $repo = New-TestRepo -Name "patch-content"
            Push-Location $repo
            try {
                Set-Content -Path "will-delete.txt" -Value "to be deleted"
                git add will-delete.txt 2>$null | Out-Null
                git commit -m "Add file to delete later" 2>$null | Out-Null
            }
            finally { Pop-Location }

            $branch = Add-FeatureBranch -RepoPath $repo -BranchName "patch-test" -Files @{
                "new-file.txt" = "added content"
            }
            Push-Location $repo
            try {
                git checkout "patch-test" 2>$null | Out-Null
                git rm will-delete.txt 2>$null | Out-Null
                git commit -m "Delete file" 2>$null | Out-Null
                git checkout main 2>$null | Out-Null
            }
            finally { Pop-Location }

            $zip = Invoke-Archive -RepoPath $repo -LeftBranch "main" -RightBranch "patch-test"
            $zip | Should -Not -BeNullOrEmpty

            $extractDir = Expand-TestArchive -ZipFile $zip
            $patchFile = Get-ChildItem $extractDir -Recurse -File | Where-Object { $_.Name -eq "CHANGES.patch" }
            $patchFile | Should -Not -BeNullOrEmpty

            $patchContent = Get-Content $patchFile.FullName -Raw
            # Real diff operations present
            $patchContent | Should -Match "diff --git"
            # Stub tokens should NOT appear as diff targets
            $patchContent | Should -Not -Match "diff --git.*-deleted"
            $patchContent | Should -Not -Match "diff --git.*-added"
        }
    }
}
