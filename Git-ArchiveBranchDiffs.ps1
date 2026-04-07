<#
    .SYNOPSIS
    Creates a ZIP archive containing the diff/delta between two related branches

    .DESCRIPTION
    Creates a ZIP archive containing the diff/delta between two related branches.
    Ensure the following are on the PATH environment variable: { git }
    Supports tab-completion for repository paths and branch names.

    .PARAMETER repositoryPath
    Specifies directory path to the root of a git repository.
    Tab-completes to directories containing a .git folder.

    .PARAMETER leftBranch
    Specifies a branch, tag, or commit ref to be the left-side of a diff comparison.
    Tab-completes to available branches, tags, and stashes.

    .PARAMETER rightBranch
    Specifies a branch, tag, or commit ref to be the right-side of a diff comparison.
    Tab-completes to available branches, tags, and stashes.

    .PARAMETER outputDirectory
    Specifies the directory path where the ZIP file will be created.

    .PARAMETER archiveFileName
    [Optional] Specifies the name of the ZIP file that will be created.

    .PARAMETER nonInteractive
    [Optional] When set, uses smart defaults instead of prompting:
    repositoryPath defaults to current directory, leftBranch to the default remote branch,
    rightBranch to the currently checked-out branch, outputDirectory to current directory.

    .PARAMETER workingTree
    [Optional] Compare uncommitted working tree changes against the left branch.
    Mutually exclusive with -staged and -rightBranch.

    .PARAMETER staged
    [Optional] Compare staged (indexed) changes against the left branch.
    Mutually exclusive with -workingTree and -rightBranch.

    .PARAMETER threeWay
    [Optional] Produce a three-way diff with base, left, and right directories.
    Shows what each side changed relative to the merge-base.
    Mutually exclusive with -workingTree and -staged.

    .EXAMPLE
    PS> ./Git-ArchiveBranchDiffs.ps1 -repositoryPath /c/myRepo -leftBranch master -rightBranch f/myBranch -outputDirectory /tmp

    .EXAMPLE
    PS> ./Git-ArchiveBranchDiffs.ps1 -nonInteractive
#>
Param (
    [parameter(Mandatory=$false)]
	[ArgumentCompleter({
		param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
		Get-ChildItem -Path "$wordToComplete*" -Directory -ErrorAction SilentlyContinue |
			Where-Object { Test-Path (Join-Path $_.FullName ".git") } |
			ForEach-Object { $_.FullName }
	})]
	[string]$repositoryPath,

    [parameter(Mandatory=$false)]
	[ArgumentCompleter({
		param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
		$repoPath = $fakeBoundParameters['repositoryPath']
		if([string]::IsNullOrWhiteSpace($repoPath)) { $repoPath = (Get-Location).Path }
		if(Test-Path (Join-Path $repoPath ".git")) {
			Push-Location $repoPath
			try { Get-GitCompletionCandidates $wordToComplete }
			finally { Pop-Location }
		}
	})]
	[string]$leftBranch,

    [parameter(Mandatory=$false)]
	[ArgumentCompleter({
		param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
		$repoPath = $fakeBoundParameters['repositoryPath']
		if([string]::IsNullOrWhiteSpace($repoPath)) { $repoPath = (Get-Location).Path }
		if(Test-Path (Join-Path $repoPath ".git")) {
			Push-Location $repoPath
			try { Get-GitCompletionCandidates $wordToComplete }
			finally { Pop-Location }
		}
	})]
	[string]$rightBranch,

    [parameter(Mandatory=$false)]
	[System.IO.DirectoryInfo]$outputDirectory,

	[parameter(Mandatory=$false)]
	[string]$archiveFileName = $null,

	[parameter(Mandatory=$false)]
	[switch]$nonInteractive,

	[parameter(Mandatory=$false)]
	[switch]$workingTree,

	[parameter(Mandatory=$false)]
	[switch]$staged,

	[parameter(Mandatory=$false)]
	[switch]$threeWay
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
    [string]$message = $args -join ' '
    Write-Host $message -ForegroundColor Red -BackgroundColor Black
    throw $message
}

Function Read-Prompt {
    [OutputType([string])]
    Param (
        [Parameter(ValueFromPipeline = $true, Mandatory=$true)]
        [string]
        $prompt
    )
    $(Write-Host -ForegroundColor Blue $($prompt + ": ")) + $(Read-Host)
}

