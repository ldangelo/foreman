#!/bin/sh
# install.sh — Foreman curl installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ldangelo/foreman/main/install.sh | sh
#
# Options (via environment variables):
#   FOREMAN_VERSION   — specific version tag to install (default: latest)
#   FOREMAN_INSTALL   — install directory override (default: auto-detect)
#   GITHUB_TOKEN      — GitHub API token to avoid rate limiting (optional)
#
# Supports: darwin-arm64, darwin-x64, linux-x64, linux-arm64
# Windows: use install.ps1 instead

set -eu

# ── Constants ──────────────────────────────────────────────────────────────────
REPO="ldangelo/foreman"
BINARY_NAME="foreman"
GITHUB_API="${FOREMAN_API_BASE:-https://api.github.com}"
GITHUB_RELEASES="${FOREMAN_RELEASES_BASE:-https://github.com/${REPO}/releases/download}"

# ── Terminal colors (safe for sh) ─────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold 2>/dev/null || printf '')
  RED=$(tput setaf 1 2>/dev/null || printf '')
  GREEN=$(tput setaf 2 2>/dev/null || printf '')
  YELLOW=$(tput setaf 3 2>/dev/null || printf '')
  BLUE=$(tput setaf 4 2>/dev/null || printf '')
  RESET=$(tput sgr0 2>/dev/null || printf '')
else
  BOLD=''
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  RESET=''
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
# All status output goes to stderr so that functions used in command
# substitution (e.g. version="$(fetch_latest_version)") only capture their
# actual return value on stdout.
info()    { printf '%s==>%s %s\n'    "${BLUE}${BOLD}" "${RESET}" "$*" >&2; }
success() { printf '%s✓%s %s\n'     "${GREEN}${BOLD}" "${RESET}" "$*" >&2; }
warn()    { printf '%s⚠️  %s%s\n'   "${YELLOW}" "$*" "${RESET}" >&2; }
error()   { printf '%s✗ Error:%s %s\n' "${RED}${BOLD}" "${RESET}" "$*" >&2; }
die()     { error "$@"; exit 1; }

# ── Pre-flight: required tools ────────────────────────────────────────────────
require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Required tool not found: $1. Please install it and try again."
  fi
}

require_tool curl
require_tool tar
require_tool uname

# ── OS Detection ──────────────────────────────────────────────────────────────
detect_os() {
  local raw_os
  raw_os="$(uname -s)"
  case "$raw_os" in
    Darwin) echo "darwin" ;;
    Linux)  echo "linux"  ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      die "Windows is not supported by this installer. Use install.ps1 instead:
  https://raw.githubusercontent.com/${REPO}/main/install.ps1"
      ;;
    *)
      die "Unsupported operating system: ${raw_os}"
      ;;
  esac
}

# ── Architecture Detection ────────────────────────────────────────────────────
detect_arch() {
  local raw_arch
  raw_arch="$(uname -m)"
  case "$raw_arch" in
    arm64|aarch64)         echo "arm64" ;;
    x86_64|x64|amd64)     echo "x64"   ;;
    *)
      die "Unsupported architecture: ${raw_arch}
Foreman binaries are available for: arm64 (Apple Silicon / ARM64), x86_64 (Intel/AMD)"
      ;;
  esac
}

# ── GitHub API: fetch latest release tag ─────────────────────────────────────
fetch_latest_version() {
  local api_url="${GITHUB_API}/repos/${REPO}/releases/latest"
  local auth_header=""
  local response

  if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth_header="Authorization: Bearer ${GITHUB_TOKEN}"
  fi

  info "Fetching latest release from GitHub..."

  if [ -n "$auth_header" ]; then
    response="$(curl -fsSL -H "$auth_header" -H "Accept: application/vnd.github.v3+json" "$api_url" 2>&1)" || {
      die "Failed to fetch release info from GitHub API.
  URL: ${api_url}
  Hint: Check your internet connection, or set GITHUB_TOKEN to avoid rate limiting."
    }
  else
    response="$(curl -fsSL -H "Accept: application/vnd.github.v3+json" "$api_url" 2>&1)" || {
      die "Failed to fetch release info from GitHub API.
  URL: ${api_url}
  Hint: Check your internet connection. If you hit GitHub's rate limit (60 req/hr unauthenticated),
  set GITHUB_TOKEN=<your-token> and re-run, or set FOREMAN_VERSION=<tag> to skip the API call."
    }
  fi

  # Extract tag_name from JSON (POSIX-compatible, no jq required)
  local tag
  tag="$(printf '%s' "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')"

  if [ -z "$tag" ]; then
    # Check for rate limit message
    if printf '%s' "$response" | grep -q "API rate limit exceeded"; then
      die "GitHub API rate limit exceeded (60 requests/hour for unauthenticated users).
Set GITHUB_TOKEN=<your-token> and re-run, or specify the version manually:
  FOREMAN_VERSION=v1.0.0 curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sh"
    fi
    die "Could not determine latest release tag from GitHub API response.
Specify the version manually with FOREMAN_VERSION=<tag> and retry."
  fi

  echo "$tag"
}

