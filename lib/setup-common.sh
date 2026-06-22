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

require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "Run this script as root: sudo bash $0"
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
    eval printf '%s\n' "~${user_name}"
}

run_as_target_user() {
    if [[ "$CURRENT_USER" == "root" ]]; then
        "$@"
    else
        sudo -u "$CURRENT_USER" "$@"
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

normalize_github_repo_url() {
    local repo_url="$1"

    if [[ "$repo_url" =~ ^git@ ]]; then
        printf '%s\n' "$repo_url"
        return
    fi

    if [[ "$repo_url" =~ ^https://github\.com/([^/]+)/([^/]+?)(\.git)?/?$ ]]; then
        printf 'git@github.com:%s/%s.git\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return
    fi

    printf '%s\n' "$repo_url"
}

repo_name_from_url() {
    local repo_url="$1"
    local repo_name

    repo_name=$(basename "$repo_url")
    repo_name=${repo_name%.git}
    printf '%s\n' "$repo_name"
}

repo_slug_from_url() {
    local repo_url="$1"

    if [[ "$repo_url" =~ ^https://github\.com/([^/]+)/([^/]+?)(\.git)?/?$ ]]; then
        printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return
    fi

    if [[ "$repo_url" =~ ^git@github\.com:([^/]+)/([^/]+?)(\.git)?$ ]]; then
        printf '%s/%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return
    fi

    printf '%s\n' "$repo_url"
}

extract_repo_slug_from_github_ssh_output() {
    local ssh_output="$1"

    if [[ "$ssh_output" =~ Hi[[:space:]]+([^[:space:]!]+)! ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi

    return 1
}
