# Windows Installation Guide

Foreman can be installed on Windows 10/11 using the PowerShell installer script.

## Prerequisites

- Windows 10 or Windows 11 (64-bit)
- PowerShell 5.0+ (pre-installed on Windows 10+)
- Internet connection

## Quick Install

Open **PowerShell** as a regular user and run:

```powershell
irm https://raw.githubusercontent.com/ldangelo/foreman/main/install.ps1 | iex
```

The installer automatically:
- Downloads the `foreman-win-x64.exe` binary from the [latest GitHub Release](https://github.com/ldangelo/foreman/releases/latest)
- Installs to `%LOCALAPPDATA%\foreman\` (no admin required)
- Places `better_sqlite3.node` alongside the binary (required side-car)
- Adds the install directory to your user `PATH`
- Verifies the install with `foreman --version`

## Options

```powershell
# Install a specific version
$env:FOREMAN_VERSION = "v1.2.3"
irm https://raw.githubusercontent.com/ldangelo/foreman/main/install.ps1 | iex

# Install to a custom directory
$env:FOREMAN_INSTALL = "C:\tools\foreman"
irm https://raw.githubusercontent.com/ldangelo/foreman/main/install.ps1 | iex

# Bypass GitHub API rate limits
$env:GITHUB_TOKEN = "ghp_yourtoken"
irm https://raw.githubusercontent.com/ldangelo/foreman/main/install.ps1 | iex
```

## After Installation

Open a **new** PowerShell window (so the updated PATH takes effect), then:

```powershell
foreman --version
```

## Windows Defender / SmartScreen

If Windows Defender or SmartScreen flags the binary:

1. Right-click `foreman-win-x64.exe` in File Explorer
2. Select **Properties**
3. Check the **Unblock** checkbox at the bottom
4. Click **OK**

Or via PowerShell:

```powershell
Unblock-File "$env:LOCALAPPDATA\foreman\foreman-win-x64.exe"
```

## Manual Installation

1. Download `foreman-vX.Y.Z-win-x64.zip` from [GitHub Releases](https://github.com/ldangelo/foreman/releases/latest)
2. Extract the zip — you'll find `foreman-win-x64.exe` and `better_sqlite3.node`
3. Copy **both files** to a directory in your PATH (e.g., `C:\Windows\System32` or a custom bin dir)
4. Rename `foreman-win-x64.exe` to `foreman.exe`
5. Open a new terminal and run `foreman --version`

> **Important:** `better_sqlite3.node` must remain in the **same directory** as `foreman.exe`. Without it, the binary will fail at startup.

## Verify Checksums

```powershell
# Download checksums.txt
$tag = "v1.0.0"
Invoke-WebRequest "https://github.com/ldangelo/foreman/releases/download/$tag/checksums.txt" -OutFile checksums.txt

# Verify the zip
Get-FileHash "foreman-$tag-win-x64.zip" -Algorithm SHA256
# Compare against the value in checksums.txt
```

## Uninstalling

```powershell
# Remove the binary
Remove-Item "$env:LOCALAPPDATA\foreman" -Recurse -Force

# Remove from PATH (user-level)
$path = [System.Environment]::GetEnvironmentVariable("PATH", "User")
$newPath = ($path -split ";" | Where-Object { $_ -notmatch "\\foreman" }) -join ";"
[System.Environment]::SetEnvironmentVariable("PATH", $newPath, "User")
```

## Troubleshooting

**"foreman is not recognized as an internal or external command"**
- Open a new PowerShell window after installation (PATH changes require a new session)
- Verify the install directory is in your PATH: `echo $env:PATH`

**"Access is denied" error**
- The installer doesn't require admin rights — it installs to `%LOCALAPPDATA%\foreman`
- If using `FOREMAN_INSTALL`, ensure you have write access to that directory

**Binary crashes on startup with "better_sqlite3 module not found"**
- Ensure `better_sqlite3.node` is in the same directory as `foreman-win-x64.exe`
- Re-run the installer to restore the side-car file

**GitHub API rate limit hit**
- Set `$env:GITHUB_TOKEN` to a personal access token (no permissions required)
- Or wait an hour for the rate limit to reset