# ── Determine install directory ───────────────────────────────────────────────
# Returns: install_dir (absolute path)
# Sets:    USE_SUDO (1 = use sudo, 0 = no sudo needed)
determine_install_dir() {
  # If user explicitly set FOREMAN_INSTALL, use that
  if [ -n "${FOREMAN_INSTALL:-}" ]; then
    echo "${FOREMAN_INSTALL}"
    return
  fi

  local system_dir="/usr/local/bin"

  # Check if we can write to system dir without sudo
  if [ -w "$system_dir" ]; then
    USE_SUDO=0
    echo "$system_dir"
    return
  fi

  # Check if sudo is available and passwordless
  if command -v sudo >/dev/null 2>&1; then
    if sudo -n true 2>/dev/null; then
      USE_SUDO=1
      echo "$system_dir"
      return
    fi
    # Sudo is available but requires a password — prompt user
    warn "Installing to ${system_dir} requires sudo."
    warn "You will be prompted for your password."
    USE_SUDO=1
    echo "$system_dir"
    return
  fi

  # Fall back to user-local directory
  warn "sudo not available — installing to ~/.local/bin instead"
  USE_SUDO=0
  echo "${HOME}/.local/bin"
}

# ── Main Install Logic ─────────────────────────────────────────────────────────
main() {
  printf '\n%sForeman Installer%s\n' "${BOLD}" "${RESET}"
  printf '%s─────────────────%s\n\n' "${BOLD}" "${RESET}"

  # ── Detect platform ────────────────────────────────────────────────────────
  local os arch
  os="$(detect_os)"
  arch="$(detect_arch)"
  local platform="${os}-${arch}"

  info "Platform detected: ${platform}"

  # ── Determine version ──────────────────────────────────────────────────────
  local version
  if [ -n "${FOREMAN_VERSION:-}" ]; then
    version="${FOREMAN_VERSION}"
    info "Using specified version: ${version}"
  else
    version="$(fetch_latest_version)"
    info "Latest version: ${version}"
  fi

  # Validate version format (must start with 'v')
  case "$version" in
    v*) ;;
    *) die "Invalid version format: ${version} (expected 'v' prefix, e.g. v1.0.0)" ;;
  esac

  # ── Construct download URL ─────────────────────────────────────────────────
  local asset_name="foreman-${version}-${platform}.tar.gz"
  local download_url="${GITHUB_RELEASES}/${version}/${asset_name}"

  info "Downloading ${asset_name}..."

  # ── Create temp directory ──────────────────────────────────────────────────
  # Note: _FOREMAN_TMP_DIR must be a global (not local) so the cleanup trap
  # can access it after main() returns. POSIX sh traps fire at global scope.
  _FOREMAN_TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t foreman_install)"

  # Cleanup on exit
  cleanup() {
    rm -rf "${_FOREMAN_TMP_DIR:-}"
  }
  trap cleanup EXIT INT TERM

  # ── Download archive ───────────────────────────────────────────────────────
  local archive_path="${_FOREMAN_TMP_DIR}/${asset_name}"

  if ! curl -fsSL --progress-bar -o "$archive_path" "$download_url"; then
    die "Download failed.
  URL: ${download_url}
  Possible causes:
    - No release found for version ${version} on platform ${platform}
    - Network connectivity issue
    - Invalid version specified
  Check available releases at: https://github.com/${REPO}/releases"
  fi

  # Verify the archive is non-empty
  if [ ! -s "$archive_path" ]; then
    die "Downloaded archive is empty: ${archive_path}"
  fi

  # ── Verify checksum (SHA256) ───────────────────────────────────────────────
  info "Verifying checksum..."

  local checksums_url="${GITHUB_RELEASES}/${version}/checksums.txt"
  local checksums_path="${_FOREMAN_TMP_DIR}/checksums.txt"

  # Determine sha256 command (Linux: sha256sum, macOS: shasum -a 256)
  local sha256_cmd=""
  if command -v sha256sum >/dev/null 2>&1; then
    sha256_cmd="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    sha256_cmd="shasum -a 256"
  fi

  if [ -n "$sha256_cmd" ]; then
    if curl -fsSL -o "$checksums_path" "$checksums_url" 2>/dev/null; then
      # Extract expected hash for this asset from checksums.txt
      local expected_hash
      expected_hash="$(grep " ${asset_name}$" "$checksums_path" 2>/dev/null | awk '{print $1}' || true)"

      if [ -n "$expected_hash" ]; then
        local actual_hash
        actual_hash="$(cd "${_FOREMAN_TMP_DIR}" && $sha256_cmd "${asset_name}" | awk '{print $1}')"

        if [ "$actual_hash" = "$expected_hash" ]; then
          success "Checksum verified ✓"
        else
          die "Checksum mismatch for ${asset_name}!
  Expected: ${expected_hash}
  Got:      ${actual_hash}
  The downloaded file may be corrupt or tampered with. Please try again."
        fi
      else
        warn "Could not find checksum for ${asset_name} in checksums.txt — skipping verification."
      fi
    else
      warn "Could not download checksums.txt — skipping checksum verification."
    fi
  else
    warn "No sha256 tool found (sha256sum or shasum) — skipping checksum verification."
  fi

  # ── Extract archive ────────────────────────────────────────────────────────
  local extract_dir="${_FOREMAN_TMP_DIR}/extracted"
  mkdir -p "$extract_dir"

  info "Extracting archive..."
  if ! tar xzf "$archive_path" -C "$extract_dir"; then
    die "Failed to extract archive: ${archive_path}
