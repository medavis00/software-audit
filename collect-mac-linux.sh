#!/bin/bash
# collect-mac-linux.sh - lists installed software on this Mac or Linux machine.
#
# Usage (from the software-audit folder):
#   bash collect-mac-linux.sh            # apps + Homebrew (mac) / flatpak + snap (linux)
#   bash collect-mac-linux.sh --all      # Linux: also every dpkg/rpm package (thousands)
#
# Writes inventories/<hostname>.json next to this script.
# Works with the bash 3.2 that ships on macOS; no extra tools needed.

INCLUDE_ALL=0
[ "$1" = "--all" ] && INCLUDE_ALL=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$SCRIPT_DIR/inventories"
HOST="$(hostname -s 2>/dev/null || hostname)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# Escape a string for JSON.
json_str() {
    printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\n\r'
}

# add_app NAME VERSION PUBLISHER SOURCE
# Fields are joined with the \037 unit separator, not tabs, because bash's
# `read` merges consecutive tabs and would lose empty fields.
US="$(printf '\037')"
add_app() {
    [ -z "$1" ] && return
    printf '%s\037%s\037%s\037%s\n' "$1" "$2" "$3" "$4" >> "$TMP"
}

case "$(uname -s)" in
Darwin)
    PLATFORM=macos
    OS_NAME="macOS $(sw_vers -productVersion 2>/dev/null)"
    for dir in /Applications /Applications/Utilities "$HOME/Applications"; do
        [ -d "$dir" ] || continue
        for app in "$dir"/*.app; do
            [ -d "$app" ] || continue
            plist="$app/Contents/Info"
            ver="$(defaults read "$plist" CFBundleShortVersionString 2>/dev/null)"
            [ -z "$ver" ] && ver="$(defaults read "$plist" CFBundleVersion 2>/dev/null)"
            pub="$(defaults read "$plist" CFBundleIdentifier 2>/dev/null)"
            add_app "$(basename "$app" .app)" "$ver" "$pub" "applications"
        done
    done
    if command -v brew >/dev/null 2>&1; then
        brew list --formula --versions 2>/dev/null | while read -r n v _; do add_app "$n" "$v" "" "brew"; done
        brew list --cask --versions 2>/dev/null | while read -r n v _; do add_app "$n" "$v" "" "brew-cask"; done
    fi
    ;;
*)
    PLATFORM=linux
    OS_NAME="$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
    [ -z "$OS_NAME" ] && OS_NAME="Linux $(uname -r)"
    if [ "$INCLUDE_ALL" = 1 ]; then
        if command -v dpkg-query >/dev/null 2>&1; then
            dpkg-query -W -f='${Package}\t${Version}\t${Maintainer}\n' 2>/dev/null | tr '\t' '\037' \
                | while IFS="$US" read -r n v m; do add_app "$n" "$v" "$m" "dpkg"; done
        elif command -v rpm >/dev/null 2>&1; then
            rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{VENDOR}\n' 2>/dev/null | tr '\t' '\037' \
                | while IFS="$US" read -r n v m; do add_app "$n" "$v" "$m" "rpm"; done
        fi
    else
        # Only packages the user asked for, not every dependency.
        if command -v apt-mark >/dev/null 2>&1; then
            for n in $(apt-mark showmanual 2>/dev/null); do
                v="$(dpkg-query -W -f='${Version}' "$n" 2>/dev/null)"
                add_app "$n" "$v" "" "apt"
            done
        elif command -v dnf >/dev/null 2>&1; then
            for n in $(dnf repoquery --userinstalled --qf '%{name}' 2>/dev/null); do
                v="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$n" 2>/dev/null)"
                add_app "$n" "$v" "" "dnf"
            done
        fi
    fi
    if command -v flatpak >/dev/null 2>&1; then
        flatpak list --app --columns=name,version,origin 2>/dev/null | tr '\t' '\037' \
            | while IFS="$US" read -r n v o; do add_app "$n" "$v" "$o" "flatpak"; done
    fi
    if command -v snap >/dev/null 2>&1; then
        snap list 2>/dev/null | tail -n +2 | while read -r n v _ _ p _; do add_app "$n" "$v" "$p" "snap"; done
    fi
    ;;
esac

# Extra items, named with a prefix so approved-apps.csv can check them.
if command -v code >/dev/null 2>&1; then
    code --list-extensions --show-versions 2>/dev/null \
        | while IFS=@ read -r n v; do add_app "vscode-ext:$n" "$v" "" "check"; done
fi
if command -v git >/dev/null 2>&1; then
    git config --global --list 2>/dev/null \
        | while IFS== read -r k v; do add_app "git-config:$k" "$v" "" "check"; done
fi

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/$HOST.json"
COUNT=0
{
    printf '{\n  "hostname": "%s",\n  "os": "%s",\n  "platform": "%s",\n  "collected_at": "%s",\n  "apps": [' \
        "$(json_str "$HOST")" "$(json_str "$OS_NAME")" "$PLATFORM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    sep=""
    sort -f -u "$TMP" | while IFS="$US" read -r n v p s; do
        printf '%s\n    {"name": "%s", "version": "%s", "publisher": "%s", "source": "%s"}' \
            "$sep" "$(json_str "$n")" "$(json_str "$v")" "$(json_str "$p")" "$(json_str "$s")"
        sep=","
    done
    printf '\n  ]\n}\n'
} > "$OUT"
COUNT="$(sort -u "$TMP" | wc -l | tr -d ' ')"
echo "Found $COUNT apps. Saved to $OUT"
