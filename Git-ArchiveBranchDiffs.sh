#!/usr/bin/env bash

# call this script to execute ./Git-ArchiveBranchDiffs.ps1
# it will download PowerShell Core if necessary
#
#  Usage
#         sudo bash ./Git-ArchiveBranchDiffs.sh
#
# NOTE: like any shell script, this requires 'execute' permission which can be set as follows
#         sudo chmod +x Git-ArchiveBranchDiffs.sh

function RunPowerShellScript()
{
    local platform="$(uname -s)"
    case "${platform}" in
        Linux*)     local archiveExtension=.tar.gz  #Linux
                    local unarchive='sudo tar zxf ${tempDownload} -C ${targetdir}'
					local package=linux-x64${archiveExtension} ;;
        Darwin*)    local archiveExtension=.tar.gz #Mac
                    local unarchive='sudo tar zxf ${tempDownload} -C ${targetdir}'
					local package=osx-x64${archiveExtension} ;;
        CYGWIN*)    local archiveExtension=.zip #Cygwin
                    local unarchive='sudo powershell.exe -nologo -noprofile -command "& { Add-Type -A \''System.IO.Compression.FileSystem\''; [IO.Compression.ZipFile]::ExtractToDirectory(\''${tempDownload}\'', \''${targetdir}\''); }"'
					local package=win-x64${archiveExtension} ;;
        MINGW*)     local archiveExtension=.zip #Mingw
					local unarchive='sudo powershell.exe -nologo -noprofile -command "& { Add-Type -A \''System.IO.Compression.FileSystem\''; [IO.Compression.ZipFile]::ExtractToDirectory(\''${tempDownload}\'', \''${targetdir}\''); }"'
					local package=win-x64${archiveExtension} ;;
        *)          machine="UNKNOWN:${platform}" ;;
    esac

    echo
    echo Running on $platform

    local version=7.3.4 #update the version here to match any available PowerShell release 
    local url=https://github.com/PowerShell/PowerShell/releases/download/v${version}/powershell-${version}-${package}
    local tempDownload=/tmp/powershell${archiveExtension}
    local targetdir=/usr/local/tmp/microsoft/powershell/${version}

    echo

    if test -f $targetdir/pwsh; then
        echo "$targetdir/pwsh already exists."
        local pswhExists=true
    else
        echo "Downloading $tempDownload..."
        echo
        # Download the powershell '.tar.gz' archive
        curl -L -o $tempDownload $url

        # Create the target folder where powershell will be placed
        sudo mkdir -p $targetdir

        echo "Extracting $tempDownload to ${targetdir}..."
        # Expand powershell to the target folder
        eval $unarchive

        # Set execute permissions
        sudo chmod +x $targetdir/pwsh
        local pswhExists=false
    fi

    # Create the symbolic link that points to pwsh
    #sudo ln -s $targetdir/pwsh /usr/local/bin/pwsh
    
    # Remove the symbolic link
    #unlink /usr/local/bin/pwsh
    
    # OS-X pre-req
    # xcode-select --install  # this could be part of the Darwin case in switch above

    echo $targetdir/pwsh $1
    if [[ "$pswhExists" == false ]]; then
        echo PowerShell is starting for the first time, please wait a moment...
    fi
    echo
    $targetdir/pwsh $1
    echo

    # Cleanup (defeats the existence check)
    #sudo rm -f -r $targetdir
}

RunPowerShellScript ./Git-ArchiveBranchDiffs.ps1