Function Get-PathCompletions {
    [OutputType([string[]])]
    Param (
        [Parameter(Mandatory=$true)]
        [string]$partialPath
    )

    [string]$directory = ""
    [string]$prefix = ""

    if($partialPath.EndsWith("\") -or $partialPath.EndsWith("/"))
    {
        $directory = $partialPath
        $prefix = ""
    }
    elseif($partialPath.Contains("\") -or $partialPath.Contains("/"))
    {
        $directory = [System.IO.Path]::GetDirectoryName($partialPath)
        $prefix = [System.IO.Path]::GetFileName($partialPath)
    }
    else
    {
        $directory = "."
        $prefix = $partialPath
    }

    if([string]::IsNullOrEmpty($directory) -or -not [System.IO.Directory]::Exists($directory)) { return @() }

    [string[]]$matches = @(Get-ChildItem -Path $directory -Directory -ErrorAction SilentlyContinue |
        Where-Object { $prefix.Length -eq 0 -or $_.Name.StartsWith($prefix, [System.StringComparison]::InvariantCultureIgnoreCase) } |
        ForEach-Object {
            if($directory -eq ".") { $_.Name }
            else { [System.IO.Path]::Combine($directory, $_.Name) }
        })
    return $matches
}

Function Get-GitCompletionCandidates {
    [OutputType([string[]])]
    Param (
        [Parameter(Mandatory=$false)]
        [string]$wordToComplete = ""
    )
    [System.Collections.Generic.List[string]]$results = [System.Collections.Generic.List[string]]::new()

    foreach($b in [GitTool]::GetBranches($true)) { $results.Add($b) }
    foreach($t in [GitTool]::GetTags())           { $results.Add($t) }
    foreach($s in [GitTool]::GetStashes())        { $results.Add($s) }

    if($wordToComplete.Length -gt 0) {
        return @($results | Where-Object {
            $_.StartsWith($wordToComplete, [System.StringComparison]::InvariantCultureIgnoreCase)
        })
    }
    return $results.ToArray()
}

Function Read-PromptWithCompletion {
    [OutputType([string])]
    Param (
        [Parameter(Mandatory=$true)]
        [string]$prompt,
        [Parameter(Mandatory=$false)]
        [string[]]$candidates = @(),
        [Parameter(Mandatory=$false)]
        [switch]$pathMode
    )

    Write-Host -ForegroundColor Blue $($prompt + ": ") -NoNewline

    [string]$userInput = ""
    [string]$ghost = ""

    while($true)
    {
        # Resolve candidates: dynamic for paths, static for everything else
        [string[]]$activeCandidates = $candidates
        if($pathMode -and $userInput.Length -gt 0)
        {
            $activeCandidates = @(Get-PathCompletions $userInput)
        }

        # Find best matching candidate for current input
        [string]$ghost = ""
        if($userInput.Length -gt 0 -and $activeCandidates.Count -gt 0)
        {
            foreach($c in $activeCandidates)
            {
                if($c.StartsWith($userInput, [System.StringComparison]::InvariantCultureIgnoreCase))
                {
                    $ghost = $c.Substring($userInput.Length)
                    break
                }
            }
        }

        # Show ghost text (greyed out completion hint)
        if($ghost.Length -gt 0)
        {
            Write-Host $ghost -ForegroundColor DarkGray -NoNewline
            $pos = $Host.UI.RawUI.CursorPosition
            $pos.X -= $ghost.Length
            $Host.UI.RawUI.CursorPosition = $pos
        }

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

        # Clear ghost text before processing keystroke
        if($ghost.Length -gt 0)
        {
            Write-Host (" " * $ghost.Length) -NoNewline
            $pos = $Host.UI.RawUI.CursorPosition
            $pos.X -= $ghost.Length
            $Host.UI.RawUI.CursorPosition = $pos
        }

        if($key.VirtualKeyCode -eq [System.ConsoleKey]::Enter)
        {
            Write-Host ""
            return $userInput
        }
        elseif($key.VirtualKeyCode -eq [System.ConsoleKey]::Tab)
        {
            if($ghost.Length -gt 0)
            {
                Write-Host $ghost -ForegroundColor White -NoNewline
                $userInput += $ghost
            }
        }
        elseif($key.VirtualKeyCode -eq [System.ConsoleKey]::Backspace)
        {
            if($userInput.Length -gt 0)
            {
                $userInput = $userInput.Substring(0, $userInput.Length - 1)
                Write-Host "`b `b" -NoNewline
            }
        }
        elseif($key.VirtualKeyCode -eq [System.ConsoleKey]::Escape)
        {
            # Clear entire input
            if($userInput.Length -gt 0)
            {
                Write-Host ("`b `b" * $userInput.Length) -NoNewline
                $userInput = ""
            }
        }
        elseif($key.Character -ne 0 -and -not [System.Char]::IsControl($key.Character))
        {
            $userInput += $key.Character
            Write-Host $key.Character -ForegroundColor White -NoNewline
        }
    }
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
    [Parameter(ValueFromPipeline = $true, Mandatory=$true)]
    [System.IO.FileSystemInfo]$fileSystemInfo
)
{
    [string]$userName = [System.Environment]::GetEnvironmentVariable("USERNAME")
    [string]$fullPath = """" + $fileSystemInfo.FullName + """"
    # takeown /F %1 /R
    Start-Process -FilePath takeown.exe -ArgumentList ("/F $fullPath /R") -Verb runas | Out-Null
    # icacls %1 /grant %USERNAME%:(OI)(CI)F /T
    Start-Process -FilePath icacls.exe -ArgumentList ("$fullPath /grant $userName\:(OI)(CI)F /T") -Verb runas | Out-Null
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

    if ([System.String]::IsNullOrWhiteSpace($destinationPath))
    {
        $destinationPath = $commandPath
    }
    if ([System.String]::IsNullOrWhiteSpace($archiveFileName))
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
        if ([System.String]::IsNullOrWhiteSpace($rootedPathToIgnore))
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
    [string]$nestInDirectoryOverride = "",
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

    if ([System.String]::IsNullOrWhiteSpace($sourcePath))
    {
        $sourcePath = $commandPath
    }
    if ([System.String]::IsNullOrWhiteSpace($destinationPath))
    {
        $destinationPath = $commandPath
    }
    if ([System.String]::IsNullOrWhiteSpace($archiveFileName))
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

			if([string]::IsNullOrWhiteSpace($nestInDirectoryOverride) -eq $false)
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

				if([string]::IsNullOrWhiteSpace($nestInDirectoryOverride) -eq $false)
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
    [parameter(Mandatory=$true)]
    [string]$sourceArchivePath,
    [parameter(Mandatory=$true)]
    [string]$destinationPath
) {
    [System.IO.Compression.ZipFile]::ExtractToDirectory($sourceArchivePath, $destinationPath)
}

function Convert-NewlinesToUnix(
	[parameter(ValueFromPipeline = $true, Mandatory=$true)]
	[string] $fileName) 
{
    (Get-Content $fileName).Replace("`r`n", "`n") | Out-File $fileName -Encoding utf8
    return
}


function Convert-NewlinesToWindows(
	[parameter(ValueFromPipeline = $true, Mandatory=$true)]
	[string] $fileName) 
{
    (Get-Content $fileName).Replace("`n", "`r`n") | Out-File $fileName -Encoding utf8
    return
}

function Get-Temp-SubDirectory {
    [OutputType([System.IO.DirectoryInfo])]
    Param (
        [parameter(ValueFromPipeline = $true, Mandatory=$true)]
        [string]
        $subDirectory
    )
    [System.IO.DirectoryInfo]$tempDirectory = [System.IO.DirectoryInfo]::new([System.IO.Path]::GetTempPath())
    [System.IO.DirectoryInfo]$tempSubDirectory = $tempDirectory.CreateSubdirectory($subDirectory)
    return $tempSubDirectory
}

function Get-IsDirectory {
	[OutputType([bool])]
	Param (
        [parameter(ValueFromPipeline = $true, Mandatory=$true)]	
        [System.IO.FileSystemInfo]
		$fileSystemInfo
    )
    return $null -ne $fileSystemInfo -and ($fileSystemInfo.GetType().IsAssignableFrom([System.IO.DirectoryInfo]))
}

function Get-ParentDirectory {
	[OutputType([System.IO.DirectoryInfo])]
	Param (
        [parameter(ValueFromPipeline = $true, Mandatory=$true)]
        [System.IO.FileSystemInfo]
		$fileSystemInfo
    )
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
        [parameter(ValueFromPipeline = $true, Mandatory=$true)]
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

    if([string]::IsNullOrWhiteSpace($sharedPath))
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
        [parameter(ValueFromPipeline = $true, Mandatory=$true)]
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

class TempDirectoryScope {
	TempDirectoryScope([string]$subDirectory) 
	{
		if([string]::IsNullOrWhiteSpace($subDirectory)) {
			$this.Directory = Get-UniqueName | Get-Temp-SubDirectory
		}
		else {
			$this.Directory = Get-Temp-SubDirectory $subDirectory
		}
	}
	[System.IO.DirectoryInfo]$Directory

	[string] GetTempPath() {
		return $this.Directory.FullName
	}

	[System.IO.DirectoryInfo] GetSubDirectory([string]$directoryName) {
		
		if([string]::IsNullOrWhiteSpace($directoryName)) {
			$directoryName = Get-UniqueName
		}
		[System.IO.DirectoryInfo]$subDirectory = [System.IO.Path]::Combine($this.Directory.FullName, $directoryName)
		return $subDirectory;
	}
	
	[string] GetEmptyTempFile() {
		[string]$fileName = Get-UniqueName
		[string]$tempFilePath = [System.IO.Path]::Combine($this.Directory.FullName, $fileName)
		[System.IO.File]::Create($tempFilePath).Close()
		return $tempFilePath
	}

	[void] Cleanup() {
		$this.Directory.Delete($true)
	}
	
	[string] ToString() {
		return $this.Directory.FullName
	}
}

[TempDirectoryScope]$script:Temp = [TempDirectoryScope]::new($null)

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

enum RevisionKind
{
	Commit    # normal branch/tag/hash — has CommitHash and CommitDate
	WorkTree  # uncommitted working directory
	Staged    # staged index (git add'd but not committed)
}
#endregion Enums

<# model of line items returned by `git diff` #>
class GitDiff {
	GitDiff([string]$statusRaw, [string]$originalFilePath, [string]$filePath) {
		if($null -eq $statusRaw) {
			Write-Fail "statusRaw should not be null"
		}
		# originalFilePath is legitimately null for manifest entries (status X)
		if($null -eq $originalFilePath -and $statusRaw -ne [GitDiffStatusRaw]::X.ToString()) {
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
			#e.g.  R095 → token "R095"
			$this.RenameToken = $statusRaw
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
		if([string]::IsNullOrWhiteSpace($diffRaw)) {
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
				$this.ContentFilePath = $script:Temp.GetEmptyTempFile()
				$this.Comparand = [DiffComparand]::Left
				break
			}
			([GitDiffStatus]::Deleted)
			{
				$this.FilePath = $this.Diff.OriginalFilePath + "-deleted"
				$this.ContentFilePath = $script:Temp.GetEmptyTempFile()
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
	
	[string] ToString() {
		return $this.Diff.ToString() + ": " + $this.FilePath.ToString() + " (" + $this.ContentFilePath.ToString() + ")"
	}
}

<# model of git branch attributes #>
class GitBranch {
	GitBranch([string]$branchName) {
		if([string]::IsNullOrWhiteSpace($branchName)) {
			Write-Fail "branchName should not be null"
		}
		$this.Kind = [RevisionKind]::Commit
		$this.BranchName = $branchName
		$this.RemoteName = [GitTool]::GetRemoteName()
		$this.ResolveLocalOrRemoteCommit($this.RemoteName, $this.BranchName)
		$this.RemoteUrl = [GitTool]::GetRemoteUrl()
		$this.CommitDate = [GitTool]::GetCommitDate($this.BranchName)
	}

	static [GitBranch] ForWorkTree() {
		[GitBranch]$branch = [GitBranch]::CreateSpecial("WORKING-TREE", [RevisionKind]::WorkTree)
		return $branch
	}

	static [GitBranch] ForStaged() {
		[GitBranch]$branch = [GitBranch]::CreateSpecial("STAGED", [RevisionKind]::Staged)
		return $branch
	}

	hidden static [GitBranch] CreateSpecial([string]$name, [RevisionKind]$kind) {
		# Use default constructor bypass via PSObject trick — set fields manually
		[GitBranch]$branch = [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject([GitBranch])
		$branch.Kind = $kind
		$branch.BranchName = $name
		$branch.CommitHash = $null
		$branch.CommitDate = [System.DateTimeOffset]::Now
		$branch.RemoteName = ""
		$branch.RemoteUrl = ""
		return $branch
	}

	[RevisionKind]$Kind
	[string]$BranchName
	[string]$CommitHash
	[System.DateTimeOffset]$CommitDate
	[string]$RemoteName
	[string]$RemoteUrl

	hidden [void] ResolveLocalOrRemoteCommit([string]$remoteName, [string]$branchName)
	{
		$this.CommitHash = [GitTool]::GetCommitHash($branchName)

		if([string]::IsNullOrWhiteSpace($this.CommitHash))
		{
			if($this.IsLocalBranch() -and -not [string]::IsNullOrWhiteSpace($remoteName))
			{
				[string]$remoteBranch = $remoteName + "/" + $branchName
				$this.CommitHash = git rev-parse $remoteBranch 2>$null
				if($LASTEXITCODE -ne 0 -or [string]::Equals($this.CommitHash, $remoteBranch))
				{
					$this.CommitHash = $null
				}
				else
				{
					Write-Warn "Did not find local branch '$branchName' but will use remote branch '$remoteBranch'"
					$this.BranchName = $remoteBranch
				}
			}

			if([string]::IsNullOrWhiteSpace($this.CommitHash))
			{
				Write-Warn "branch '$($this.BranchName)' not found, defaulting to 'HEAD'"
				$this.CommitHash = git rev-parse "HEAD" 2>$null
				if($LASTEXITCODE -ne 0)
				{
					Write-Fail "Could not resolve HEAD; is this a valid git repository?"
				}
			}
		}
	}

	[bool] IsLocalBranch() 
	{
		if($this.BranchName.StartsWith($this.RemoteName + "/"))
		{
			return $false
		}
		return $true
	}

	[string] GetDirectorySafeName()
	{
		return $this.BranchName.Replace("\\","_").Replace("/", "_").Replace("~","_").Replace("^","_").Replace("@","_").Replace("{","_").Replace("}","_")
	}

	[byte[]] GetFileContent([string]$repoFilePath)
	{
		if($this.Kind -eq [RevisionKind]::WorkTree) {
			[string]$fullPath = [System.IO.Path]::GetFullPath($repoFilePath)
			if([System.IO.File]::Exists($fullPath)) {
				return [System.IO.File]::ReadAllBytes($fullPath)
			}
			return $null
		}
		if($this.Kind -eq [RevisionKind]::Staged) {
			return [GitTool]::GetFileContent("", $repoFilePath)
		}
		return [GitTool]::GetFileContent($this.BranchName, $repoFilePath)
	}

	[string] GetTimestamp() {
		if($this.Kind -ne [RevisionKind]::Commit) {
			return "(uncommitted)"
		}
		return $(Get-DateTimeAndZone $($this.CommitDate))
	}

	[string] ToString() {
		if($this.Kind -ne [RevisionKind]::Commit) {
			return $this.BranchName
		}
		return $this.BranchName.ToString() + " (" + $this.CommitHash.ToString() + ")" + " [" + $this.RemoteUrl.ToString() + "]"
	}
}

<# model containing the left/right files for single diff comprised of real file blobs and/or token files #>
class GitDiffFile {
	GitDiffFile([GitDiff]$diff, [System.IO.FileInfo]$leftFile, [System.IO.FileInfo]$rightFile) {
		# diff may be null in three-way mode
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
		[byte[]]$content = $this.Branch.GetFileContent($repoFilePath)

		if($null -eq $content)
		{
			#this is usually because the file was deleted but not as part of the commit of the right-side
			$content = @() #not null
			[string]$missingFilePath = $repoFilePath + "-missing"

			return [GitBranchDirectory]::WriteFileImpl($this.Directory.FullName, $missingFilePath, $content, $this.Branch.CommitDate)
		}

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
			$content = [System.IO.File]::ReadAllBytes($tokenFileInfo.ContentFilePath)
		}
		else
		{
			$content = $this.Branch.GetFileContent($tokenFileInfo.ContentFilePath)
		}

		return [GitBranchDirectory]::WriteFileImpl($this.Directory.FullName, $tokenFileInfo.FilePath, $content, $this.Branch.CommitDate)
	}

	hidden static [System.IO.FileInfo] WriteFileImpl([string]$directoryPath, [string]$relativeFilePath, [byte[]]$content, [System.DateTimeOffset]$commitDate) 
	{
		if([string]::IsNullOrWhiteSpace($directoryPath))
		{
			return $null
		}
		if([string]::IsNullOrWhiteSpace($relativeFilePath))
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
				[System.IO.File]::WriteAllBytes($fileInfo.FullName, $content)
				$fileInfo.CreationTime = $commitDate.DateTime
				$fileInfo.LastAccessTime = $commitDate.DateTime
				$fileInfo.LastWriteTime = $commitDate.DateTime
			}
			catch {
				Write-Warn "Failed to write file: $($Error[0])"
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
		$this.ThreeWayMode = $false
		$this.RootDirectory = $script:Temp.GetSubDirectory($null)

		$this.LeftBranch = [GitBranchDirectory]::new($this.RootDirectory, $leftBranch, $this.RootDirectory.CreateSubdirectory($leftBranch.GetDirectorySafeName()))
		$this.RightBranch = [GitBranchDirectory]::new($this.RootDirectory, $rightBranch, $this.RootDirectory.CreateSubdirectory($rightBranch.GetDirectorySafeName()))
	}

	static [GitDiffBranch] ForThreeWay([string]$leftBranchName, [string]$rightBranchName) {
		[GitBranch]$leftRef = [GitBranch]::new($leftBranchName)
		[GitBranch]$rightRef = [GitBranch]::new($rightBranchName)

		# Compute merge-base
		[string]$mergeBaseHash = [GitTool]::GetMergeBase($leftRef.CommitHash, $rightRef.CommitHash)
		if([string]::IsNullOrWhiteSpace($mergeBaseHash)) {
			Write-Fail "Cannot create three-way diff: no common ancestor found between branches (unrelated histories?)"
		}

		[GitBranch]$mergeBaseBranch = [GitBranch]::new($mergeBaseHash)

		[GitDiffBranch]$result = [GitDiffBranch]::new($leftRef, $rightRef)
		$result.ThreeWayMode = $true
		$result.BaseBranch = [GitBranchDirectory]::new($result.RootDirectory, $mergeBaseBranch, $result.RootDirectory.CreateSubdirectory("base"))
		return $result
	}

	[GitBranchDirectory]$LeftBranch
	[GitBranchDirectory]$RightBranch
	[GitBranchDirectory]$BaseBranch
	[bool]$ThreeWayMode
	[System.IO.FileInfo]$HistoryFile
	[System.IO.FileInfo]$PatchFile

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
		if(-not $outputDirectory.Exists) {
			$outputDirectory.Create()	
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
				$diffFile.RightFile.Equals($diffFile.LeftFile))
			{
				$diffFilePaths += $diffFile.RightFile.FullName
			}
		}

		# Include base directory files in three-way mode
		if($this.ThreeWayMode -and $null -ne $this.BaseBranch -and $this.BaseBranch.Directory.Exists)
		{
			[System.IO.FileInfo[]]$baseFiles = $this.BaseBranch.Directory.GetFiles("*", [System.IO.SearchOption]::AllDirectories)
			foreach($baseFile in $baseFiles) {
				$diffFilePaths += $baseFile.FullName
			}
		}

		# Include history file in archive if generated
		if($null -ne $this.HistoryFile -and $this.HistoryFile.Exists)
		{
			$diffFilePaths += $this.HistoryFile.FullName
		}

		# Include patch file in archive if generated
		if($null -ne $this.PatchFile -and $this.PatchFile.Exists)
		{
			$diffFilePaths += $this.PatchFile.FullName
		}

		if([string]::IsNullOrWhiteSpace($archiveFileName))
		{
			[string]$leftName = $this.LeftBranch.Directory.Name
			[string]$rightName = $this.RightBranch.Directory.Name
			[string]$threeWayPrefix = $(if($this.ThreeWayMode) { "3way " } else { "" })
			$archiveFileName = "$threeWayPrefix$leftName$([GitDiff]::BranchDiffSeparator)$rightName.zip"
		}
		elseif(-not $(Get-ExtensionEquals $archiveFileName ".zip"))
		{
			$archiveFileName += ".zip"
		}
		
		[string]$archiveFilePath = [System.IO.Path]::Combine($outputDirectory.FullName, $archiveFileName)
		[System.IO.FileInfo]$archiveFile = [System.IO.FileInfo]::new($archiveFilePath)

		[string]$rootedPathToIgnore = $this.RootDirectory.FullName
		[string]$zipFileName = $archiveFile.Name
		[string]$destinationPath = $archiveFile.Directory.FullName

		try {
			CreateZipFromPathsImpl $diffFilePaths $rootedPathToIgnore $destinationPath $zipFileName $false
		}
		catch {
			Write-Fail "Failed to create archive: $($Error[0])"
		}
		finally{
			$this.RootDirectory.Delete($true)
		}
		return $archiveFile
	}

	[System.IO.FileInfo] WriteHistoryFile([GitDiff[]]$diffs)
	{
		[string]$leftHash = $this.LeftBranch.Branch.CommitHash
		[string]$rightHash = $this.RightBranch.Branch.CommitHash

		[string]$mergeBase = [GitTool]::GetMergeBase($leftHash, $rightHash)
		if([string]::IsNullOrWhiteSpace($mergeBase))
		{
			Write-Warn "Could not determine merge-base for history; skipping HISTORY.md"
			return $null
		}
		[string]$mergeBaseShort = $mergeBase.Substring(0, [System.Math]::Min(8, $mergeBase.Length))

		# Collect file paths from the diff set (exclude manifest entries)
		[System.Collections.Generic.List[string]]$filePaths = [System.Collections.Generic.List[string]]::new()
		foreach($diff in $diffs)
		{
			if($diff.Status -eq [GitDiffStatus]::Unknown) { continue }
			if(-not [string]::IsNullOrWhiteSpace($diff.FilePath) -and -not $filePaths.Contains($diff.FilePath))
			{
				$filePaths.Add($diff.FilePath)
			}
			if(-not [string]::IsNullOrWhiteSpace($diff.OriginalFilePath) -and
			   -not [string]::Equals($diff.OriginalFilePath, $diff.FilePath) -and
			   -not $filePaths.Contains($diff.OriginalFilePath))
			{
				$filePaths.Add($diff.OriginalFilePath)
			}
		}

		if($filePaths.Count -eq 0) { return $null }

		[string[]]$fileArgs = $filePaths.ToArray()

		# Fast lookup for "is this file in the archive's diff set?"
		[System.Collections.Generic.HashSet[string]]$diffSet =
			[System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		foreach($fp in $fileArgs) { [void]$diffSet.Add($fp) }

		# Get structured commits on each side that touched diff'd files
		[string]$rightBranchName = $this.RightBranch.Branch.BranchName
		[GitLogEntry[]]$rightLog = [GitTool]::GetLog("$mergeBase..$rightHash", 0, $fileArgs)

		[string]$leftBranchName = $this.LeftBranch.Branch.BranchName
		[GitLogEntry[]]$leftLog = [GitTool]::GetLog("$mergeBase..$leftHash", 0, $fileArgs)

		if($rightLog.Length -eq 0 -and $leftLog.Length -eq 0) { return $null }

		# Churn stats: merge-base → each side, limited to diff-set files
		[GitDiffStat[]]$rightStats = @([GitTool]::GetDiffStat($mergeBase, $rightHash) |
			Where-Object { $diffSet.Contains($_.FilePath) })
		[GitDiffStat[]]$leftStats = @([GitTool]::GetDiffStat($mergeBase, $leftHash) |
			Where-Object { $diffSet.Contains($_.FilePath) })

		[int]$perCommitFilesCap = 200  # avoid running diff-tree hundreds of times on giant histories

		# Build history content
		[System.Collections.Generic.List[string]]$lines = [System.Collections.Generic.List[string]]::new()
		$lines.Add("# Commit History (files in diff only)")
		$lines.Add("")
		$lines.Add("Merge-base: $mergeBaseShort")
		$lines.Add("")

		# Churn summary section
		if($rightStats.Length -gt 0 -or $leftStats.Length -gt 0)
		{
			$lines.Add("## Churn Summary")
			$lines.Add("")
			if($rightStats.Length -gt 0) {
				$lines.Add("### $rightBranchName (vs merge-base)")
				$lines.Add("")
				$this.AppendChurnTable($lines, $rightStats)
				$lines.Add("")
			}
			if($leftStats.Length -gt 0) {
				$lines.Add("### $leftBranchName (vs merge-base)")
				$lines.Add("")
				$this.AppendChurnTable($lines, $leftStats)
				$lines.Add("")
			}
		}

		if($rightLog.Length -gt 0)
		{
			$lines.Add("## $rightBranchName ($($rightLog.Length) commits)")
			$lines.Add("")
			$this.AppendCommitBlocks($lines, $rightLog, $diffSet, $perCommitFilesCap)
			$lines.Add("")
		}

		if($leftLog.Length -gt 0)
		{
			$lines.Add("## $leftBranchName ($($leftLog.Length) commits)")
			$lines.Add("")
			$this.AppendCommitBlocks($lines, $leftLog, $diffSet, $perCommitFilesCap)
			$lines.Add("")
		}

		[string]$historyFilePath = [System.IO.Path]::Combine($this.RootDirectory.FullName, "HISTORY.md")
		[System.IO.File]::WriteAllLines($historyFilePath, $lines.ToArray(), [System.Text.Encoding]::UTF8)

		[System.IO.FileInfo]$fileInfo = [System.IO.FileInfo]::new($historyFilePath)
		[System.DateTime]$commitDate = $this.RightBranch.Branch.CommitDate.DateTime
		$fileInfo.CreationTime = $commitDate
		$fileInfo.LastAccessTime = $commitDate
		$fileInfo.LastWriteTime = $commitDate

		return $fileInfo
	}

	# Appends a top-10-by-churn markdown table to $lines.
	hidden [Void] AppendChurnTable([System.Collections.Generic.List[string]]$lines, [GitDiffStat[]]$stats)
	{
		[GitDiffStat[]]$ranked = @($stats | Sort-Object -Descending -Property @{
			Expression = { if($_.IsBinary) { -1 } else { $_.Insertions + $_.Deletions } }
		})
		[int]$total = $ranked.Length
		[int]$binaryCount = @($ranked | Where-Object { $_.IsBinary }).Length
		[int]$topN = [System.Math]::Min(10, $total)

		$lines.Add("| Insertions | Deletions | File |")
		$lines.Add("|-----------:|----------:|------|")
		for([int]$i = 0; $i -lt $topN; $i++) {
			[GitDiffStat]$s = $ranked[$i]
			[string]$insCol = $(if($s.IsBinary) { "binary" } else { "+$($s.Insertions)" })
			[string]$delCol = $(if($s.IsBinary) { "-" } else { "-$($s.Deletions)" })
			[string]$pathCol = $s.FilePath
			if(-not [string]::IsNullOrEmpty($s.OriginalFilePath)) {
				$pathCol = "$($s.OriginalFilePath) → $($s.FilePath)"
			}
			$lines.Add("| $insCol | $delCol | $pathCol |")
		}
		$lines.Add("")
		[string]$footer = "(Top $topN of $total files by churn"
		if($binaryCount -gt 0) { $footer += "; $binaryCount binary file" + $(if($binaryCount -eq 1) { "" } else { "s" }) }
		$footer += ".)"
		$lines.Add($footer)
	}

	# Appends per-commit blocks with filtered touched-file lists to $lines.
	hidden [Void] AppendCommitBlocks(
		[System.Collections.Generic.List[string]]$lines,
		[GitLogEntry[]]$log,
		[System.Collections.Generic.HashSet[string]]$diffSet,
		[int]$perCommitFilesCap)
	{
		[bool]$includePerCommitFiles = ($log.Length -le $perCommitFilesCap)
		foreach($entry in $log) {
			$lines.Add("- $entry")
			if(-not $includePerCommitFiles) { continue }
			[GitDiff[]]$touched = [GitTool]::GetCommitFiles($entry.Hash)
			foreach($d in $touched) {
				if($d.Status -eq [GitDiffStatus]::Unknown) { continue }
				[string]$path = $d.FilePath
				[string]$origPath = $d.OriginalFilePath
				[bool]$inSet = $diffSet.Contains($path) -or
					(-not [string]::IsNullOrEmpty($origPath) -and $diffSet.Contains($origPath))
				if(-not $inSet) { continue }
				[string]$statusChar = $d.Status.ToString().Substring(0, 1)
				[string]$display = $path
				if(-not [string]::IsNullOrEmpty($origPath) -and -not [string]::Equals($origPath, $path)) {
					$display = "$origPath → $path"
				}
				$lines.Add("  - $statusChar  $display")
			}
		}
		if(-not $includePerCommitFiles) {
			$lines.Add("")
			$lines.Add("_(Per-commit file lists suppressed: more than $perCommitFilesCap commits.)_")
		}
	}

	# Generates a unified diff patch and writes it to CHANGES.patch in the archive root.
	# Dispatches by RevisionKind to produce the correct git diff invocation.
	[System.IO.FileInfo] WritePatchFile()
	{
		[string]$leftHash = $this.LeftBranch.Branch.CommitHash
		[RevisionKind]$rightKind = $this.RightBranch.Branch.Kind
		[string[]]$patchLines = @()

		if($rightKind -eq [RevisionKind]::WorkTree) {
			$patchLines = @(git --no-pager diff $leftHash 2>$null)
		}
		elseif($rightKind -eq [RevisionKind]::Staged) {
			$patchLines = @(git --no-pager diff --staged $leftHash 2>$null)
		}
		else {
			[string]$rightHash = $this.RightBranch.Branch.CommitHash
			$patchLines = @(git --no-pager diff $leftHash $rightHash 2>$null)
		}

		if($LASTEXITCODE -ne 0 -or $null -eq $patchLines -or $patchLines.Length -eq 0) {
			return $null
		}

		[string]$patchContent = [string]::Join([System.Environment]::NewLine, $patchLines)
		[string]$patchFilePath = [System.IO.Path]::Combine($this.RootDirectory.FullName, "CHANGES.patch")
		[System.IO.File]::WriteAllText($patchFilePath, $patchContent, [System.Text.Encoding]::UTF8)

		[System.IO.FileInfo]$fileInfo = [System.IO.FileInfo]::new($patchFilePath)
		if($this.RightBranch.Branch.Kind -eq [RevisionKind]::Commit) {
			[System.DateTime]$commitDate = $this.RightBranch.Branch.CommitDate.DateTime
			$fileInfo.CreationTime = $commitDate
			$fileInfo.LastAccessTime = $commitDate
			$fileInfo.LastWriteTime = $commitDate
		}
		return $fileInfo
	}

	[GitDiffFile[]] WriteThreeWayDiffFiles()
	{
		[string]$baseHash = $this.BaseBranch.Branch.CommitHash
		[string]$leftHash = $this.LeftBranch.Branch.CommitHash
		[string]$rightHash = $this.RightBranch.Branch.CommitHash

		# Run two diffs: base→left and base→right
		Write-Host "  → " -ForegroundColor Cyan -NoNewline
		Write-Host "Computing base→left diff..." -ForegroundColor Gray
		[GitDiff[]]$baseToLeftDiffs = [GitTool]::GitDiff($baseHash, $leftHash)

		Write-Host "  → " -ForegroundColor Cyan -NoNewline
		Write-Host "Computing base→right diff..." -ForegroundColor Gray
		[GitDiff[]]$baseToRightDiffs = [GitTool]::GitDiff($baseHash, $rightHash)

		if($baseToLeftDiffs.Length -eq 0 -and $baseToRightDiffs.Length -eq 0) {
			return @()
		}

		# Collect all unique file paths across both diffs (excluding manifests)
		[System.Collections.Generic.HashSet[string]]$allPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
		foreach($diff in $baseToLeftDiffs) {
			if($diff.Status -ne [GitDiffStatus]::Unknown) {
				if(-not [string]::IsNullOrWhiteSpace($diff.FilePath)) { $null = $allPaths.Add($diff.FilePath) }
				if(-not [string]::IsNullOrWhiteSpace($diff.OriginalFilePath)) { $null = $allPaths.Add($diff.OriginalFilePath) }
			}
		}
		foreach($diff in $baseToRightDiffs) {
			if($diff.Status -ne [GitDiffStatus]::Unknown) {
				if(-not [string]::IsNullOrWhiteSpace($diff.FilePath)) { $null = $allPaths.Add($diff.FilePath) }
				if(-not [string]::IsNullOrWhiteSpace($diff.OriginalFilePath)) { $null = $allPaths.Add($diff.OriginalFilePath) }
			}
		}

		# Extract files for all three sides
		[string]$activity = "Extracting three-way diff files"
		[string[]]$pathList = $allPaths | Sort-Object
		[double]$progressFactor = 100.0 / [System.Math]::Max(1, $pathList.Length)

		[GitDiffFile[]]$diffFiles = @()
		for($i = 0; $i -lt $pathList.Length; $i++) {
			[string]$filePath = $pathList[$i]
			[int]$percentage = $progressFactor * $i
			Write-Progress -Activity $activity -Status "$percentage% Complete: $filePath" -PercentComplete $percentage

			# Write file from each side (will create -missing token if file doesn't exist at that revision)
			[System.IO.FileInfo]$baseFile = $this.BaseBranch.WriteFile($filePath)
			[System.IO.FileInfo]$leftFile = $this.LeftBranch.WriteFile($filePath)
			[System.IO.FileInfo]$rightFile = $this.RightBranch.WriteFile($filePath)

			# Track left/right as the diff file pair (base files collected separately via directory scan)
			$diffFiles += [GitDiffFile]::new($null, $leftFile, $rightFile)
		}
		Write-Progress -Activity $activity -Completed

		# Generate history file
		[System.IO.FileInfo]$historyResult = $this.WriteHistoryFile($baseToRightDiffs)
		if($null -ne $historyResult) {
			$this.HistoryFile = $historyResult
		}

		# Generate unified diff patch file
		[System.IO.FileInfo]$patchResult = $this.WritePatchFile()
		if($null -ne $patchResult) {
			$this.PatchFile = $patchResult
		}

		return $diffFiles
	}

	[GitDiffFile[]] WriteDiffFiles()
	{
		if($this.ThreeWayMode) {
			return $this.WriteThreeWayDiffFiles()
		}

        [GitDiffFile[]]$diffFiles = @()

		[GitDiff[]]$diffs = @()
		switch($this.RightBranch.Branch.Kind) {
			([RevisionKind]::WorkTree) {
				$diffs = [GitTool]::GitDiffWorkTree($this.LeftBranch.Branch.CommitHash)
			}
			([RevisionKind]::Staged) {
				$diffs = [GitTool]::GitDiffStaged($this.LeftBranch.Branch.CommitHash)
			}
			default {
				$diffs = [GitTool]::GitDiff($this.LeftBranch.Branch.CommitHash, $this.RightBranch.Branch.CommitHash)
			}
		}

        if($diffs.Length -eq 0)
        {
            return $diffFiles
        }

		# Generate history file from commits that touched diff'd files (only for commit-to-commit)
		[System.IO.FileInfo]$historyResult = $null
		if($this.RightBranch.Branch.Kind -eq [RevisionKind]::Commit) {
			$historyResult = $this.WriteHistoryFile($diffs)
		}
		if($null -ne $historyResult)
		{
			$this.HistoryFile = $historyResult
		}

		# Generate unified diff patch file (all modes)
		[System.IO.FileInfo]$patchResult = $this.WritePatchFile()
		if($null -ne $patchResult)
		{
			$this.PatchFile = $patchResult
		}

		[string]$leftName = $this.LeftBranch.Directory.Name
		[string]$rightName = $this.RightBranch.Directory.Name
		[string]$argumentsFilePath = $([System.IO.Path]::Combine($script:Temp.GetTempPath(), "Δ $leftName$([GitDiff]::BranchDiffSeparator)$rightName"))
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
					[string[]]$content = [System.IO.File]::ReadAllLines($diff.TokenFileInfo.ContentFilePath, [System.Text.Encoding]::UTF8)
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

<# Single porcelain status entry from `git status --porcelain=v1` #>
class GitStatusEntry {
	[string]$IndexStatus    # single char: staged/index status (or '?' untracked, '!' ignored)
	[string]$WorkTreeStatus # single char: working-tree status
	[string]$FilePath
	[string]$OriginalFilePath # populated for renames/copies (source path)

	GitStatusEntry([string]$indexStatus, [string]$workTreeStatus, [string]$filePath, [string]$originalFilePath) {
		$this.IndexStatus = $indexStatus
		$this.WorkTreeStatus = $workTreeStatus
		$this.FilePath = $filePath
		$this.OriginalFilePath = $originalFilePath
	}

	# Parses a single porcelain v1 line. Returns $null for malformed input.
	# Format: XY <path>   or   XY <orig> -> <new>   (rename/copy)
	static [GitStatusEntry] Parse([string]$line) {
		if($null -eq $line -or $line.Length -lt 4) { return $null }
		[string]$x = $line.Substring(0, 1)
		[string]$y = $line.Substring(1, 1)
		[string]$rest = $line.Substring(3)
		[string]$orig = $null
		[string]$path = $rest
		[int]$arrowIdx = $rest.IndexOf(" -> ")
		if($arrowIdx -ge 0) {
			$orig = $rest.Substring(0, $arrowIdx)
			$path = $rest.Substring($arrowIdx + 4)
		}
		return [GitStatusEntry]::new($x, $y, $path, $orig)
	}

	[bool] IsStaged() {
		return ($this.IndexStatus -ne " " -and $this.IndexStatus -ne "?" -and $this.IndexStatus -ne "!")
	}

	[bool] IsModifiedInWorkTree() {
		return ($this.WorkTreeStatus -ne " " -and $this.WorkTreeStatus -ne "?" -and $this.WorkTreeStatus -ne "!")
	}

	[bool] IsUntracked() {
		return ($this.IndexStatus -eq "?" -and $this.WorkTreeStatus -eq "?")
	}

	[bool] IsConflicted() {
		# Conflict codes: DD, AU, UD, UA, DU, AA, UU
		[string]$xy = $this.IndexStatus + $this.WorkTreeStatus
		return ($xy -eq "DD" -or $xy -eq "AU" -or $xy -eq "UD" -or $xy -eq "UA" -or $xy -eq "DU" -or $xy -eq "AA" -or $xy -eq "UU")
	}

	[string] ToString() {
		if(-not [string]::IsNullOrEmpty($this.OriginalFilePath)) {
			return "$($this.IndexStatus)$($this.WorkTreeStatus) $($this.OriginalFilePath) -> $($this.FilePath)"
		}
		return "$($this.IndexStatus)$($this.WorkTreeStatus) $($this.FilePath)"
	}
}

<# Structured commit metadata from `git log` #>
class GitLogEntry {
	[string]$Hash
	[string]$ShortHash
	[string]$AuthorName
	[string]$AuthorEmail
	[System.DateTimeOffset]$AuthorDate
	[string]$Subject

	GitLogEntry([string]$hash, [string]$shortHash, [string]$authorName, [string]$authorEmail, [System.DateTimeOffset]$authorDate, [string]$subject) {
		$this.Hash = $hash
		$this.ShortHash = $shortHash
		$this.AuthorName = $authorName
		$this.AuthorEmail = $authorEmail
		$this.AuthorDate = $authorDate
		$this.Subject = $subject
	}

	# Parses a single git-log line formatted with FieldSeparator-separated columns.
	# Expected fields: hash, shortHash, author name, author email, author date (ISO 8601), subject.
	static [string] $FieldSeparator = [char]0x1f  # ASCII Unit Separator

	# Builds the --format argument string that produces one line per commit
	# with fields separated by FieldSeparator. Matches the fields consumed by Parse().
	static [string] GetLogFormat() {
		[string]$fs = [GitLogEntry]::FieldSeparator
		return "%H$fs%h$fs%an$fs%ae$fs%aI$fs%s"
	}

	static [GitLogEntry] Parse([string]$line) {
		if([string]::IsNullOrEmpty($line)) { return $null }
		[string[]]$parts = $line.Split([GitLogEntry]::FieldSeparator)
		if($parts.Length -lt 6) { return $null }
		[System.DateTimeOffset]$dto = [System.DateTimeOffset]::MinValue
		if(-not [System.DateTimeOffset]::TryParse($parts[4], [ref]$dto)) {
			$dto = [System.DateTimeOffset]::MinValue
		}
		return [GitLogEntry]::new($parts[0], $parts[1], $parts[2], $parts[3], $dto, $parts[5])
	}

	[string] ToString() {
		return "$($this.ShortHash) $($this.Subject) ($($this.AuthorName), $($this.AuthorDate.ToString('yyyy-MM-dd HH:mm:ss zzz')))"
	}
}

<# Per-file insertion/deletion counts from `git diff --numstat` #>
class GitDiffStat {
	[string]$FilePath
	[string]$OriginalFilePath # populated for renames (source path)
	[int]$Insertions
	[int]$Deletions
	[bool]$IsBinary

	GitDiffStat([string]$filePath, [string]$originalFilePath, [int]$insertions, [int]$deletions, [bool]$isBinary) {
		$this.FilePath = $filePath
		$this.OriginalFilePath = $originalFilePath
		$this.Insertions = $insertions
		$this.Deletions = $deletions
		$this.IsBinary = $isBinary
	}

	# Parses a single `git diff --numstat` line.
	# Format: "<ins>\t<del>\t<path>"   (binary files use "-" for both counts)
	# Renames appear as: "<ins>\t<del>\t<old> => <new>"  (without -z).
	static [GitDiffStat] Parse([string]$line) {
		if([string]::IsNullOrWhiteSpace($line)) { return $null }
		[string[]]$parts = $line.Split("`t")
		if($parts.Length -lt 3) { return $null }
		[bool]$binaryFlag = ($parts[0] -eq "-" -and $parts[1] -eq "-")
		[int]$ins = 0
		[int]$del = 0
		if(-not $binaryFlag) {
			[void][int]::TryParse($parts[0], [ref]$ins)
			[void][int]::TryParse($parts[1], [ref]$del)
		}
		[string]$path = $parts[2]
		[string]$origPath = $null
		[int]$arrow = $path.IndexOf(" => ")
		if($arrow -ge 0) {
			$origPath = $path.Substring(0, $arrow)
			$path = $path.Substring($arrow + 4)
		}
		return [GitDiffStat]::new($path, $origPath, $ins, $del, $binaryFlag)
	}

	[string] ToString() {
		if($this.IsBinary) { return "(binary) $($this.FilePath)" }
		return "+$($this.Insertions) -$($this.Deletions) $($this.FilePath)"
	}
}

<# Line-by-line authorship from `git blame --porcelain` #>
class GitBlameLine {
	[string]$CommitHash
	[int]$LineNumber       # 1-based line number in the final file
	[string]$AuthorName
	[string]$AuthorEmail
	[System.DateTimeOffset]$AuthorDate
	[string]$Content       # the actual line text

	GitBlameLine([string]$commitHash, [int]$lineNumber, [string]$authorName, [string]$authorEmail, [System.DateTimeOffset]$authorDate, [string]$content) {
		$this.CommitHash = $commitHash
		$this.LineNumber = $lineNumber
		$this.AuthorName = $authorName
		$this.AuthorEmail = $authorEmail
		$this.AuthorDate = $authorDate
		$this.Content = $content
	}

	[string] ToString() {
		[string]$shortHash = $this.CommitHash
		if($shortHash.Length -gt 8) { $shortHash = $shortHash.Substring(0, 8) }
		return "$shortHash $($this.LineNumber): $($this.Content)"
	}
}

<# Contributor summary from `git shortlog -sne` #>
class GitContributor {
	[int]$CommitCount
	[string]$Name
	[string]$Email

	GitContributor([int]$commitCount, [string]$name, [string]$email) {
		$this.CommitCount = $commitCount
		$this.Name = $name
		$this.Email = $email
	}

	# Parses a single shortlog line.  Format: "  <count>\t<name> <email>"
	static [GitContributor] Parse([string]$line) {
		if([string]::IsNullOrWhiteSpace($line)) { return $null }
		[string]$trimmed = $line.Trim()
		[string[]]$parts = $trimmed.Split("`t", 2)
		if($parts.Length -lt 2) { return $null }
		[int]$count = 0
		if(-not [int]::TryParse($parts[0].Trim(), [ref]$count)) { return $null }
		[string]$nameEmail = $parts[1].Trim()
		[string]$authorName = $nameEmail
		[string]$authorEmail = ""
		[int]$emailStart = $nameEmail.LastIndexOf(" <")
		if($emailStart -ge 0 -and $nameEmail.EndsWith(">")) {
			$authorName = $nameEmail.Substring(0, $emailStart)
			$authorEmail = $nameEmail.Substring($emailStart + 2, $nameEmail.Length - $emailStart - 3)
		}
		return [GitContributor]::new($count, $authorName, $authorEmail)
	}

	[string] ToString() {
		return "$($this.CommitCount)`t$($this.Name) <$($this.Email)>"
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

		if([string]::IsNullOrWhiteSpace($commitHash))
		{
			$commitHash = "HEAD~1" # previous commit
		}

		Write-Host "  → " -ForegroundColor Cyan -NoNewline
		Write-Host "Diffing $commitHash..." -ForegroundColor Gray

		# Check if merge-base exists; fall back to direct diff for unrelated histories
		[bool]$hasMergeBase = $true
		if(-not [string]::IsNullOrWhiteSpace($changesCommitHash))
		{
			if($null -eq [GitTool]::GetMergeBase($commitHash, $changesCommitHash))
			{
				Write-Warn "No common ancestor found between branches; using direct diff (unrelated histories?)"
				$hasMergeBase = $false
			}
		}

		[object[]]$diffsRawArray = @()
		if([string]::IsNullOrWhiteSpace($changesCommitHash))
		{
			if($hasMergeBase)
			{
				$diffsRawArray = git --no-pager diff --find-copies --find-renames --name-status --merge-base $commitHash
			}
			else
			{
				$diffsRawArray = git --no-pager diff --find-copies --find-renames --name-status $commitHash
			}
		}
		else
		{
			if($hasMergeBase)
			{
				$diffsRawArray = git --no-pager diff --find-copies --find-renames --name-status --merge-base $commitHash $changesCommitHash
			}
			else
			{
				$diffsRawArray = git --no-pager diff --find-copies --find-renames --name-status $commitHash $changesCommitHash
			}
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

		[string]$manifestFilePath = $([System.IO.Path]::Combine($script:Temp.GetTempPath(), "commit# " + $($commitHash + ".manifest")))
		Set-Content -Path $manifestFilePath -Value $manifestRawArray
		[GitDiff]$manifestDiff = [GitDiff]::new([GitDiffStatusRaw]::X, $null, $manifestFilePath)
		
		$diffs += $manifestDiff

		Remove-Variable manifestFilePath
		Remove-Variable manifestDiff

		return $diffs
	}

	static [GitDiff[]] GitDiffWorkTree([string]$commitHash) {
		return [GitTool]::GitDiffSpecial("--", $commitHash, "working tree")
	}

	static [GitDiff[]] GitDiffStaged([string]$commitHash) {
		return [GitTool]::GitDiffSpecial("--staged", $commitHash, "staged index")
	}

	hidden static [GitDiff[]] GitDiffSpecial([string]$diffFlag, [string]$commitHash, [string]$label) {
		[GitDiff[]]$diffs = @()

		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return $diffs
		}

		Write-Host "  → " -ForegroundColor Cyan -NoNewline
		Write-Host "Diffing $commitHash against $label..." -ForegroundColor Gray

		[object[]]$diffsRawArray = @()
		if($diffFlag -eq "--") {
			# Working tree diff: git diff --find-copies --find-renames --name-status $commitHash
			$diffsRawArray = git --no-pager diff --find-copies --find-renames --name-status $commitHash
		}
		else {
			# Staged diff: git diff --staged --find-copies --find-renames --name-status $commitHash
			$diffsRawArray = git --no-pager diff $diffFlag --find-copies --find-renames --name-status $commitHash
		}

		if($null -eq $diffsRawArray) {
			Write-Fail "git returned no diffs for $label"
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

		[string]$manifestFilePath = $([System.IO.Path]::Combine($script:Temp.GetTempPath(), "$label.manifest"))
		Set-Content -Path $manifestFilePath -Value $manifestRawArray
		[GitDiff]$manifestDiff = [GitDiff]::new([GitDiffStatusRaw]::X, $null, $manifestFilePath)
		$diffs += $manifestDiff

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
		return $archiveFile
	}

	static [System.IO.FileInfo] ArchiveBranchDiffs([GitBranch]$leftBranch, [GitBranch]$rightBranch, [System.IO.DirectoryInfo]$outputDirectory, [string]$archiveFileName)
	{
		[GitDiffBranch]$diffBranch = [GitDiffBranch]::new($leftBranch, $rightBranch)

		[System.IO.FileInfo]$archiveFile = $diffBranch.CreateDiffsZip($outputDirectory, $archiveFileName)

		if($null -eq $archiveFile)
		{
			return $null
		}
		return $archiveFile
	}

	static [System.IO.FileInfo] ArchiveBranchDiffsThreeWay([string]$leftBranchName, [string]$rightBranchName, [System.IO.DirectoryInfo]$outputDirectory, [string]$archiveFileName)
	{
		[GitDiffBranch]$diffBranch = [GitDiffBranch]::ForThreeWay($leftBranchName, $rightBranchName)

		[System.IO.FileInfo]$archiveFile = $diffBranch.CreateDiffsZip($outputDirectory, $archiveFileName)

		if($null -eq $archiveFile)
		{
			return $null
		}
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
	        if([string]::IsNullOrWhiteSpace($remoteUrl))
	        {
	            return $remoteUrl
	        }
		return $remoteUrl.Trim()
	}

	static [string] GetRemoteName()
	{
		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return ""
		}

		[string]$remoteName = git remote
		if([string]::IsNullOrWhiteSpace($remoteName))
		{
			return $remoteName
		}
		return $remoteName.Trim()
	}

	static [string] GetDefaultRemoteBranch()
	{
		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return ""
		}
		[string]$remoteName = [GitTool]::GetRemoteName()
		if([string]::IsNullOrWhiteSpace($remoteName))
		{
			Write-Warn "No git remote configured; cannot detect default branch"
			return ""
		}
		[string]$defaultBranch = git symbolic-ref refs/remotes/$remoteName/HEAD --short 2>$null
		if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($defaultBranch))
		{
			Write-Warn "Could not resolve default branch for remote '$remoteName'"
			return ""
		}
		return $defaultBranch.Trim()
	}

	static [string] GetCurrentBranch()
	{
		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return ""
		}
		[string]$currentBranch = git branch --show-current
		if([string]::IsNullOrWhiteSpace($currentBranch))
		{
			# Detached HEAD — fall back to short commit hash
			$currentBranch = git rev-parse --short HEAD 2>$null
			if(-not [string]::IsNullOrWhiteSpace($currentBranch))
			{
				Write-Warn "Detached HEAD state; using commit $($currentBranch.Trim()) as current branch"
			}
		}
		if([string]::IsNullOrWhiteSpace($currentBranch))
		{
			return $currentBranch
		}
		return $currentBranch.Trim()
	}

	static [string] GetCommitHash([string]$branchName)
	{
		if(-not (Get-Command -CommandType Application git -ErrorAction SilentlyContinue))
		{
			Write-Fail git not found
			return ""
		}
		if([string]::IsNullOrWhiteSpace($branchName)) {
			Write-Fail "branchName should not be null"
		}

		[string]$commitHash = git rev-parse $branchName 2>$null
		if($LASTEXITCODE -ne 0)
		{
			return $null
		}
		if([string]::Equals($commitHash, $branchName))
		{
			if(-not [GitTool]::IsPossibleCommitHash($commitHash))
			{
				$commitHash = $null
			}
		}

		return $commitHash
	}

	static [System.DateTimeOffset] GetCommitDate([string]$branchName) 
	{
		if([string]::IsNullOrWhiteSpace($branchName)) {
			Write-Fail "branchName should not be null"
		}
		#%ci is 'commit date' + 'iso'
		[string]$commitDateRaw = git log -n 1 --pretty="format:%ci" $branchName
		return [System.DateTimeOffset]::Parse($commitDateRaw)
	}

	static [bool] IsPossibleCommitHash([string]$branchOrHash) {
	        # The regex checks for a string that is between 4 and 40 characters long,
	        # contains only hexadecimal characters (0-9, a-f)
	        if ($branchOrHash -match '^[a-f0-9]{4,40}$') {
	            return $true
	        }
	        else {
	            return $false
	        }
    	}

	# Returns the merge-base commit hash, or $null if no common ancestor exists.
	static [string] GetMergeBase([string]$commitHash1, [string]$commitHash2) {
		if([string]::IsNullOrWhiteSpace($commitHash1) -or [string]::IsNullOrWhiteSpace($commitHash2)) {
			return $null
		}
		[string]$mergeBase = git merge-base $commitHash1 $commitHash2 2>$null
		if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($mergeBase)) {
			return $null
		}
		return $mergeBase.Trim()
	}

	static [bool] IsShallowClone() {
		[string]$result = git rev-parse --is-shallow-repository 2>$null
		return ($result -eq "true")
	}

	# Returns true if $ancestor is an ancestor commit of $descendant.
	static [bool] IsAncestor([string]$ancestor, [string]$descendant) {
		if([string]::IsNullOrWhiteSpace($ancestor) -or [string]::IsNullOrWhiteSpace($descendant)) {
			return $false
		}
		git merge-base --is-ancestor $ancestor $descendant 2>$null
		return ($LASTEXITCODE -eq 0)
	}

	# Returns the absolute path of the repo root, or $null if not in a git repo.
	static [string] GetRepoRoot() {
		[string]$root = git rev-parse --show-toplevel 2>$null
		if($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
			return $null
		}
		return $root.Trim()
	}

	# Returns local + remote branch names (as seen by git tab-completion).
	static [string[]] GetBranches([bool]$includeRemotes) {
		[string[]]$result = $null
		if($includeRemotes) {
			$result = @(git branch -a --format='%(refname:short)' 2>$null)
		} else {
			$result = @(git branch --format='%(refname:short)' 2>$null)
		}
		if($LASTEXITCODE -ne 0) { return @() }
		return @($result | Where-Object { $_.Length -gt 0 })
	}

	# Returns all tag names in the repository.
	static [string[]] GetTags() {
		[string[]]$result = @(git tag --list 2>$null)
		if($LASTEXITCODE -ne 0) { return @() }
		return @($result | Where-Object { $_.Length -gt 0 })
	}

	# Returns stash references in the form "stash@{N}".
	static [string[]] GetStashes() {
		[string[]]$result = @(git stash list --format='%gd' 2>$null)
		if($LASTEXITCODE -ne 0) { return @() }
		return @($result | Where-Object { $_.Length -gt 0 })
	}

	# Returns structured commits for the given range (e.g. "A..B", "HEAD", a branch name).
	# $limit of 0 or less means "no limit". $paths is an optional path filter.
	static [GitLogEntry[]] GetLog([string]$range, [int]$limit, [string[]]$paths) {
		if([string]::IsNullOrWhiteSpace($range)) { return @() }
		[System.Collections.Generic.List[string]]$gitArgs = [System.Collections.Generic.List[string]]::new()
		$gitArgs.Add("--no-pager")
		$gitArgs.Add("log")
		$gitArgs.Add("--format=" + [GitLogEntry]::GetLogFormat())
		if($limit -gt 0) { $gitArgs.Add("-n"); $gitArgs.Add("$limit") }
		$gitArgs.Add($range)
		if($null -ne $paths -and $paths.Length -gt 0) {
			$gitArgs.Add("--")
			foreach($p in $paths) { $gitArgs.Add($p) }
		}
		[string[]]$lines = @(git @gitArgs 2>$null)
		if($LASTEXITCODE -ne 0) { return @() }
		[System.Collections.Generic.List[GitLogEntry]]$entries = [System.Collections.Generic.List[GitLogEntry]]::new()
		foreach($line in $lines) {
			[GitLogEntry]$e = [GitLogEntry]::Parse($line)
			if($null -ne $e) { $entries.Add($e) }
		}
		return $entries.ToArray()
	}

	# Convenience overloads.
	static [GitLogEntry[]] GetLog([string]$range) { return [GitTool]::GetLog($range, 0, $null) }
	static [GitLogEntry[]] GetLog([string]$range, [int]$limit) { return [GitTool]::GetLog($range, $limit, $null) }

	# Returns [GitDiff] entries for the files touched by a single commit,
	# relative to its first parent. Root commits (no parent) return every
	# tracked file as Added.
	static [GitDiff[]] GetCommitFiles([string]$commitHash) {
		if([string]::IsNullOrWhiteSpace($commitHash)) { return @() }
		# Use diff-tree against first parent (-m would show merges per-parent; we keep it simple).
		# -r: recurse into subtrees; --no-commit-id: suppress the commit header line;
		# --root: for root commits, show all files as additions.
		[string[]]$lines = @(git --no-pager diff-tree -r --no-commit-id --name-status --root $commitHash 2>$null)
		if($LASTEXITCODE -ne 0) { return @() }
		[System.Collections.Generic.List[GitDiff]]$diffs = [System.Collections.Generic.List[GitDiff]]::new()
		foreach($line in $lines) {
			if([string]::IsNullOrWhiteSpace($line)) { continue }
			[GitDiff]$diff = [GitDiff]::Parse($line)
			if($null -ne $diff) { $diffs.Add($diff) }
		}
		return $diffs.ToArray()
	}

	# Returns the unified-diff text for a single file between two revisions.
	# Returns an empty string if the file is unchanged (or input is empty/invalid).
	# Returns line-by-line blame annotations for a file at a given revision.
	static [GitBlameLine[]] GetBlame([string]$revision, [string]$filePath) {
		if([string]::IsNullOrWhiteSpace($revision) -or [string]::IsNullOrWhiteSpace($filePath)) {
			return @()
		}
		[string[]]$lines = @(git --no-pager blame --porcelain $revision -- $filePath 2>$null)
		if($LASTEXITCODE -ne 0 -or $null -eq $lines -or $lines.Length -eq 0) { return @() }

		[System.Collections.Generic.List[GitBlameLine]]$results = [System.Collections.Generic.List[GitBlameLine]]::new()
		[string]$curHash = ""
		[int]$curLine = 0
		[string]$curAuthor = ""
		[string]$curEmail = ""
		[long]$curTimestamp = 0
		[string]$curTz = "+0000"

		foreach($raw in $lines) {
			if($raw.StartsWith("`t")) {
				# Content line — this terminates the current block.
				[string]$lineContent = $raw.Substring(1)
				[System.DateTimeOffset]$dto = [System.DateTimeOffset]::MinValue
				try {
					[System.DateTime]$epoch = [System.DateTime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
					$dto = [System.DateTimeOffset]::new($epoch.AddSeconds($curTimestamp))
				} catch { }
				$results.Add([GitBlameLine]::new($curHash, $curLine, $curAuthor, $curEmail, $dto, $lineContent))
			}
			elseif($raw -match '^([0-9a-f]{40}) \d+ (\d+)') {
				$curHash = $Matches[1]
				$curLine = [int]$Matches[2]
			}
			elseif($raw.StartsWith("author ")) { $curAuthor = $raw.Substring(7) }
			elseif($raw.StartsWith("author-mail ")) {
				$curEmail = $raw.Substring(12).Trim('<', '>')
			}
			elseif($raw.StartsWith("author-time ")) {
				[void][long]::TryParse($raw.Substring(12), [ref]$curTimestamp)
			}
			elseif($raw.StartsWith("author-tz ")) { $curTz = $raw.Substring(10) }
		}
		return $results.ToArray()
	}

	# Returns unique contributors (author name + email + commit count) for a range.
	static [GitContributor[]] GetContributors([string]$range) {
		if([string]::IsNullOrWhiteSpace($range)) { return @() }
		[string[]]$lines = @(git --no-pager shortlog -sne $range 2>$null)
		if($LASTEXITCODE -ne 0 -or $null -eq $lines) { return @() }
		[System.Collections.Generic.List[GitContributor]]$results = [System.Collections.Generic.List[GitContributor]]::new()
		foreach($line in $lines) {
			[GitContributor]$c = [GitContributor]::Parse($line)
			if($null -ne $c) { $results.Add($c) }
		}
		return $results.ToArray()
	}

	static [string] GetFileDiff([string]$left, [string]$right, [string]$filePath) {
		if([string]::IsNullOrWhiteSpace($left) -or
		   [string]::IsNullOrWhiteSpace($right) -or
		   [string]::IsNullOrWhiteSpace($filePath)) {
			return ""
		}
		[string[]]$lines = @(git --no-pager diff $left $right -- $filePath 2>$null)
		if($LASTEXITCODE -ne 0 -or $null -eq $lines) { return "" }
		return [string]::Join([System.Environment]::NewLine, $lines)
	}

	# Cleaner alias for GetFileContent — returns file bytes at a specific revision.
	# Returns an empty byte array if the file doesn't exist at that revision.
	static [byte[]] GetFileAtRevision([string]$revision, [string]$filePath) {
		return [GitTool]::GetFileContent($revision, $filePath)
	}

	# Returns the unified diff between two (potentially different) files at
	# two revisions. Useful for comparing renamed files or files across repos.
	static [string] CompareFiles([string]$rev1, [string]$path1, [string]$rev2, [string]$path2) {
		if([string]::IsNullOrWhiteSpace($rev1) -or [string]::IsNullOrWhiteSpace($path1) -or
		   [string]::IsNullOrWhiteSpace($rev2) -or [string]::IsNullOrWhiteSpace($path2)) {
			return ""
		}
		# git diff <blob1> <blob2> compares two arbitrary objects.
		[string]$leftBlob = "${rev1}:${path1}"
		[string]$rightBlob = "${rev2}:${path2}"
		[string[]]$lines = @(git --no-pager diff $leftBlob $rightBlob 2>$null)
		if($LASTEXITCODE -ne 0 -or $null -eq $lines) { return "" }
		return [string]::Join([System.Environment]::NewLine, $lines)
	}

	# Returns per-file insertion/deletion counts between two revisions.
	# Accepts "A..B" range or two separate refs via DiffStat(left, right).
	static [GitDiffStat[]] GetDiffStat([string]$left, [string]$right) {
		if([string]::IsNullOrWhiteSpace($left) -or [string]::IsNullOrWhiteSpace($right)) { return @() }
		[string[]]$lines = @(git --no-pager diff --numstat $left $right 2>$null)
		if($LASTEXITCODE -ne 0) { return @() }
		[System.Collections.Generic.List[GitDiffStat]]$stats = [System.Collections.Generic.List[GitDiffStat]]::new()
		foreach($line in $lines) {
			[GitDiffStat]$s = [GitDiffStat]::Parse($line)
			if($null -ne $s) { $stats.Add($s) }
		}
		return $stats.ToArray()
	}

	# Returns [GitStatusEntry] objects, one per porcelain line.
	# Honors --untracked-files=all so untracked items are individually listed.
	static [GitStatusEntry[]] GetStatus() {
		[string[]]$lines = @(git status --porcelain=v1 --untracked-files=all 2>$null)
		if($LASTEXITCODE -ne 0) { return @() }
		[System.Collections.Generic.List[GitStatusEntry]]$entries = [System.Collections.Generic.List[GitStatusEntry]]::new()
		foreach($line in $lines) {
			if($line.Length -lt 4) { continue }
			[GitStatusEntry]$entry = [GitStatusEntry]::Parse($line)
			if($null -ne $entry) { $entries.Add($entry) }
		}
		return $entries.ToArray()
	}

	# Returns staged files with per-file insertion/deletion counts.
	# Each entry pairs the GitStatusEntry with its GitDiffStat (staged vs HEAD).
	static [hashtable[]] GetStagedFiles() {
		[GitStatusEntry[]]$status = [GitTool]::GetStatus()
		[GitStatusEntry[]]$stagedOnly = @($status | Where-Object { $_.IsStaged() })
		if($stagedOnly.Length -eq 0) { return @() }
		# Get numstat for staged changes (diff --staged --numstat)
		[string[]]$statLines = @(git --no-pager diff --staged --numstat 2>$null)
		[System.Collections.Generic.Dictionary[string,GitDiffStat]]$statMap =
			[System.Collections.Generic.Dictionary[string,GitDiffStat]]::new([System.StringComparer]::OrdinalIgnoreCase)
		if($LASTEXITCODE -eq 0 -and $null -ne $statLines) {
			foreach($sl in $statLines) {
				[GitDiffStat]$ds = [GitDiffStat]::Parse($sl)
				if($null -ne $ds -and -not $statMap.ContainsKey($ds.FilePath)) {
					$statMap[$ds.FilePath] = $ds
				}
			}
		}
		[System.Collections.Generic.List[hashtable]]$results = [System.Collections.Generic.List[hashtable]]::new()
		foreach($entry in $stagedOnly) {
			[GitDiffStat]$stat = $null
			[void]$statMap.TryGetValue($entry.FilePath, [ref]$stat)
			$results.Add(@{ Status = $entry; DiffStat = $stat })
		}
		return $results.ToArray()
	}

	# Returns files currently in a merge conflict, with the conflict type code.
	static [GitStatusEntry[]] GetConflicts() {
		[GitStatusEntry[]]$status = [GitTool]::GetStatus()
		return @($status | Where-Object { $_.IsConflicted() })
	}

	static [byte[]] GetFileContent([string]$branchOrRevision, [string]$repoFilePath)
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

		[string]$showResultFilePath = $script:Temp.GetEmptyTempFile()

		git --no-pager show $showFile > $showResultFilePath

		[System.IO.FileInfo]$showResultFile = [System.IO.FileInfo]::new($showResultFilePath)

		if($null -eq $showResultFile -or 0 -eq $showResultFile.Length)
		{
			Write-Warn "No file content found for $branchOrRevision/$repoFilePath"
			return @()
		}

		[byte[]]$showResult = [System.IO.File]::ReadAllBytes($showResultFilePath)
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

		[byte[]]$content = [GitTool]::GetFileContent($branchOrRevision, $repoFilePath)

		if($null -ne $content -and $content.Length -gt 0) 
		{
			[System.IO.FileInfo]$filePath = [System.IO.Path]::Combine($directoryRoot.FullName, $repoFilePath)
			[System.IO.File]::WriteAllBytes($filePath, $content)
			return $true
		}
		
		return $false
	}

	static [bool] IsGitRoot([string]$directoryPath)
	{
		# A normal repo has a .git directory; a worktree has a .git file that
		# points at the shared gitdir. Accept both.
		[string]$dotGit = [System.IO.Path]::Combine($directoryPath, ".git")
		return [System.IO.Directory]::Exists($dotGit) -or [System.IO.File]::Exists($dotGit)
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

# Guard: skip entry point when dot-sourced for unit testing
# Tests set $script:SkipEntryPoint = $true before dot-sourcing
if($(try { $script:SkipEntryPoint } catch { $false })) { return }

[System.IO.DirectoryInfo]$currentDirectory = [System.IO.DirectoryInfo]::new($(Get-Location))
[Environment]::CurrentDirectory = $currentDirectory.FullName

[System.Diagnostics.Stopwatch]$script:stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

#region Banner
[int]$boxWidth = 50
function Write-BoxLine([string]$text, [string]$textColor = "White") {
	[int]$padding = $boxWidth - $text.Length
	Write-Host "  ║" -ForegroundColor Cyan -NoNewline
	Write-Host $text -ForegroundColor $textColor -NoNewline
	Write-Host (" " * $padding) -ForegroundColor Cyan -NoNewline
	Write-Host "║" -ForegroundColor Cyan
}
Write-Host ""
Write-Host "  ╔$("═" * $boxWidth)╗" -ForegroundColor Cyan
Write-BoxLine ""
Write-BoxLine "   Git-ArchiveBranchDiffs"
Write-BoxLine "   Archive branch diffs for offline review" "DarkGray"
Write-BoxLine ""
Write-Host "  ╚$("═" * $boxWidth)╝" -ForegroundColor Cyan
Write-Host ""
#endregion Banner

try {

#region Parameter Validation
if($workingTree -and $staged) {
	Write-Fail "-workingTree and -staged are mutually exclusive"
}
if($threeWay -and ($workingTree -or $staged)) {
	Write-Fail "-threeWay is incompatible with -workingTree and -staged"
}
if((-not [string]::IsNullOrWhiteSpace($rightBranch)) -and ($workingTree -or $staged)) {
	Write-Fail "-rightBranch cannot be used with -workingTree or -staged"
}
#endregion Parameter Validation

#region Input Resolution
Write-Host "  ── " -ForegroundColor DarkGray -NoNewline
Write-Host "Input Resolution" -ForegroundColor Cyan -NoNewline
Write-Host " ──────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

if($nonInteractive)
{
	# Non-interactive mode: use smart defaults
	if([string]::IsNullOrWhiteSpace($repositoryPath))
	{
		# Prefer git's own upward walk so the script works from any subdirectory.
		[string]$discoveredRoot = [GitTool]::GetRepoRoot()
		if(-not [string]::IsNullOrWhiteSpace($discoveredRoot))
		{
			$repositoryPath = $discoveredRoot
		}
		elseif([GitTool]::IsGitRoot($currentDirectory.FullName))
		{
			$repositoryPath = $currentDirectory.FullName
		}
		else
		{
			Write-Fail "Not inside a git repository. Specify -repositoryPath."
		}
	}
}
else
{
	if([string]::IsNullOrWhiteSpace($repositoryPath))
	{
		# Compute candidate via git's upward walk first, so subdirectory launches work.
		[string]$discoveredRoot = [GitTool]::GetRepoRoot()
		[string]$candidate = $null
		if(-not [string]::IsNullOrWhiteSpace($discoveredRoot)) {
			$candidate = $discoveredRoot
		}
		elseif([GitTool]::IsGitRoot($currentDirectory.FullName)) {
			$candidate = [System.IO.Path]::GetFullPath($currentDirectory)
		}

		if(-not [string]::IsNullOrWhiteSpace($candidate) -and
		   -not [string]::Equals($candidate, $PSScriptRoot, [System.StringComparison]::InvariantCultureIgnoreCase))
		{
			$useCurrentDirectory = Read-Prompt "Use '$candidate' as the git repository root? (Y/N)"

			if([string]::Equals($useCurrentDirectory, "Y", [System.StringComparison]::InvariantCultureIgnoreCase) -or
			[string]::Equals($useCurrentDirectory, "YES", [System.StringComparison]::InvariantCultureIgnoreCase))
			{
				$repositoryPath = $candidate
			}
		}

		if([string]::IsNullOrWhiteSpace($repositoryPath))
		{
			$repositoryPath = Read-PromptWithCompletion "Enter the path to the root of a git repository" -pathMode
			$repositoryPath = [System.IO.Path]::GetFullPath($repositoryPath)
		}
	}
}

if(-not [GitTool]::IsGitRoot($repositoryPath))
{
	Write-Fail "'$repositoryPath' does not appear to be a git repository root."
}

Write-Host "  ✓ " -ForegroundColor Green -NoNewline
Write-Host "Repository: " -ForegroundColor Gray -NoNewline
Write-Host "$repositoryPath" -ForegroundColor White

Push-Location -Path $repositoryPath

if($nonInteractive)
{
	if([string]::IsNullOrWhiteSpace($leftBranch))
	{
		$leftBranch = [GitTool]::GetDefaultRemoteBranch()
		if([string]::IsNullOrWhiteSpace($leftBranch))
		{
			Write-Fail "Could not detect default remote branch. Specify -leftBranch."
		}
	}

	if(-not $workingTree -and -not $staged -and [string]::IsNullOrWhiteSpace($rightBranch))
	{
		$rightBranch = [GitTool]::GetCurrentBranch()
		if([string]::IsNullOrWhiteSpace($rightBranch))
		{
			Write-Fail "Could not detect current branch. Specify -rightBranch."
		}
	}
}
else
{
	if([string]::IsNullOrWhiteSpace($leftBranch))
	{
		[string]$defaultBranch = [GitTool]::GetDefaultRemoteBranch()

		$useDefaultBranch = Read-Prompt "Use '$defaultBranch' as LEFT branch for comparison? (Y/N)"

		if([string]::Equals($useDefaultBranch, "Y", [System.StringComparison]::InvariantCultureIgnoreCase) -or
		[string]::Equals($useDefaultBranch, "YES", [System.StringComparison]::InvariantCultureIgnoreCase))
		{
			$leftBranch = $defaultBranch
		}
		else
		{
			[string[]]$branches = @(Get-GitCompletionCandidates)
			if($branches.Count -gt 0)
			{
				$leftBranch = Read-PromptWithCompletion "Enter the name of the LEFT branch for comparison" $branches
			}
			else
			{
				$leftBranch = Read-Prompt "Enter the name of the LEFT branch for comparison"
			}
		}
	}

	if(-not $workingTree -and -not $staged -and [string]::IsNullOrWhiteSpace($rightBranch))
	{
		[string]$currentBranch = [GitTool]::GetCurrentBranch()

		$useCurrentBranch = Read-Prompt "Use '$currentBranch' as RIGHT branch for comparison? (Y/N)"

		if([string]::Equals($useCurrentBranch, "Y", [System.StringComparison]::InvariantCultureIgnoreCase) -or
		[string]::Equals($useCurrentBranch, "YES", [System.StringComparison]::InvariantCultureIgnoreCase))
		{
			$rightBranch = $currentBranch
		}
		else
		{
			[string[]]$branches = @(Get-GitCompletionCandidates)
			if($branches.Count -gt 0)
			{
				$rightBranch = Read-PromptWithCompletion "Enter the name of the RIGHT branch for comparison" $branches
			}
			else
			{
				$rightBranch = Read-Prompt "Enter the name of the RIGHT branch for comparison"
			}
		}
	}
}

Pop-Location

# Determine right-side display name
[string]$rightDisplay = $rightBranch
if($workingTree) { $rightDisplay = "WORKING-TREE" }
elseif($staged) { $rightDisplay = "STAGED" }

Write-Host "  ✓ " -ForegroundColor Green -NoNewline
Write-Host "Left branch:  " -ForegroundColor Gray -NoNewline
Write-Host "$leftBranch" -ForegroundColor White
Write-Host "  ✓ " -ForegroundColor Green -NoNewline
Write-Host "Right branch: " -ForegroundColor Gray -NoNewline
Write-Host "$rightDisplay" -ForegroundColor White

if($nonInteractive)
{
	if([string]::IsNullOrWhiteSpace($outputDirectory))
	{
		$outputDirectory = $currentDirectory.FullName
	}
}
else
{
	if([string]::IsNullOrWhiteSpace($outputDirectory))
	{
		$outputDirectory = Read-PromptWithCompletion "Enter the path where the ZIP will be created" -pathMode
		$outputDirectory = [System.IO.Path]::GetFullPath($outputDirectory)
	}
}

Write-Host "  ✓ " -ForegroundColor Green -NoNewline
Write-Host "Output dir:   " -ForegroundColor Gray -NoNewline
Write-Host "$outputDirectory" -ForegroundColor White
Write-Host ""
#endregion Input Resolution

#region Diff and Archive
Write-Host "  ── " -ForegroundColor DarkGray -NoNewline
Write-Host "Diff Analysis & Archive Creation" -ForegroundColor Cyan -NoNewline
Write-Host " ──────────────" -ForegroundColor DarkGray
Write-Host ""

Push-Location -Path $repositoryPath

# Warn about shallow clones which may produce incomplete results
if([GitTool]::IsShallowClone())
{
	Write-Warn "This is a shallow clone; diff results and commit history may be incomplete"
}

# Preflight: communicate the ancestor relationship so users understand
# what the archive will contain — or that they probably swapped their args.
if(-not $workingTree -and -not $staged) {
	[string]$leftHashPre  = [GitTool]::GetCommitHash($leftBranch)
	[string]$rightHashPre = [GitTool]::GetCommitHash($rightBranch)
	if(-not [string]::IsNullOrWhiteSpace($leftHashPre) -and -not [string]::IsNullOrWhiteSpace($rightHashPre)) {
		if([string]::Equals($leftHashPre, $rightHashPre, [System.StringComparison]::OrdinalIgnoreCase)) {
			Write-Host ""
			Write-Host "  Left and right refer to the same commit — nothing to compare." -ForegroundColor Yellow
			Write-Host ""
			Pop-Location
			return
		}
		if([GitTool]::IsAncestor($leftHashPre, $rightHashPre)) {
			Write-Host "  '$leftBranch' is an ancestor of '$rightBranch'." -ForegroundColor Gray
			Write-Host "  Archive will contain commits added on '$rightBranch' since '$leftBranch'." -ForegroundColor DarkGray
		}
		elseif([GitTool]::IsAncestor($rightHashPre, $leftHashPre)) {
			Write-Host "  '$rightBranch' is an ancestor of '$leftBranch'." -ForegroundColor Yellow
			Write-Host "  Consider swapping -leftBranch and -rightBranch." -ForegroundColor Gray
		}
	}
}

[System.IO.FileInfo]$archiveFile = $null
if($workingTree) {
	[GitStatusEntry[]]$status = [GitTool]::GetStatus()
	[GitStatusEntry[]]$dirty = @($status | Where-Object { $_.IsModifiedInWorkTree() -or $_.IsUntracked() })
	if($dirty.Length -eq 0) {
		Write-Host ""
		Write-Host "  Working tree is clean — nothing to archive." -ForegroundColor Yellow
		Write-Host ""
		Pop-Location
		return
	}
	Write-Host "  Found $($dirty.Length) uncommitted change(s) in working tree." -ForegroundColor Gray
	[GitBranch]$leftBranchObj = [GitBranch]::new($leftBranch)
	[GitBranch]$rightBranchObj = [GitBranch]::ForWorkTree()
	$archiveFile = [GitTool]::ArchiveBranchDiffs($leftBranchObj, $rightBranchObj, $outputDirectory, $archiveFileName)
}
elseif($staged) {
	[GitStatusEntry[]]$status = [GitTool]::GetStatus()
	[GitStatusEntry[]]$stagedEntries = @($status | Where-Object { $_.IsStaged() })
	if($stagedEntries.Length -eq 0) {
		Write-Host ""
		Write-Host "  Index is empty — nothing to archive." -ForegroundColor Yellow
		Write-Host ""
		Pop-Location
		return
	}
	Write-Host "  Found $($stagedEntries.Length) staged change(s)." -ForegroundColor Gray
	[GitBranch]$leftBranchObj = [GitBranch]::new($leftBranch)
	[GitBranch]$rightBranchObj = [GitBranch]::ForStaged()
	$archiveFile = [GitTool]::ArchiveBranchDiffs($leftBranchObj, $rightBranchObj, $outputDirectory, $archiveFileName)
}
elseif($threeWay) {
	$archiveFile = [GitTool]::ArchiveBranchDiffsThreeWay($leftBranch, $rightBranch, $outputDirectory, $archiveFileName)
}
else {
	$archiveFile = [GitTool]::ArchiveBranchDiffs($leftBranch, $rightBranch, $outputDirectory, $archiveFileName)
}

$script:stopwatch.Stop()

Pop-Location
#endregion Diff and Archive

#region Summary
if($null -ne $archiveFile -and $archiveFile.Exists)
{
	[double]$sizeKB = $archiveFile.Length / 1024.0
	[string]$sizeDisplay = $(if($sizeKB -ge 1024) { "{0:N1} MB" -f ($sizeKB / 1024.0) } else { "{0:N1} KB" -f $sizeKB })
	[string]$elapsed = "{0:N1}s" -f $script:stopwatch.Elapsed.TotalSeconds

	[int]$labelWidth = 14

	function Write-TableRow([string]$label, [string]$value, [string]$valueColor = "White") {
		Write-Host "  │" -ForegroundColor Green -NoNewline
		Write-Host ("{0,-$labelWidth}" -f " $label") -ForegroundColor Gray -NoNewline
		Write-Host "│" -ForegroundColor Green -NoNewline
		Write-Host " $value" -ForegroundColor $valueColor
	}

	[string]$headerText = " Archive Created Successfully"
	[int]$headerWidth = $headerText.Length + 1

	Write-Host ""
	Write-Host "  ┌$("─" * $headerWidth)┐" -ForegroundColor Green
	Write-Host "  │" -ForegroundColor Green -NoNewline
	Write-Host ("{0,-$headerWidth}" -f $headerText) -ForegroundColor White -NoNewline
	Write-Host "│" -ForegroundColor Green
	Write-Host "  ├$("─" * $labelWidth)┬$("─" * ($headerWidth - $labelWidth - 1))┘" -ForegroundColor Green
	Write-TableRow "Left Branch" $leftBranch
	Write-TableRow "Right Branch" $rightDisplay
	Write-TableRow "Archive" $archiveFile.Name
	Write-TableRow "Size" $sizeDisplay
	Write-TableRow "Elapsed" $elapsed
	Write-TableRow "Path" $archiveFile.Directory.FullName
	Write-Host "  └$("─" * $labelWidth)┘" -ForegroundColor Green
	Write-Host ""
	Write-Host "  Extract the archive and use a directory-diff tool to review:" -ForegroundColor Gray
	Write-Host "    Beyond Compare, Meld, VS Code, etc." -ForegroundColor DarkGray
	Write-Host ""
}
else
{
	Write-Host ""
	Write-Host "  No differences found between the specified branches." -ForegroundColor Yellow
	Write-Host ""
}
#endregion Summary

}
finally {
	$script:Temp.Cleanup()
	$script:Temp = $null
}