The downloaded file may be corrupt. Try again."
  fi

  # ── Locate extracted binary ────────────────────────────────────────────────
  local binary_name="foreman-${platform}"
  local binary_src="${extract_dir}/${binary_name}"

  if [ ! -f "$binary_src" ]; then
    # Try to find it anywhere in the extract dir
    binary_src="$(find "$extract_dir" -name "foreman-${platform}" -type f 2>/dev/null | head -1 || true)"
    if [ -z "$binary_src" ]; then
      die "Could not find binary '${binary_name}' in extracted archive.
Contents of archive:
$(ls -la "$extract_dir" 2>/dev/null || echo '  (empty)')"
    fi
  fi

  # ── Locate side-car native addon ───────────────────────────────────────────
  local addon_src="${extract_dir}/better_sqlite3.node"
  local has_addon=0
  if [ -f "$addon_src" ]; then
    has_addon=1
  else
    warn "better_sqlite3.node not found in archive — database features may not work."
  fi

  # ── Determine install directory ────────────────────────────────────────────
  USE_SUDO=0
  local install_dir
  install_dir="$(determine_install_dir)"

  # Create install dir if needed (user-local path)
  if [ ! -d "$install_dir" ]; then
    info "Creating directory: ${install_dir}"
    mkdir -p "$install_dir" 2>/dev/null || {
      if [ "$USE_SUDO" -eq 1 ]; then
        sudo mkdir -p "$install_dir"
      else
        die "Cannot create install directory: ${install_dir}"
      fi
    }
  fi

  # ── Install binary ─────────────────────────────────────────────────────────
  local install_path="${install_dir}/${BINARY_NAME}"
  local addon_dest="${install_dir}/better_sqlite3.node"

  info "Installing foreman to ${install_path}..."

  chmod +x "$binary_src"

  if [ "$USE_SUDO" -eq 1 ]; then
    sudo cp -f "$binary_src" "$install_path"
    sudo chmod +x "$install_path"
    if [ "$has_addon" -eq 1 ]; then
      sudo cp -f "$addon_src" "$addon_dest"
    fi
  else
    cp -f "$binary_src" "$install_path"
    chmod +x "$install_path"
    if [ "$has_addon" -eq 1 ]; then
      cp -f "$addon_src" "$addon_dest"
    fi
  fi

  # ── PATH check ────────────────────────────────────────────────────────────
  local in_path=0
  # Check if install_dir is in PATH
  case ":${PATH}:" in
    *":${install_dir}:"*) in_path=1 ;;
  esac

  # ── Verify installation ────────────────────────────────────────────────────
  info "Verifying installation..."

  local installed_version
  if [ "$in_path" -eq 1 ]; then
    installed_version="$(foreman --version 2>/dev/null || true)"
  else
    installed_version="$("${install_path}" --version 2>/dev/null || true)"
  fi

  if [ -z "$installed_version" ]; then
    warn "Could not verify foreman version — the binary may still work."
    warn "Try running: ${install_path} --version"
  else
    success "Installed: ${installed_version}"
  fi

  # ── macOS Gatekeeper note ─────────────────────────────────────────────────
  if [ "$os" = "darwin" ]; then
    printf '\n%sNote (macOS):%s If you see a security warning:\n' "${YELLOW}" "${RESET}"
    printf '  System Settings → Privacy & Security → Allow Anyway\n'
    printf '  Or run: xattr -d com.apple.quarantine %s\n' "$install_path"
  fi

  # ── PATH instructions if needed ───────────────────────────────────────────
  if [ "$in_path" -eq 0 ]; then
    printf '\n%s%s is not in your PATH.%s\n' "${YELLOW}" "$install_dir" "${RESET}"
    printf 'Add the following to your shell config (~/.bashrc, ~/.zshrc, etc.):\n\n'
    printf '  %sexport PATH="%s:$PATH"%s\n\n' "${BOLD}" "$install_dir" "${RESET}"
    printf 'Then restart your shell or run:\n\n'
    printf '  %ssource ~/.bashrc%s   # or source ~/.zshrc\n\n' "${BOLD}" "${RESET}"
  fi

  # ── Success ────────────────────────────────────────────────────────────────
  printf '\n%s%s Foreman %s installed successfully!%s\n\n' \
    "${GREEN}${BOLD}" "✓" "${version}" "${RESET}"
  printf 'Run %sforeman --help%s to get started.\n\n' "${BOLD}" "${RESET}"
}

main "$@"
