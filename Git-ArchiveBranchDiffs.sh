#!/usr/bin/env bash
set -euo pipefail

# Bash wrapper for Git-ArchiveBranchDiffs.ps1
# Downloads PowerShell Core if not already installed, then runs the .ps1 script.
#
# Usage:
#   bash ./Git-ArchiveBranchDiffs.sh [args...]
#   bash ./Git-ArchiveBranchDiffs.sh -nonInteractive
#
# All arguments are forwarded to the PowerShell script.
#
# NOTE: like any shell script, this requires 'execute' permission which can be set as follows
#   chmod +x Git-ArchiveBranchDiffs.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS_SCRIPT="$SCRIPT_DIR/Git-ArchiveBranchDiffs.ps1"

# If pwsh is already on PATH, use it directly
if command -v pwsh &>/dev/null; then
    pwsh "$PS_SCRIPT" "$@"
    exit $?
fi

# Detect platform and architecture
platform="$(uname -s)"
arch="$(uname -m)"

case "${arch}" in
    x86_64|amd64)    archSuffix="x64" ;;
    aarch64|arm64)   archSuffix="arm64" ;;
    *)               echo "Error: Unsupported architecture: ${arch}"; exit 1 ;;
esac

case "${platform}" in
    Linux*)     archiveExtension=".tar.gz"
                package="linux-${archSuffix}${archiveExtension}" ;;
    Darwin*)    archiveExtension=".tar.gz"
                package="osx-${archSuffix}${archiveExtension}" ;;
    CYGWIN*)    archiveExtension=".zip"
                package="win-${archSuffix}${archiveExtension}" ;;
    MINGW*)     archiveExtension=".zip"
                package="win-${archSuffix}${archiveExtension}" ;;
    *)          echo "Error: Unsupported platform: ${platform}"; exit 1 ;;
esac

echo
echo "Running on ${platform} (${arch})"

version="7.4.7" # update the version here to match any available PowerShell release
url="https://github.com/PowerShell/PowerShell/releases/download/v${version}/powershell-${version}-${package}"
tempDownload="/tmp/powershell${archiveExtension}"
targetdir="/usr/local/tmp/microsoft/powershell/${version}"

echo

pwshExists=false
if test -f "$targetdir/pwsh"; then
    echo "$targetdir/pwsh already exists."
    pwshExists=true
else
    echo "Downloading PowerShell ${version}..."
    echo "  URL: ${url}"
    echo

    curl -fSL -o "$tempDownload" "$url"

    sudo mkdir -p "$targetdir"

    echo "Extracting to ${targetdir}..."
    case "${archiveExtension}" in
        .tar.gz) sudo tar zxf "$tempDownload" -C "$targetdir" ;;
        .zip)    if command -v unzip &>/dev/null; then
                     sudo unzip -qo "$tempDownload" -d "$targetdir"
                 else
                     powershell.exe -nologo -noprofile -command \
                       "Add-Type -A 'System.IO.Compression.FileSystem'; [IO.Compression.ZipFile]::ExtractToDirectory('${tempDownload}', '${targetdir}')"
                 fi ;;
    esac

    sudo chmod +x "$targetdir/pwsh"

    # Clean up downloaded archive
    rm -f "$tempDownload"
fi

    # Create the symbolic link that points to pwsh
    #sudo ln -s $targetdir/pwsh /usr/local/bin/pwsh
    
    # Remove the symbolic link
    #unlink /usr/local/bin/pwsh
    
    # OS-X pre-req
    # xcode-select --install  # this could be part of the Darwin case in switch above
if [[ "$pwshExists" == false ]]; then
    echo "PowerShell is starting for the first time, please wait a moment..."
fi
echo

"$targetdir/pwsh" "$PS_SCRIPT" "$@"
