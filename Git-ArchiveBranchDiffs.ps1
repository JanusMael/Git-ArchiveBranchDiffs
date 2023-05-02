<#
    .SYNOPSIS
    Creates a ZIP archive containing the diff/delta between two related branches

    .DESCRIPTION
    Creates a ZIP archive containing the diff/delta between two related branches
    Ensure the following are on the PATH environment variable: { git }

    .PARAMETER repositoryPath
    Specifies directory path to the root of a `git` repository

    .PARAMETER leftBranch
    Specifies the name of the branch to be the left-side of a diff comparison

    .PARAMETER rightBranch
    Specifies the name of the branch to be the right-side of a diff comparison

    .PARAMETER outputDirectory
    Specifies the directory path where the ZIP file will be created

    .PARAMETER archiveFileName
    [Optional] Specifies the name of the ZIP file that will be created

    .EXAMPLE
    PS> ./Git-ArchiveBranchDiffs.ps1 -repositoryPath /c/myRepo -leftBranch master -rightBranch f/myBranch -outputDirectory /tmp
#>
Param (
    [parameter(Mandatory=$false)]
	[string]$repositoryPath, 
    [parameter(Mandatory=$false)]
	[string]$leftBranch, 
    [parameter(Mandatory=$false)]
	[string]$rightBranch, 
    [parameter(Mandatory=$false)]
	[System.IO.DirectoryInfo]$outputDirectory,
	[parameter(Mandatory=$false)]
	[string]$archiveFileName = $null
)

Set-StrictMode -Version Latest

#region Short output functions
Function Write-Success {
    Write-Host $args -ForegroundColor Green -BackgroundColor Black
}

Function Write-Info {
    Write-Host $args -ForegroundColor Blue -BackgroundColor Black
}

Function Write-Warn {
    Write-Host $args -ForegroundColor Yellow -BackgroundColor Black
}

Function Write-Fail {
    Write-Host $args -ForegroundColor Red -BackgroundColor Black
}

Function Read-Prompt {
    [OutputType([string])]
    Param (
        [Parameter(Mandatory=$true)]
        [string]
        $prompt
    )
    $(Write-Host -ForegroundColor Blue $($prompt + ": ")) + $(Read-Host)     
}
#endregion  Short output functions

#region IO / zip functions
[int]$BufferSize = 4096
function CopyBinaryStream (
    [Parameter(Mandatory=$true)]
    [System.IO.Stream]$streamIn,
    [Parameter(Mandatory=$true)]
    [System.IO.Stream]$streamOut
    )
{
    $reader = New-Object System.IO.BinaryReader $streamIn
    $writer = New-Object System.IO.BinaryWriter $streamOut

    [byte[]]$buffer = New-Object byte[] $BufferSize
    [int]$bytesRead = 0

    # while the read method returns bytes
    # keep writing them to the output stream
    While(($bytesRead = $reader.Read($buffer, 0, $buffer.Length)) -gt 0 )
    {
        $writer.Write($buffer, 0, $bytesRead)
    }

    $reader.Dispose()
    $writer.Dispose()
}

function TakeOwn(

    [Parameter(Mandatory=$true)]
    [System.IO.FileSystemInfo]$fileSystemInfo
)
{
    [string]$fullPath = """" + $fileSystemInfo.FullName + """"
    Start-Process -FilePath takeown.exe -ArgumentList ("/F $fullPath") -Verb runas | Out-Null
}

