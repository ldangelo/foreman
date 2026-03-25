# install.ps1 — Foreman PowerShell installer for Windows
#
# Usage:
#   irm https://raw.githubusercontent.com/ldangelo/foreman/main/install.ps1 | iex
#
# Options (via environment variables):
#   FOREMAN_VERSION   — specific version tag to install (default: latest)
#   FOREMAN_INSTALL   — install directory override (default: %LOCALAPPDATA%\foreman)
#   GITHUB_TOKEN      — GitHub API token to avoid rate limiting (optional)
#
# Supports: Windows x64 only
# macOS/Linux: use install.sh instead

#Requires -Version 5.0

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ── Constants ──────────────────────────────────────────────────────────────────
$REPO            = 'ldangelo/foreman'
$BINARY_NAME     = 'foreman.exe'
$GITHUB_API      = 'https://api.github.com'
$GITHUB_RELEASES = "https://github.com/$REPO/releases/download"

# ── Terminal colors ────────────────────────────────────────────────────────────
function Write-Info    { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Cyan   }
function Write-Success { param([string]$Msg) Write-Host "✓ $Msg"  -ForegroundColor Green  }
function Write-Warn    { param([string]$Msg) Write-Host "⚠  $Msg"  -ForegroundColor Yellow }
function Write-Err     { param([string]$Msg) Write-Host "✗ Error: $Msg" -ForegroundColor Red }

function Exit-Error {
    param([string]$Msg)
    Write-Err $Msg
    exit 1
}

# ── Platform check ─────────────────────────────────────────────────────────────
if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
    Exit-Error "This installer is for Windows only. On macOS/Linux, use install.sh:`n  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh"
}

# ── GitHub API: fetch latest release tag ──────────────────────────────────────
function Get-LatestVersion {
    $apiUrl = "$GITHUB_API/repos/$REPO/releases/latest"
    $headers = @{ Accept = 'application/vnd.github.v3+json' }

    if ($env:GITHUB_TOKEN) {
        $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
    }

    Write-Info 'Fetching latest release from GitHub...'

    try {
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
        $tag = $response.tag_name
    }
    catch {
        $errMsg = $_.ToString()
        if ($errMsg -match 'rate limit') {
            Exit-Error "GitHub API rate limit exceeded (60 requests/hour for unauthenticated users).`nSet `$env:GITHUB_TOKEN=<your-token> and re-run, or specify the version manually:`n  `$env:FOREMAN_VERSION='v1.0.0'; irm https://raw.githubusercontent.com/$REPO/main/install.ps1 | iex"
        }
        Exit-Error "Failed to fetch release info from GitHub API.`n  URL: $apiUrl`n  Error: $errMsg`n  Hint: Check your internet connection, or set GITHUB_TOKEN to avoid rate limiting."
    }

    if ([string]::IsNullOrWhiteSpace($tag)) {
        Exit-Error "Could not determine latest release tag from GitHub API response.`nSpecify the version manually: `$env:FOREMAN_VERSION='v1.0.0'"
    }

    return $tag
}

# ── Determine install directory ────────────────────────────────────────────────
function Get-InstallDir {
    if ($env:FOREMAN_INSTALL) {
        return $env:FOREMAN_INSTALL
    }

    $localAppData = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        # Fallback if %LOCALAPPDATA% is not set (rare edge case)
        $localAppData = Join-Path $env:USERPROFILE 'AppData\Local'
    }

    return Join-Path $localAppData 'foreman'
}

