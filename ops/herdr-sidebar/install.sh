#!/usr/bin/env bash
# Installs (or removes) the Foreman runs panel for the Herdr desktop app.
# See README.md in this directory for what it does and how to use it.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: install.sh [--uninstall] [--no-keys] [--switch] [--no-check]

  (no flags)   install the mod, add the "foreman" layout, bind the shortcuts
  --uninstall  remove the mod, the "foreman" layout, its shortcuts and saved panel state
  --no-keys    leave keys.json alone (the panel works; the shortcuts are not bound)
  --switch     switch Herdr to the "foreman" layout afterwards (default Herdr home only)
  --no-check   skip `herdr-app check` on the installed mod

Environment:
  HERDR_APP_HOME    Herdr app home (default: ~/.config/herdr-app)
  FOREMAN_ENV_FILE  .env file holding FOREMAN_API_TOKEN (default: <this checkout>/.env)
EOF
}

uninstall=0 keys=1 switch=0 check=1
for arg in "$@"; do
  case "$arg" in
    --uninstall) uninstall=1 ;;
    --no-keys) keys=0 ;;
    --switch) switch=1 ;;
    --no-check) check=0 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "install.sh: unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
home_dir="${HERDR_APP_HOME:-$HOME/.config/herdr-app}"
env_file="${FOREMAN_ENV_FILE:-$repo_root/.env}"
mod_dir="$home_dir/mods/foreman-runs"
layout_file="$home_dir/layouts/foreman.json"
keys_file="$home_dir/keys.json"
snippet="$here/keys.layout-foreman.json"

command -v jq >/dev/null || { echo "install.sh: jq is required (brew install jq)" >&2; exit 1; }
[ -d "$home_dir" ] || { echo "install.sh: Herdr app home not found: $home_dir (start Herdr once, or set HERDR_APP_HOME)" >&2; exit 1; }