function AddFileInfoToZipArchive(
    [Parameter(Mandatory=$true)]
    [System.IO.Compression.ZipArchive]$zipArchive,
    [Parameter(Mandatory=$true)]
    [System.IO.FileInfo]$fileInfo,
    [Parameter(Mandatory=$true)]
    [string]$zipFilePath,
    [Parameter(Mandatory=$true)]
    [string]$entryName,
    #[Parameter(Mandatory=$false)]
    [bool]$omitFileContent = $false,
    #[Parameter(Mandatory=$false)]
    [string[]]$exclusions = $null,
    #[Parameter(Mandatory=$false)]
    [Nullable[System.DateTimeOffset]]$lastWriteTime = $null
    )
{
    if ($zipFilePath -ne $fileInfo.FullName)
    {
        [boolean]$shouldExclude = $false

        if ($null -ne $exclusions)
        {
            ForEach($exclusion in $exclusions)
            {
                #NOTE e.g. excluding '\packages' will ALSO exclude 'SomeFolder\packages.config' so you have to be specific e.g. '\packages\'
                if($fileInfo.FullName.Contains($exclusion))
                {
                    $shouldExclude = $true
                    break
                }
            }
        }

        if($shouldExclude -eq $false)
        {
			#prevent directory with no name shown by certain archive management tools
			$entryName = $entryName.TrimStart('/', '\')

            [System.IO.Compression.ZipArchiveEntry]$entry = $null

            if ($omitFileContent -eq $false -and
                $fileInfo.Exists)
            {
                $entry = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $fileInfo.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            }
            else 
            {
                $entry = $zipArchive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            }

            if($null -ne $lastWriteTime -and $lastWriteTime.HasValue)
            {
                $entry.LastWriteTime = $lastWriteTime.Value
            }
        }
    }
}

function CreateZipFromPathsImpl (
    #[Parameter(Mandatory=$false)]
    [System.Collections.Generic.IEnumerable[string]]
    $sourceFilePaths,
    #[Parameter(Mandatory=$false)]
    [string]$rootedPathToIgnore,
	#[Parameter(Mandatory=$false)]
    [string]$destinationPath,
    #[Parameter(Mandatory=$false)]
    [string]$archiveFileName,
    #[Parameter(Mandatory=$false)]
    [bool]$omitFileContent = $false,
    #[Parameter(Mandatory=$false)]
    [string[]]$exclusions = $null,
    #[Parameter(Mandatory=$false)]
    [Nullable[System.DateTimeOffset]]$lastWriteTime = $null
    )
{
    $ErrorActionPreference = "stop" # you can opt to stagger on, bleeding, if an error occurs

    if($MyInvocation.MyCommand.PSobject.Properties.name -match "Path") #strict mode safe check for property
    {
        $commandPath = (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
	else
	{
		$commandPath = (Split-Path -Parent $MyInvocation.PSCommandPath)
	}
    $commandDirectory = [System.IO.DirectoryInfo]::new($commandPath)

    if ([System.String]::IsNullOrEmpty($destinationPath))
    {
        $destinationPath = $commandPath
    }
    if ([System.String]::IsNullOrEmpty($archiveFileName))
    {
        $archiveFileName = $commandDirectory.Name + ".zip"
    }
	if(-not $(Get-ExtensionEquals $archiveFileName ".zip"))
	{
		$archiveFileName += ".zip"
	}

    $zipFilePath = [System.IO.Path]::Combine($destinationPath, $archiveFileName)

    Add-Type -Assembly System.IO.Compression

    [System.IO.FileStream]$stream = [System.IO.File]::Open($zipFilePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $arguments = $stream, [System.IO.Compression.ZipArchiveMode]::Create, $false, [System.Text.Encoding]::UTF8
    [System.IO.Compression.ZipArchive]$zipArchive = New-Object System.IO.Compression.ZipArchive $arguments

    [string]$activity = "Zipping files"
		
    [int]$i = 0
    [double]$progressFactor = 100.0 / [Linq.Enumerable]::Count($sourceFilePaths)
    ForEach ($sourceFilePath in $sourceFilePaths)
    {
        [System.IO.FileInfo]$fileInfo = New-Object System.IO.FileInfo $sourceFilePath

        $i = $i + 1
        [int]$percentage = $progressFactor * $i

        if($fileInfo.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint) -or
           $fileInfo.Attributes.HasFlag([System.IO.FileAttributes]::Directory))
        {
            continue
        }

        $removePathRootLength = 0
        if ([System.String]::IsNullOrEmpty($rootedPathToIgnore))
        {
            $removePathRootLength = [System.IO.Path]::GetPathRoot($fileInfo.FullName).Length
        }
        else
        {
            $removePathRootLength = $rootedPathToIgnore.Length
        }

        [string]$entryName = $fileInfo.FullName.Remove(0, $removePathRootLength)

        Write-Progress -Activity $activity -Status "$percentage% Complete $entryName" -PercentComplete $percentage

        AddFileInfoToZipArchive $zipArchive $fileInfo $zipFilePath $entryName $omitFileContent $exclusions $lastWriteTime
    }
    Write-Progress -Activity $activity -Completed

    $zipArchive.Dispose()
    $stream.Dispose()
}

function CreateZipImpl (
    #[Parameter(Mandatory=$false)]
    [string]$sourcePath,
	#[Parameter(Mandatory=$false)]
    [string]$destinationPath,
    #[Parameter(Mandatory=$false)]
    [string]$archiveFileName,
    #[Parameter(Mandatory=$false)]
    [bool]$omitFileContent = $false,
    #[Parameter(Mandatory=$false)]
    [string]$searchPatternMask = "*",
    #[Parameter(Mandatory=$false)]
    [string[]]$exclusions = $null,
	#[Parameter(Mandatory=$false)]
	[boolean]$includeParentDirectoryName = $false,
	#[Parameter(Mandatory=$false)]
	[string]$nestInDirectoryOverride = ""
    )
{
    $ErrorActionPreference = "stop" # you can opt to stagger on, bleeding, if an error occurs

    if($MyInvocation.MyCommand.PSobject.Properties.name -match "Path") #strict mode safe check for property
    {
        $commandPath = (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
	else
	{
		$commandPath = (Split-Path -Parent $MyInvocation.PSCommandPath)
	}
    $commandDirectory = [System.IO.DirectoryInfo]::new($commandPath)

    if ([System.String]::IsNullOrEmpty($sourcePath))
    {
        $sourcePath = $commandPath
    }
    if ([System.String]::IsNullOrEmpty($destinationPath))
    {
        $destinationPath = $commandPath
    }
    if ([System.String]::IsNullOrEmpty($archiveFileName))
    {
        $archiveFileName = $commandDirectory.Name + ".zip"
    }
	if(-not $(Get-ExtensionEquals $archiveFileName ".zip"))
	{
		$archiveFileName += ".zip"
	}

    $zipFilePath = [System.IO.Path]::Combine($destinationPath, $archiveFileName)

    Add-Type -Assembly System.IO.Compression

    $sourceDirectory = [System.IO.DirectoryInfo]::new($sourcePath)

    $splitDelimiters = ";", "|"
    [string[]]$searchPatterns = $searchPatternMask.Split($splitDelimiters, [System.StringSplitOptions]::RemoveEmptyEntries)

    [System.IO.FileStream]$stream = [System.IO.File]::Open($zipFilePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $arguments = $stream, [System.IO.Compression.ZipArchiveMode]::Create, $false, [System.Text.Encoding]::UTF8
    [System.IO.Compression.ZipArchive]$zipArchive = New-Object System.IO.Compression.ZipArchive $arguments

    ForEach ($searchPattern in $searchPatterns)
    {
        ForEach ($fileInfo in $sourceDirectory.EnumerateFiles($searchPattern, [System.IO.SearchOption]::TopDirectoryOnly))
        {
            [string]$entryName = $null

			if($includeParentDirectoryName -eq $true)
			{
				$entryName = $fileInfo.FullName.Remove(0, $sourceDirectory.Parent.FullName.Length)
			}
			else
			{
				$entryName = $fileInfo.FullName.Remove(0, $sourceDirectory.FullName.Length)
			}

			if([string]::IsNullOrEmpty($nestInDirectoryOverride) -eq $false)
			{
				$entryName = $nestInDirectoryOverride + $entryName;
			}

            AddFileInfoToZipArchive $zipArchive $fileInfo $zipFilePath $entryName $omitFileContent $exclusions $lastWriteTime
        }
    }

    ForEach ($directoryInfo in $sourceDirectory.EnumerateDirectories("*", [System.IO.SearchOption]::AllDirectories))
    {
        if($directoryInfo.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint))
        {
            continue
        }
        $shouldExclude = $false
        if ($null -ne $exclusions)
        {
            ForEach($exclusion in $exclusions)
            {
                #NOTE e.g. excluding '\packages' will ALSO exclude 'SomeFolder\packages.config' so you have to be specific e.g. '\packages\'
                if($directoryInfo.FullName.Contains($exclusion))
                {
                    $shouldExclude = $true
                    break
                }
                elseif($exclusion.EndsWith("\") -and
                       $directoryInfo.FullName.Contains($exclusion.Substring(0, $exclusion.Length - 1)))
                {
                    $shouldExclude = $true
                    break
                }
            }
        }
        if($shouldExclude -eq $true)
        {
            continue
        }
        ForEach ($searchPattern in $searchPatterns)
        {
            ForEach ($fileInfo in $directoryInfo.EnumerateFiles($searchPattern, [System.IO.SearchOption]::TopDirectoryOnly))
            {
				[string]$entryName = $null

				if($includeParentDirectoryName -eq $true)
				{
					$entryName = $fileInfo.FullName.Remove(0, $sourceDirectory.Parent.FullName.Length)
				}
				else
				{
					$entryName = $fileInfo.FullName.Remove(0, $sourceDirectory.FullName.Length)
				}

				if([string]::IsNullOrEmpty($nestInDirectoryOverride) -eq $false)
				{
					$entryName = $nestInDirectoryOverride + [System.IO.Path]::DirectorySeparatorChar + $entryName;
				}

                AddFileInfoToZipArchive $zipArchive $fileInfo $zipFilePath $entryName $omitFileContent $exclusions $lastWriteTime
            }
        }
    }

    $zipArchive.Dispose()
    $stream.Dispose()
}

function CreateZip (
    #[Parameter(Mandatory=$false)]
    [string]$sourcePath,
	#[Parameter(Mandatory=$false)]
    [string]$destinationPath,
    #[Parameter(Mandatory=$false)]
    [string]$archiveFileName,
    #[Parameter(Mandatory=$false)]
    [string]$searchPatternMask = "*",
    #[Parameter(Mandatory=$false)]
    [string[]]$exclusions = $null,
	#[Parameter(Mandatory=$false)]
	[boolean]$includeParentDirectoryName = $false,
	#[Parameter(Mandatory=$false)]
	[string]$nestInDirectoryOverride = ""
    )
{
    CreateZipImpl $sourcePath $destinationPath $archiveFileName $false $searchPatternMask $exclusions $includeParentDirectoryName $nestInDirectoryOverride
}

function CreateDirectoryListingArchive (
    #[Parameter(Mandatory=$false)]
    [string]$sourcePath,
	#[Parameter(Mandatory=$false)]
    [string]$destinationPath,
    #[Parameter(Mandatory=$false)]
    [string]$archiveFileName,
    #[Parameter(Mandatory=$false)]
    [string]$searchPatternMask = "*",
    #[Parameter(Mandatory=$false)]
    [string[]]$exclusions = $null,
	#[Parameter(Mandatory=$false)]
	[boolean]$includeParentDirectoryName = $false,
	#[Parameter(Mandatory=$false)]
	[string]$nestInDirectoryOverride = ""
    )
{
    CreateZipImpl $sourcePath $destinationPath $archiveFileName $true $searchPatternMask $exclusions $includeParentDirectoryName $nestInDirectoryOverride
}

function Unzip(
    [string]$sourceArchivePath,
    [string]$destinationPath
) {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($sourceArchivePath, $destinationPath)
}

function Convert-NewlinesToUnix([string] $fileName) {
    (Get-Content $fileName).Replace("`r`n", "`n") | Out-File $fileName -Encoding ascii
    return
}


function Convert-NewlinesToWindows([string] $fileName) {
    (Get-Content $fileName).Replace("`n", "`r`n") | Out-File $fileName -Encoding ascii
    return
}

function Get-Temp-SubDirectory([string] $subDirectory) {
    [System.IO.DirectoryInfo]$tempDirectory = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetTempPath())
    [System.IO.DirectoryInfo]$tempSubDirectory = $tempDirectory.CreateSubdirectory($subDirectory)
    return $tempSubDirectory
}

function Get-IsDirectory([System.IO.FileSystemInfo]$fileSystemInfo) {
    return $null -ne $fileSystemInfo -and ($fileSystemInfo.GetType().IsAssignableFrom([System.IO.DirectoryInfo]))
}

function Get-ParentDirectory([System.IO.FileSystemInfo]$fileSystemInfo) {
    if($(Get-IsDirectory $fileSystemInfo))
    {
        return ([System.IO.DirectoryInfo]$fileSystemInfo).Parent
    }
    else 
    {
        return ([System.IO.FileInfo]$fileSystemInfo).Directory
    }
}

function Get-PathParts {
    [OutputType([System.Collections.Generic.IEnumerable[string]])]
    Param (
        [parameter(Mandatory=$true)]
        [System.IO.FileSystemInfo]
        $fileSystemInfo
    )
    [System.Collections.Generic.Stack[string]]$pathParts = New-Object System.Collections.Generic.Stack[string]
    
    [System.IO.FileSystemInfo]$cursor = $fileSystemInfo

    while($null -ne $cursor) {
        $pathParts.Push($cursor.Name)
        $cursor = $(Get-ParentDirectory $cursor)
    }
    return $pathParts
}

function Get-SharedPath {
    [OutputType([System.IO.DirectoryInfo])]
    Param (
        [parameter(Mandatory=$true)]
        [System.IO.FileSystemInfo]
        $leftPath,
        [parameter(Mandatory=$true)]
        [System.IO.FileSystemInfo]
        $rightPath
    )
    [System.Collections.IEnumerator]$lhsPathParts = $(Get-PathParts $leftPath).GetEnumerator()
    [System.Collections.IEnumerator]$rhsPathParts = $(Get-PathParts $rightPath).GetEnumerator()
    
    [System.Collections.Generic.List[string]]$sharedRootParts = [System.Collections.Generic.List[string]]::new()
    
    while($lhsPathParts.MoveNext() -and $rhsPathParts.MoveNext() -and 
        $lhsPathParts.Current -eq $rhsPathParts.Current) {
        $sharedRootParts.Add($lhsPathParts.Current)
    }

    $sharedPath = [System.IO.Path]::Combine($sharedRootParts)

    if([string]::IsNullOrEmpty($sharedPath))
    {
        return $null
    }

    [System.IO.DirectoryInfo]$sharedDirectory = [System.IO.DirectoryInfo]::new($sharedPath)
    return $sharedDirectory
}

function Get-UniqueName {
    [OutputType([string])]
    Param ()
    return [System.Guid]::NewGuid().ToString().Replace("-", "")
}

function Get-DateTimeAndZone {
    [OutputType([string])]
    Param (
        [parameter(Mandatory=$true)]
        [System.DateTimeOffset]
        $dateTimeOffset
    )

    [string]$shortTimeZone = ""
    [string[]]$timeZoneParts = [System.TimeZone]::CurrentTimeZone.StandardName.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)

    for ($i = 0; $i -lt $timeZoneParts.Length; $i++) {
        $shortTimeZone += $timeZoneParts[$i][0]
    }

    [string]$dateTimeAndZone = $dateTimeOffset.DateTime.ToShortDateString() + " " + $dateTimeOffset.DateTime.ToLongTimeString() + " (" + $shortTimeZone + ")"
    return $dateTimeAndZone
}

function Get-ExtensionEquals {
    [OutputType([boolean])]
    Param (
        [parameter(Mandatory=$true)]
        [string]
        $filePath,
		[parameter(Mandatory=$true)]
        [string]
        $extension
	)
    return [string]::Equals([System.IO.Path]::GetExtension($filePath), $("." + $extension.TrimStart(".")), [System.StringComparison]::InvariantCultureIgnoreCase)
}

#endregion  IO / zip functions

#region Enums
<# Git Cherry Pick types #>
enum GitDiffStatusRaw { 
	A #addition of a file
	C #copy of a file into a new one
	D #deletion of a file
	M #modification of the contents or mode of a file
	R #renaming of a file
	T #change in the type of the file
	U #file is unmerged (you must complete the merge before it can be committed)
	X #"unknown" change type (erroneous if returned by 'git', used for manifests by GitTool
}
enum GitDiffStatus {
	Added = [GitDiffStatusRaw]::A
	Copy = [GitDiffStatusRaw]::C
	Deleted = [GitDiffStatusRaw]::D
	Modified = [GitDiffStatusRaw]::M
	Renamed = [GitDiffStatusRaw]::R
	ChangedType = [GitDiffStatusRaw]::T
	Unmerged = [GitDiffStatusRaw]::U
	Unknown = [GitDiffStatusRaw]::X
}

enum DiffComparand
{
	Left
	Right
	Manifest # bookkeeping files added in addition to the files participating in the diff
}
#endregion Enums

<# model of line items returned by `git diff` #>
class GitDiff {
	GitDiff([string]$statusRaw, [string]$originalFilePath, [string]$filePath) {
		if($null -eq $statusRaw) {
			Write-Fail "statusRaw should not be null"
		}
		if($null -eq $originalFilePath) {
			Write-Fail "originalFilePath should not be null"
		}
		if($null -eq $filePath) {
			Write-Fail "filePath should not be null"
		}
		$this.OriginalFilePath = $originalFilePath
		$this.FilePath = $filePath
		$this.RenameToken = $null
		if($statusRaw.StartsWith([GitDiffStatusRaw]::R.ToString())) 
		{
			#e.g.  R095
			$this.RenameToken =  "renamed-" + $statusRaw.Substring(1)
			$this.Status = [GitDiffStatusRaw]::R.ToString()
		}
		else 
		{
			$this.Status = [GitDiffStatus][Enum]::Parse([GitDiffStatusRaw], $statusRaw)
		} 

		if($this.Status -eq [GitDiffStatus]::Added)
		{
			$this.FilePath = $this.OriginalFilePath
		}
		if($this.Status -ne [GitDiffStatus]::Modified -and
		   $this.Status -ne [GitDiffStatus]::Copy -and
		   $this.Status -ne [GitDiffStatus]::ChangedType) 
		{
			$this.TokenFileInfo = [DiffTokenFileInfo]::new($this)
		}
	}
	[GitDiffStatus]$Status
	[string]$FilePath
	[string]$OriginalFilePath
	[DiffTokenFileInfo]$TokenFileInfo
	[string]$RenameToken
	static [string]$BranchDiffSeparator = " ⟷ "

	static [GitDiff]Parse([string]$diffRaw) {
		if([string]::IsNullOrEmpty($diffRaw)) {
			Write-Fail "diffRaw should not be null"
		}
		[GitDiff]$result = $null
		[string[]]$diffParts = $diffRaw.Split("`t", [System.StringSplitOptions]::RemoveEmptyEntries)
		if($diffParts.Length -gt 1) {
			[string]$statusRaw = $diffParts[0]

			[string]$originalFilePart = $diffParts[1]
			if($diffParts.Length -gt 2) 
			{
				# file path reflects rename
				[string]$currentFilePart = $diffParts[2]
				$result = [GitDiff]::new($statusRaw, $originalFilePart, $currentFilePart)
			}
			else 
			{
				# file path has not changed
				$result = [GitDiff]::new($statusRaw, $originalFilePart, $originalFilePart)
			}
		}
		return $result
	}

	[string] ToString() {
		return $this.Status.ToString() + ": " + $this.FilePath.ToString()
	}
}

<# model of file-placeholders representing additions, deletions, renames, and manifest #>
class DiffTokenFileInfo {
	DiffTokenFileInfo([GitDiff]$diff) 
	{
		if($null -eq $diff) {
			Write-Fail "diff should not be null"
		}
		$this.Diff = $diff
		$this.FilePath = $null
		$this.ContentFilePath = $diff.OriginalFilePath

		$diffStatus = $this.Diff.Status
		switch ($diffStatus)
		{
			([GitDiffStatus]::Added)
			{
				$this.FilePath = $this.Diff.FilePath + "-added"
				$this.ContentFilePath = $this.GetEmptyTempFile()
				$this.Comparand = [DiffComparand]::Left
				break
			}
			([GitDiffStatus]::Deleted)
			{
				$this.FilePath = $this.Diff.OriginalFilePath + "-deleted"
				$this.ContentFilePath = $this.GetEmptyTempFile()
				$this.Comparand = [DiffComparand]::Right
				break
			}
			([GitDiffStatus]::Renamed)
			{
				$this.FilePath = $this.Diff.OriginalFilePath + "-" + $diff.RenameToken
				$this.ContentFilePath = $this.Diff.OriginalFilePath
				$this.Comparand = [DiffComparand]::Left
				break
			}
			([GitDiffStatus]::Unknown)
			{
				$this.FilePath = [System.IO.Path]::GetFileName($this.Diff.FilePath)
				$this.ContentFilePath = $this.Diff.FilePath
				$this.Comparand = [DiffComparand]::Manifest
				break
			}
			default
			{
				Write-Fail "Unexpected DiffStatus: $diffStatus"
				break
			}
		}
	}
	[GitDiff]$Diff
	[string]$FilePath
	[string]$ContentFilePath
	[DiffComparand]$Comparand

	hidden [string] GetEmptyTempFile() {
		[string]$tempFilePath = [System.IO.Path]::GetTempFileName() # Creates a uniquely named, zero-byte temporary file on disk
		Set-Content -Path "$tempFilePath" -Value $([string]::Empty)
		return $tempFilePath
	}
	
	[string] ToString() {
		return $this.Diff.ToString() + ": " + $this.FilePath.ToString() + " (" + $this.ContentFilePath.ToString() + ")"
	}
}

<# model of git branch attributes #>
class GitBranch {
	GitBranch([string]$branchName) {
		if([string]::IsNullOrEmpty($branchName)) {
			Write-Fail "branchName should not be null"
		}
		$this.BranchName = $branchName
		$this.CommitHash = [GitTool]::GetCommitHash($branchName)
		$this.RemoteUrl = [GitTool]::GetRemoteUrl()
		$this.CommitDate = [GitTool]::GetCommitDate($branchName)
	}
	[string]$BranchName
	[string]$CommitHash
	[System.DateTimeOffset]$CommitDate
	[string]$RemoteUrl

	[string] GetDirectorySafeName() 
	{
		return $this.BranchName.Replace("\\","_").Replace("/", "_")
	}

	[string[]] GetFileContent([string]$repoFilePath)
	{
		return [GitTool]::GetFileContent($this.BranchName, $repoFilePath)
	}

	[string] GetTimestamp() {
		return $(Get-DateTimeAndZone $($this.CommitDate))
	}

	[string] ToString() {
		return $this.BranchName.ToString() + " (" + $this.CommitHash.ToString() + ")" + " [" + $this.RemoteUrl.ToString() + "]" 
	}
}

<# model containing the left/right files for single diff comprised of real file blobs and/or token files #>
class GitDiffFile {
	GitDiffFile([GitDiff]$diff, [System.IO.FileInfo]$leftFile, [System.IO.FileInfo]$rightFile) {
		if($null -eq $diff) {
			Write-Fail "diff should not be null"
		}
		if($null -eq $leftFile) {
			Write-Fail "left file should not be null"
		}
		if($null -eq $rightFile) {
			Write-Fail "right file should not be null"
		}

		$this.Diff = $diff
		$this.LeftFile = $leftFile
		$this.RightFile = $rightFile
	}
	[GitDiff]$Diff
	[System.IO.FileInfo]$LeftFile
	[System.IO.FileInfo]$RightFile

	[string] ToString() {
		return $this.LeftFile.ToString() + [GitDiff]::BranchDiffSeparator + $this.RightFile.ToString()
	}
}

<# model of a directory containing files pulled from a specific branch #>
class GitBranchDirectory {
	GitBranchDirectory([System.IO.DirectoryInfo]$rootDirectory, [GitBranch]$branch, [System.IO.DirectoryInfo]$directory) {
		if($null -eq $rootDirectory) {
			Write-Fail "rootDirectory should not be null"
		}
		if($null -eq $branch) {
			Write-Fail "branch should not be null"
		}
		if($null -eq $directory) {
			Write-Fail "directory should not be null"
		}
		$this.RootDirectory = $rootDirectory
		$this.Branch = $branch
		$this.Directory = $directory
	}
	[GitBranch]$Branch
	[System.IO.DirectoryInfo]$RootDirectory
	[System.IO.DirectoryInfo]$Directory

	[System.IO.FileInfo] WriteFile([string]$repoFilePath)
	{
		if($null -eq $repoFilePath) {
			Write-Fail "repoFilePath should not be null"
		}
		[string[]]$content = $this.Branch.GetFileContent($repoFilePath)
		return [GitBranchDirectory]::WriteFileImpl($this.Directory.FullName, $repoFilePath, $content, $this.Branch.CommitDate)
	}

	[System.IO.FileInfo] WriteFile([DiffTokenFileInfo]$tokenFileInfo)
	{
		if($null -eq $tokenFileInfo) {
			Write-Fail "tokenFileInfo should not be null"
		}
		[string[]]$content = @()
		if([System.IO.Path]::IsPathRooted($tokenFileInfo.ContentFilePath)) 
		{
			$content = [System.IO.File]::ReadAllLines($tokenFileInfo.ContentFilePath)
		}
		else
		{
			$content = $this.Branch.GetFileContent($tokenFileInfo.ContentFilePath)
		}

		return [GitBranchDirectory]::WriteFileImpl($this.Directory.FullName, $tokenFileInfo.FilePath, $content, $this.Branch.CommitDate)
	}

	hidden static [System.IO.FileInfo] WriteFileImpl([string]$directoryPath, [string]$relativeFilePath, [string[]]$content, [System.DateTimeOffset]$commitDate) 
	{
		if([string]::IsNullOrEmpty($directoryPath))
		{
			return $null
		}
		if([string]::IsNullOrEmpty($relativeFilePath))
		{
			return $null
		}
		if(-not [System.IO.Directory]::Exists($directoryPath))
		{
			[System.IO.DirectoryInfo]$branchDirectory = [System.IO.Directory]::CreateDirectory($directoryPath)
			$branchDirectory.CreationTime = $commitDate.DateTime
			$branchDirectory.LastAccessTime = $commitDate.DateTime
			$branchDirectory.LastWriteTime = $commitDate.DateTime
			Remove-Variable branchDirectory
		}

		if($null -eq $content)
		{
			Write-Fail "content should not be null"
		}
		
		if($null -ne $content)
		{
			[System.IO.FileInfo]$fileInfo = [System.IO.FileInfo]::new([System.IO.Path]::Combine($directoryPath, $relativeFilePath))
			[System.IO.DirectoryInfo]$containingDirectory = $fileInfo.Directory
			if(-not $containingDirectory.Exists) {
				$containingDirectory.Create()
				$containingDirectory.CreationTime = $commitDate.DateTime
				$containingDirectory.LastAccessTime = $commitDate.DateTime
				$containingDirectory.LastWriteTime = $commitDate.DateTime
			}
			try {
				[System.IO.File]::WriteAllLines($fileInfo.FullName, $content, [System.Text.Encoding]::UTF8)
				$fileInfo.CreationTime = $commitDate.DateTime
				$fileInfo.LastAccessTime = $commitDate.DateTime
				$fileInfo.LastWriteTime = $commitDate.DateTime
			}
			catch {
				Write-Fail $Error[0]
			}
			return $fileInfo
		}
		return $null
	}

	[string] ToString() {
		return $this.Branch.ToString() + " (" + $this.Directory.ToString() + ")"
	}
}

<# model of files from two different branches for side-by-side comparison; stored in a unique TEMP directory #>
class GitDiffBranch {
	GitDiffBranch([GitBranch]$leftBranch, [GitBranch]$rightBranch) {
		$this.Ctor($leftBranch, $rightBranch)
	}
	GitDiffBranch([string]$leftBranchName, [string]$rightBranchName) {
		$this.Ctor($leftBranchName, $rightBranchName)
	}

    hidden Ctor([string]$leftBranchName, [string]$rightBranchName) 
	{ 
		$this.Ctor([GitBranch]::new($leftBranchName), [GitBranch]::new($rightBranchName)) 
	}
    hidden Ctor([GitBranch]$leftBranch, [GitBranch]$rightBranch) {
		if($null -eq $leftBranch) {
			Write-Fail "leftBranch should not be null"
		}
		if($null -eq $rightBranch) {
			Write-Fail "rightBranch should not be null"
		}
		[string]$uniqueName = Get-UniqueName
		$this.RootDirectory = Get-Temp-SubDirectory $uniqueName

		$this.LeftBranch = [GitBranchDirectory]::new($this.RootDirectory, $leftBranch, $this.RootDirectory.CreateSubdirectory($leftBranch.GetDirectorySafeName()))
		$this.RightBranch = [GitBranchDirectory]::new($this.RootDirectory, $rightBranch, $this.RootDirectory.CreateSubdirectory($rightBranch.GetDirectorySafeName()))
	}
	
	[GitBranchDirectory]$LeftBranch
	[GitBranchDirectory]$RightBranch

	[System.IO.DirectoryInfo]$RootDirectory

	[System.IO.FileInfo] CreateDiffsZip([System.IO.DirectoryInfo]$outputDirectory) 
	{
		return $this.CreateDiffsZip($outputDirectory, $null)
	}

	[System.IO.FileInfo] CreateDiffsZip([System.IO.DirectoryInfo]$outputDirectory, [string]$archiveFileName) 
	{
		if($null -eq $outputDirectory) {
			Write-Fail "outputDirectory should not be null"
		}
		[GitDiffFile[]]$diffFiles = $this.WriteDiffFiles()

        if($diffFiles.Length -eq 0) 
        {
            return $null
        }

		[string[]]$diffFilePaths = @()

		ForEach($diffFile in $diffFiles)
		{
			if($null -ne $diffFile.LeftFile)
			{
				$diffFilePaths += $diffFile.LeftFile.FullName
			}
			
			if($null -ne $diffFile.RightFile -and -not
			  $diffFile.LeftFile.Equals($diffFile.RightFile))
			{
				$diffFilePaths += $diffFile.RightFile.FullName
			}
		}

		if([string]::IsNullOrEmpty($archiveFileName)) 
		{
			[string]$leftName = $this.LeftBranch.Directory.Name
			[string]$rightName = $this.RightBranch.Directory.Name
			$archiveFileName =  "$leftName$([GitDiff]::BranchDiffSeparator)$rightName.zip"
		}
		elseif(-not $(Get-ExtensionEquals $archiveFileName ".zip"))
		{
			$archiveFileName += ".zip"
		}
		
		[string]$archiveFilePath = [System.IO.Path]::Combine($outputDirectory.FullName, $archiveFileName)
		[System.IO.FileInfo]$archiveFile = [System.IO.FileInfo]::new($archiveFilePath)

		[string]$rootedPathToIgnore = $this.RootDirectory.FullName
		[string]$archiveFileName = $archiveFile.Name
		[string]$destinationPath = $archiveFile.Directory.FullName

		try {
			CreateZipFromPathsImpl $diffFilePaths $rootedPathToIgnore $destinationPath $archiveFileName $false
		}
		catch {
			Write-Fail $Error[0]
		}
		finally{
			$this.RootDirectory.Delete($true)
		}
		return $archiveFile
	}

	[GitDiffFile[]] WriteDiffFiles() 
	{
        [GitDiffFile[]]$diffFiles = @()

		[GitDiff[]]$diffs = [GitTool]::GitDiff($this.LeftBranch.Branch.CommitHash, $this.RightBranch.Branch.CommitHash)

        if($diffs.Length -eq 0)
        {
            return $diffFiles
        }

		[string]$leftName = $this.LeftBranch.Directory.Name
		[string]$rightName = $this.RightBranch.Directory.Name
		[string]$argumentsFilePath = $([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "Δ $leftName$([GitDiff]::BranchDiffSeparator)$rightName"))
		Set-Content -Path "$argumentsFilePath" -Value "$leftName $rightName"
		[GitDiff]$argumentsDiff = [GitDiff]::new([GitDiffStatusRaw]::X, $null, $argumentsFilePath)
		$diffs += $argumentsDiff

		[string]$activity = "Pulling files involved in the diff"
		
		[double]$progressFactor = 100.0 / $diffs.Length
		for ($i=0; $i -lt $diffs.Length; $i++) 
		{
			[GitDiff]$diff = $diffs[$i]
			[int]$percentage = $progressFactor * $i
			[string]$fileName = [System.IO.Path]::GetFileName($diff.FilePath)
			Write-Progress -Activity $activity -Status "$percentage% Complete: $fileName" -PercentComplete $percentage
			$diffFiles += $this.WriteDiffFile($diff)
		}
		Write-Progress -Activity $activity -Completed

		return $diffFiles
	}

	[GitDiffFile] WriteDiffFile([GitDiff]$diff)
	{	
		if($null -eq $diff) {
			Write-Fail "diff should not be null"
		}
		[System.IO.FileInfo]$leftFile = $null
		[System.IO.FileInfo]$rightFile = $null
		
		if($null -ne $diff.TokenFileInfo) 
		{
			$diffComparand = $diff.TokenFileInfo.Comparand
			switch ($diffComparand)
			{
				([DiffComparand]::Left)
				{
					$leftFile = $this.LeftBranch.WriteFile($diff.TokenFileInfo)
					$rightFile = $this.RightBranch.WriteFile($diff.FilePath)
					break
				}
				([DiffComparand]::Right)
				{
					$leftFile = $this.LeftBranch.WriteFile($diff.OriginalFilePath)
					$rightFile = $this.RightBranch.WriteFile($diff.TokenFileInfo)
					break
				}
				([DiffComparand]::Manifest)
				{
					[string]$manifestFilePath = [System.IO.Path]::Combine($this.RootDirectory.FullName, $diff.TokenFileInfo.FilePath)
					[string[]]$content = [System.IO.File]::ReadAllLines($diff.TokenFileInfo.ContentFilePath)
					if($(Get-ExtensionEquals $diff.TokenFileInfo.ContentFilePath ".manifest"))
					{
						[string]$leftName = $this.LeftBranch.Directory.Name
						[string]$rightName = $this.RightBranch.Directory.Name
						[string]$prependContent = @()
						$prependContent += "Δ $leftName$([GitDiff]::BranchDiffSeparator)$rightName @ [$($this.RightBranch.Branch.GetTimestamp())]"
						$prependContent += [System.Environment]::NewLine
						[System.IO.File]::WriteAllLines($manifestFilePath, $prependContent, [System.Text.Encoding]::UTF8)
						[System.IO.File]::AppendAllLines($manifestFilePath, $content, [System.Text.Encoding]::UTF8)
					}
					else
					{
						[System.IO.File]::WriteAllLines($manifestFilePath, $content, [System.Text.Encoding]::UTF8)
					}
					[System.IO.FileInfo]$fileInfo = [System.IO.FileInfo]::new($manifestFilePath)
					[System.DateTime]$commitDate = $this.RightBranch.Branch.CommitDate.DateTime
					$fileInfo.CreationTime = $commitDate
					$fileInfo.LastAccessTime = $commitDate
					$fileInfo.LastWriteTime = $commitDate
					$leftFile = $fileInfo
					$rightFile = $fileInfo
					break
				}
				default
				{
					Write-Fail "Unexpected DiffComparand: $diffComparand"

					break
				}
			}
		}
		else
		{
			$leftFile = $this.LeftBranch.WriteFile($diff.OriginalFilePath)
			$rightFile = $this.RightBranch.WriteFile($diff.FilePath)
		}

		[GitDiffFile]$diffFile = [GitDiffFile]::new($diff, $leftFile, $rightFile)
		return $diffFile
	}

	[string] ToString() {
		return $this.LeftBranch.ToString() + [GitDiff]::BranchDiffSeparator + $this.RightBranch.ToString()
	}
}

<# wrapper around select `git <command>` #>
class GitTool {
	static [GitDiff[]] GitDiff() {
		return [GitTool]::GitDiff(1)
	}
	
	static [GitDiff[]] GitDiff([string]$commitHash, [string]$changesCommitHash = $null) {
		[GitDiff[]]$diffs = @()

		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return $diffs
		}

		if([string]::IsNullOrEmpty($commitHash))
		{
			$commitHash = "HEAD~1"
		}

		Write-Info Diffing $commitHash...
		[object[]]$diffsRawArray = @()
		if([string]::IsNullOrEmpty($changesCommitHash))
		{
			$diffsRawArray = git --no-pager diff --find-copies --find-renames --name-status --merge-base $commitHash
		}
		else
		{
			$diffsRawArray = git --no-pager diff --find-copies --find-renames --name-status --merge-base $commitHash $changesCommitHash
		}

		if($null -eq $diffsRawArray) {
			Write-Fail git returned no diffs
			return $diffs
		}

		[System.Collections.Generic.Dictionary[GitDiffStatus, int]]$counts = [System.Collections.Generic.Dictionary[GitDiffStatus, int]]::new()

		for ($i=0; $i -lt $diffsRawArray.Length; $i++) {
			[GitDiff]$diff = [GitDiff]::Parse($diffsRawArray[$i])
			$diffs += $diff
			if(-not $counts.ContainsKey($diff.Status)) {
				$counts[$diff.Status] = 0
			}
			$counts[$diff.Status] = $counts[$diff.Status] + 1
		}

		[object[]]$manifestRawArray = @()
		ForEach($count in $counts.GetEnumerator())
		{
			$key = $count.Key
			$value = $count.Value
			$manifestRawArray += "$key=$value"
		}

		$manifestRawArray += [string]::Empty
		$manifestRawArray += $diffsRawArray

		[string]$manifestFilePath = $([System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "commit# " + $($commitHash + ".manifest")))
		Set-Content -Path $manifestFilePath -Value $manifestRawArray
		[GitDiff]$manifestDiff = [GitDiff]::new([GitDiffStatusRaw]::X, $null, $manifestFilePath)
		
		$diffs += $manifestDiff

		Remove-Variable manifestFilePath
		Remove-Variable manifestDiff

		return $diffs
	}

	static [System.IO.FileInfo] ArchiveBranchDiffs([string]$leftBranchName, [string]$rightBranchName, [System.IO.DirectoryInfo]$outputDirectory) 
	{
		return [GitTool]::ArchiveBranchDiffs($leftBranchName, $rightBranchName, $outputDirectory, $null)
	}

	static [System.IO.FileInfo] ArchiveBranchDiffs([string]$leftBranchName, [string]$rightBranchName, [System.IO.DirectoryInfo]$outputDirectory, [string]$archiveFileName) 
	{
		[GitDiffBranch]$diffBranch = [GitDiffBranch]::new($leftBranchName, $rightBranchName)

		[System.IO.FileInfo]$archiveFile = $diffBranch.CreateDiffsZip($outputDirectory, $archiveFileName)

        if($null -eq $archiveFile)
        {
            return $null
        }
		Write-Info Wrote Archive: """$($archiveFile.FullName)"""
		Write-Success "Extract the archive and use a diff tool that supports directory-diff to review the changes"
		Write-Success ""
		Write-Success "`t e.g. BeyondCompare, Meld, etc."
		return $archiveFile
	}

	static [string] GetRemoteUrl()
	{
		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return ""
		}

		[string]$remoteUrl = git config --get remote.origin.url
        if([string]::IsNullOrEmpty($remoteUrl))
        {
            return $remoteUrl
        }
		return $remoteUrl.Trim()
	}

	static [string] GetCommitHash([string]$branchName)
	{
		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return ""
		}
		if([string]::IsNullOrEmpty($branchName)) {
			Write-Fail "branchName should not be null"
		}

		[string]$commitHash = git rev-parse $branchName
		if([string]::Equals($commitHash, $branchName))
		{
			Write-Fail branch $branchName not found, defaulting to 'HEAD~1'
			#branchName needs become HEAD~1
			$commitHash = $null
		}
		if([string]::IsNullOrEmpty($commitHash))
		{
			$commitHash = git rev-parse "HEAD~1"
		}
		return $commitHash
	}

	static [System.DateTimeOffset] GetCommitDate([string]$branchName) 
	{
		if([string]::IsNullOrEmpty($branchName)) {
			Write-Fail "branchName should not be null"
		}
		#%ci is 'commit date' + 'iso'
		[string]$commitDateRaw = git log -n 1 --pretty="format:%ci" $branchName
		return [System.DateTimeOffset]::Parse($commitDateRaw)
	}

	static [string[]] GetFileContent([string]$branchOrRevision, [string]$repoFilePath) 
	{
		if($null -eq $branchOrRevision) {
			Write-Fail "branchOrRevision should not be null"
		}
		if($null -eq $repoFilePath) {
			Write-Fail "repoFilePath should not be null"
		}

		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return @()
		}

		[string]$showFile = $($branchOrRevision + ":" + $repoFilePath)
		[string[]]$showResult = git --no-pager show $showFile
		if($null -ne $showResult -and $showResult.Length -gt 0 -and $null -ne $showResult[0])
		{
			#remove BOM
			$showResult[0] = $showResult[0].TrimStart("∩╗┐")
		}
		else 
		{
			Write-Warn "No file content found for $branchOrRevision/$repoFilePath"
		}
		return $showResult
	}

	static [bool] SaveFileContent([string]$branchOrRevision, [string]$repoFilePath, [System.IO.DirectoryInfo]$directoryRoot)
	{
		if($null -eq $branchOrRevision) {
			Write-Fail "branchOrRevision should not be null"
		}
		if($null -eq $repoFilePath) {
			Write-Fail "repoFilePath should not be null"
		}
		if($null -eq $directoryRoot) {
			Write-Fail "directoryRoot should not be null"
		}
		if(-not $directoryRoot.Exists)
		{
			$directoryRoot.Create()
		}

		[string[]]$content = [GitTool]::GetFileContent($branchOrRevision, $repoFilePath)

		if($null -ne $content -and $content.Length -gt 0) 
		{
			[System.IO.FileInfo]$filePath = [System.IO.Path]::Combine($directoryRoot.FullName, $repoFilePath)
			[System.IO.File]::WriteAllLines($filePath, $content, [System.Text.Encoding]::UTF8)
			return $true
		}
		
		return $false
	}

	static [Void] Clean()
	{
		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return
		}

		#https://stackoverflow.com/questions/28720151/git-gc-aggressive-vs-git-repack
		git reflog expire --expire=now --all
		git gc
		git repack -Ad      # kills in-pack garbage
		git prune           # kills loose garbage
	}
}

