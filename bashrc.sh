#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/setup-common.sh
source "$SCRIPT_DIR/lib/setup-common.sh"

trap 'error "Failed at line $LINENO."' ERR

TARGET_USER="${1:-$(detect_target_user)}"
TARGET_HOME=$(target_home "$TARGET_USER")
BASHRC_PATH="$TARGET_HOME/.bashrc"
BACKUP_PATH="$TARGET_HOME/.bashrc.bak.$(date +%Y%m%d%H%M%S)"

write_bashrc() {
    cat <<'EOF'
# ~/.bashrc: executed by bash(1) for non-login shells.

HISTCONTROL=ignoreboth:erasedups
shopt -s histappend

parse_git_branch() {
  git branch 2>/dev/null | grep '\*' | sed 's/\* / (/;s/$/)/'
}

PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\[\e[1;33m\]$(parse_git_branch)\[\e[0m\]\$ '

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF
}

if [[ -f "$BASHRC_PATH" ]]; then
    warn "Existing bashrc found: $BASHRC_PATH"
    if ! confirm "Replace it with the project template?"; then
        warn "bashrc update skipped"
        exit 0
    fi
    cp "$BASHRC_PATH" "$BACKUP_PATH"
    info "Backup created: $BACKUP_PATH"
else
    if ! confirm "Create bashrc for $TARGET_USER?"; then
        warn "bashrc creation skipped"
        exit 0
    fi
fi

write_bashrc > "$BASHRC_PATH"
chown "$TARGET_USER:$TARGET_USER" "$BASHRC_PATH"
chmod 644 "$BASHRC_PATH"

info "$BASHRC_PATH updated"
info "Run 'source ~/.bashrc' in the target shell to apply changes"