# write_if_changed FILE CONTENT: writes only when the content differs (an unchanged file keeps its
# mtime, and Herdr's hot reload is not triggered). Sets $changed to 1 or 0. Callers build CONTENT with
# `x="$(...)"`, so a failing jq/awk aborts the script (set -e) instead of writing a truncated file.
changed=0
write_if_changed() {
  changed=0
  if [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; then return 0; fi
  printf '%s\n' "$2" >"$1"
  changed=1
}

on_default_home() { [ -z "${HERDR_APP_HOME:-}" ] && command -v herdr-app >/dev/null; }

# --------------------------------------------------------------------------------- uninstall
if [ "$uninstall" = 1 ]; then
  # shellcheck disable=SC1010 # `do` here is a herdr-app subcommand, not the shell keyword
  if on_default_home; then herdr-app do layout.switch '{"name":"main"}' >/dev/null 2>&1 || true; fi
  rm -rf "$mod_dir" "$home_dir/data/foreman-runs"
  if [ -f "$layout_file" ]; then
    # Remove only the panel's block. The file goes too when that leaves it identical to Herdr's
    # main layout; if you changed it (width, other tweaks) it is kept, minus the panel.
    stripped="$(jq '(.. | select(type == "object" and .id == "sidebar-lists") | .children) |= map(select(.id != "foreman-runs"))' "$layout_file")"
    if [ -f "$home_dir/layouts/main.json" ] && [ "$(printf '%s' "$stripped" | jq -S .)" = "$(jq -S . "$home_dir/layouts/main.json")" ]; then
      rm -f "$layout_file"
    else
      write_if_changed "$layout_file" "$stripped"
      echo "Kept $layout_file (it differs from Herdr's main layout); removed only the panel from it."
    fi
  fi
  if [ -f "$keys_file" ]; then
    # Drop only the bindings this installer added (same chord AND same action).
    new_keys="$(jq --slurpfile s "$snippet" '
      if ."layout:foreman" then
        ."layout:foreman" |= with_entries(select(($s[0][.key]) != .value))
        | if (."layout:foreman" | length) == 0 then del(."layout:foreman") else . end
      else . end' "$keys_file")"
    write_if_changed "$keys_file" "$new_keys"
  fi
  echo "Removed the Foreman runs panel from $home_dir"
  exit 0
fi

# ----------------------------------------------------------------------------------- install
[ -f "$home_dir/layouts/main.json" ] || { echo "install.sh: $home_dir/layouts/main.json not found (start Herdr once)" >&2; exit 1; }

# 1. The mod. Only the ENV_FILE line is rewritten, to this checkout's .env.
mkdir -p "$mod_dir"
env_js="$(jq -Rn --arg p "$env_file" '$p')" # a JSON string is a valid JS string literal
mod_js="$(awk -v line="const ENV_FILE = $env_js;" '/^const ENV_FILE = / { print line; next } { print }' "$here/mod/main.js")"
printf '%s\n' "$mod_js" | grep -qF "const ENV_FILE = $env_js;" ||
  { echo "install.sh: could not point ENV_FILE at $env_file; has the \"const ENV_FILE = \" line in mod/main.js changed?" >&2; exit 1; }
write_if_changed "$mod_dir/main.js" "$mod_js"
cp "$here/mod/mod.json" "$mod_dir/mod.json"

# 2. The layout: a copy of Herdr's "main" with the panel between Spaces and Agents.
[ -f "$layout_file" ] || cp "$home_dir/layouts/main.json" "$layout_file"
jq -e '.. | objects | select(.id == "sidebar-lists")' "$layout_file" >/dev/null ||
  { echo "install.sh: $layout_file has no \"sidebar-lists\" node; this installer expects Herdr's main layout" >&2; exit 1; }
block='{"id":"foreman-runs","type":"block","content":{"mod":"foreman-runs"},"size":{"weight":1.2},"min":90}'
new_layout="$(jq --argjson block "$block" '
  (.. | select(type == "object" and .id == "sidebar-lists") | .children) |=
    (if any(.[]; .id == "foreman-runs") then .
     else (map(.id) | index("spaces")) as $i
          | if $i == null then error("no \"spaces\" block in sidebar-lists")
            else .[:$i + 1] + [$block] + .[$i + 1:] end
     end)' "$layout_file")"
write_if_changed "$layout_file" "$new_layout"

# 3. The shortcuts, in the "layout:foreman" section so they only apply while this layout shows.
#    Existing bindings win; a chord already bound to something else is reported, not replaced.
if [ "$keys" = 1 ]; then
  [ -f "$keys_file" ] || { echo "install.sh: $keys_file not found (start Herdr once, or use --no-keys)" >&2; exit 1; }
  conflicts="$(jq -r --slurpfile s "$snippet" '
    (."layout:foreman" // {}) as $cur
    | $s[0] | to_entries[] | select($cur[.key] != null and $cur[.key] != .value)
    | "  \(.key): already \($cur[.key]) (wanted \(.value))"' "$keys_file")"
  new_keys="$(jq --slurpfile s "$snippet" '."layout:foreman" = ($s[0] + (."layout:foreman" // {}))' "$keys_file")"
  write_if_changed "$keys_file" "$new_keys"
  [ "$changed" = 0 ] || echo "Bound the shortcuts in $keys_file (section \"layout:foreman\")."
  [ -z "$conflicts" ] || { echo "Left these existing bindings as they were:"; echo "$conflicts"; }
fi

# 4. Load-check the mod (renders it once; the app also hot-reloads it).
if [ "$check" = 1 ] && command -v herdr-app >/dev/null; then
  if check_out="$(herdr-app check "$mod_dir" 2>&1)"; then
    echo "herdr-app check: $check_out"
  else
    echo "$check_out" >&2
    echo "install.sh: herdr-app check failed for $mod_dir" >&2
    exit 1
  fi
fi

echo "Installed into $home_dir"
if [ "$switch" = 1 ] && on_default_home; then
  # shellcheck disable=SC1010
  herdr-app do layout.switch '{"name":"foreman"}' >/dev/null && echo "Switched to the foreman layout."
else
  echo "Switch to it with:  herdr-app do layout.switch '{\"name\":\"foreman\"}'   (or cmd-shift-l to cycle layouts)"
fi