Write-Info Lets create an archive of delta between two branches...
Write-Info ""

if([string]::IsNullOrEmpty($repositoryPath))
{
    $repositoryPath = Read-Prompt "Enter the path to the root of a `git` repository"
	$repositoryPath = [System.IO.Path]::GetFullPath($repositoryPath)
}

if([string]::IsNullOrEmpty($leftBranch))
{
    $leftBranch = Read-Prompt "Enter the name of the LEFT branch for comparison"
}

if([string]::IsNullOrEmpty($rightBranch))
{
    $rightBranch = Read-Prompt "Enter the name of the RIGHT branch for comparison"
}

if([string]::IsNullOrEmpty($outputDirectory))
{
    $outputDirectory = Read-Prompt "Enter the path where the ZIP will be created"
	$outputDirectory = [System.IO.Path]::GetFullPath($outputDirectory)
}

if([string]::IsNullOrEmpty($archiveFileName))
{
    $specifyArchiveName = Read-Prompt "Do you want to name the ZIP file? (Y/N)"

    if([string]::Equals($specifyArchiveName, "Y", [System.StringComparison]::InvariantCultureIgnoreCase) -or 
       [string]::Equals($specifyArchiveName, "YES", [System.StringComparison]::InvariantCultureIgnoreCase))
    {
        $archiveFileName = Read-Prompt "Enter a name for the ZIP file that will be created"
    }
}

Push-Location -Path $repositoryPath

[GitTool]::ArchiveBranchDiffs($leftBranch, $rightBranch, $outputDirectory, $archiveFileName)

Pop-Location