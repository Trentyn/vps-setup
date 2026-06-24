#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*" >&2; }
note()  { echo -e "${BLUE}[-]${NC} $*"; }
die()   { error "$*"; exit 1; }

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "Run this script from a root shell: bash $0"
        exit 1
    fi
}

confirm() {
    local answer
    local prompt_text="${1:-Continue?}"

    while true; do
        read -r -p "$prompt_text [y/N]: " answer
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]|"") return 1 ;;
            *) warn "Please answer y or n" ;;
        esac
    done
}

pause() {
    read -r -p "${1:-Press Enter to continue...}" _
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

package_installed() {
    dpkg -s "$1" >/dev/null 2>&1
}

require_command() {
    if ! command_exists "$1"; then
        error "$2"
        exit 1
    fi
}

detect_target_user() {
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
    else
        printf '%s\n' "root"
    fi
}

target_home() {
    local user_name="$1"
    local home_dir

    home_dir=$(getent passwd "$user_name" | cut -d: -f6)
    if [[ -n "$home_dir" ]]; then
        printf '%s\n' "$home_dir"
        return
    fi

    eval printf '%s\n' "~${user_name}"
}

run_as_target_user() {
    if [[ "$CURRENT_USER" == "root" ]]; then
        "$@"
    elif command_exists sudo; then
        sudo -u "$CURRENT_USER" "$@"
    elif command_exists runuser; then
        runuser -u "$CURRENT_USER" -- "$@"
    else
        die "Neither sudo nor runuser is available to switch to $CURRENT_USER"
    fi
}

ensure_ssh_dir() {
    local home_dir="$1"
    local user_name="$2"

    mkdir -p "$home_dir/.ssh"
    chown "$user_name:$user_name" "$home_dir/.ssh"
    chmod 700 "$home_dir/.ssh"
    touch "$home_dir/.ssh/authorized_keys"
    chown "$user_name:$user_name" "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
}

file_contains() {
    local file_path="$1"
    local pattern="$2"

    [[ -f "$file_path" ]] && grep -Fq "$pattern" "$file_path"
}

ensure_line_in_file() {
    local line="$1"
    local file_path="$2"

    touch "$file_path"
    if ! grep -Fxq "$line" "$file_path"; then
        printf '%s\n' "$line" >> "$file_path"
    fi
}

append_block_to_file() {
    local block="$1"
    local file_path="$2"

    {
        [[ -f "$file_path" ]] && cat "$file_path"
        printf '\n%s\n' "$block"
    } > "${file_path}.tmp"
    mv "${file_path}.tmp" "$file_path"
}

replace_github_ssh_managed_block() {
    local file_path="$1"
    local marker_start="$2"
    local marker_end="$3"
    local host_alias="$4"
    local block="$5"

    touch "$file_path"
    awk -v marker_start="$marker_start" -v marker_end="$marker_end" -v host_alias="$host_alias" '
        index($0, marker_start) == 1 {
            if (index($0, "\\nHost " host_alias) > 0) {
                next
            }
            in_managed_block = 1
            next
        }
        in_managed_block {
            if (index($0, marker_end) == 1) {
                in_managed_block = 0
                next
            }
            if ($0 == "Host " host_alias) {
                next
            }
            if ($0 ~ /^[[:space:]]+(HostName|User|IdentitiesOnly|IdentityFile)[[:space:]]/) {
                next
            }
            in_managed_block = 0
        }
        { print }
    ' "$file_path" > "${file_path}.tmp"
    printf '\n%s\n' "$block" >> "${file_path}.tmp"
    mv "${file_path}.tmp" "$file_path"
}

ensure_public_key_in_authorized_keys() {
    local pub_path="$1"
    local home_dir="$2"
    local user_name="$3"

    ensure_line_in_file "$(cat "$pub_path")" "$home_dir/.ssh/authorized_keys"
    chown "$user_name:$user_name" "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
    info "authorized_keys updated"
}

extract_repo_slug_from_github_ssh_output() {
    local ssh_output="$1"

    if [[ "$ssh_output" =~ Hi[[:space:]]+([^[:space:]!]+)! ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}

valid_repo_slug() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
}

save_repo_slug_state() {
    local repo_slug="$1"

    if ! valid_repo_slug "$repo_slug"; then
        warn "Repository slug has unexpected format and was not saved: $repo_slug"
        return
    fi

    mkdir -p "$SETUP_STATE_DIR"
    printf '%s\n' "$repo_slug" > "$REPO_SLUG_FILE"
    chown "$CURRENT_USER:$CURRENT_USER" "$SETUP_STATE_DIR" "$REPO_SLUG_FILE"
    chmod 700 "$SETUP_STATE_DIR"
    chmod 600 "$REPO_SLUG_FILE"
}

load_repo_slug_state() {
    local saved_slug

    [[ -f "$REPO_SLUG_FILE" ]] || return 0

    IFS= read -r saved_slug < "$REPO_SLUG_FILE" || true
    if valid_repo_slug "$saved_slug"; then
        REPO_SLUG="$saved_slug"
        info "Saved repository detected: $REPO_SLUG"
    else
        warn "Ignoring invalid saved repository slug in $REPO_SLUG_FILE"
    fi
}