# ── PATH: add directory to user PATH if not already present ───────────────────
function Add-ToUserPath {
    param([string]$Dir)

    $currentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($null -eq $currentPath) { $currentPath = '' }

    # Normalise and check
    $dirs = $currentPath -split ';' | Where-Object { $_ -ne '' }
    $alreadyPresent = $dirs | Where-Object { $_ -ieq $Dir }

    if ($alreadyPresent) {
        return $false   # already in PATH
    }

    $newPath = ($dirs + $Dir) -join ';'
    [System.Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')

    # Also update the current session's PATH so the user can use foreman immediately
    $env:PATH = $env:PATH.TrimEnd(';') + ";$Dir"

    return $true
}

# ── Main ───────────────────────────────────────────────────────────────────────
function Main {
    Write-Host ''
    Write-Host 'Foreman Installer' -ForegroundColor White -BackgroundColor DarkBlue
    Write-Host '-----------------'
    Write-Host ''

    # ── Determine version ──────────────────────────────────────────────────────
    $version = $env:FOREMAN_VERSION
    if ($version) {
        Write-Info "Using specified version: $version"
    }
    else {
        $version = Get-LatestVersion
        Write-Info "Latest version: $version"
    }

    # Validate version format (must start with 'v')
    if ($version -notmatch '^v') {
        Exit-Error "Invalid version format: $version (expected 'v' prefix, e.g. v1.0.0)"
    }

    # ── Construct download URL ─────────────────────────────────────────────────
    $assetName   = "foreman-$version-win-x64.zip"
    $downloadUrl = "$GITHUB_RELEASES/$version/$assetName"

    Write-Info "Downloading $assetName..."

    # ── Create temp directory ──────────────────────────────────────────────────
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "foreman_install_$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    try {
        # ── Download archive ───────────────────────────────────────────────────
        $archivePath = Join-Path $tmpDir $assetName

        $webHeaders = @{ Accept = 'application/octet-stream' }
        if ($env:GITHUB_TOKEN) {
            $webHeaders['Authorization'] = "Bearer $env:GITHUB_TOKEN"
        }

        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -Headers $webHeaders -UseBasicParsing -ErrorAction Stop
        }
        catch {
            Exit-Error "Download failed.`n  URL: $downloadUrl`n  Error: $($_.ToString())`n  Possible causes:`n    - No release found for version $version on win-x64`n    - Network connectivity issue`n    - Invalid version specified`n  Check available releases at: https://github.com/$REPO/releases"
        }

        # Verify the archive is non-empty
        $archiveItem = Get-Item $archivePath -ErrorAction SilentlyContinue
        if (-not $archiveItem -or $archiveItem.Length -eq 0) {
            Exit-Error "Downloaded archive is empty: $archivePath"
        }

        # ── Extract archive ────────────────────────────────────────────────────
        $extractDir = Join-Path $tmpDir 'extracted'
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null

        Write-Info 'Extracting archive...'
        try {
            Expand-Archive -Path $archivePath -DestinationPath $extractDir -Force -ErrorAction Stop
        }
        catch {
            Exit-Error "Failed to extract archive: $archivePath`nThe downloaded file may be corrupt. Try again.`nError: $($_.ToString())"
        }

        # ── Locate extracted binary ────────────────────────────────────────────
        $binarySourceName = 'foreman-win-x64.exe'
        $binarySrc = Join-Path $extractDir $binarySourceName

        if (-not (Test-Path $binarySrc)) {
            # Try a recursive search in case the archive has a subdirectory
            $found = Get-ChildItem -Path $extractDir -Recurse -Filter $binarySourceName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                $binarySrc = $found.FullName
            }
            else {
                $contents = (Get-ChildItem -Path $extractDir -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name) -join ', '
                Exit-Error "Could not find binary '$binarySourceName' in extracted archive.`nContents: $contents"
            }
        }

        # ── Determine install directory ────────────────────────────────────────
        $installDir = Get-InstallDir

        if (-not (Test-Path $installDir)) {
            Write-Info "Creating directory: $installDir"
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }

        # ── Install binary ─────────────────────────────────────────────────────
        $installPath = Join-Path $installDir $BINARY_NAME

        Write-Info "Installing foreman to $installPath..."
        Copy-Item -Path $binarySrc -Destination $installPath -Force

        # ── PATH modification ──────────────────────────────────────────────────
        $addedToPath = Add-ToUserPath -Dir $installDir

        if ($addedToPath) {
            Write-Info "Added $installDir to user PATH."
        }
        else {
            Write-Info "$installDir is already in your PATH."
        }

        # ── Verify installation ────────────────────────────────────────────────
        Write-Info 'Verifying installation...'

        try {
            $installedVersion = & $installPath --version 2>&1
            if ($installedVersion) {
                Write-Success "Installed: $installedVersion"
            }
            else {
                Write-Warn "Could not verify foreman version — the binary may still work."
                Write-Warn "Try running: $installPath --version"
            }
        }
        catch {
            Write-Warn "Could not verify foreman version — the binary may still work."
            Write-Warn "Try running: $installPath --version"
        }

        # ── Success ────────────────────────────────────────────────────────────
        Write-Host ''
        Write-Success "Foreman $version installed successfully!"
        Write-Host ''

        if ($addedToPath) {
            Write-Host 'NOTE: PATH has been updated for your user. You may need to open a new' -ForegroundColor Yellow
            Write-Host '      PowerShell/terminal window for the changes to take effect.' -ForegroundColor Yellow
            Write-Host ''
        }

        Write-Host "Run " -NoNewline
        Write-Host "foreman --help" -ForegroundColor Cyan -NoNewline
        Write-Host " to get started."
        Write-Host ''
    }
    finally {
        # ── Cleanup temp directory ─────────────────────────────────────────────
        if (Test-Path $tmpDir) {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Main
