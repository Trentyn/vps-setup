#!/bin/bash

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

trap 'error "Failed at line $LINENO."' ERR

cat > ~/.bashrc << 'EOF'
# ~/.bashrc: executed by bash(1) for non-login shells.

# Note: PS1 and umask are already set in /etc/profile. You should not
# need this unless you want different defaults for root.
# PS1='${debian_chroot:+($debian_chroot)}\h:\w\$ '
# umask 022

# You may uncomment the following lines if you want `ls' to be colorized:
# export LS_OPTIONS='--color=auto'
# eval "$(dircolors)"
# alias ls='ls $LS_OPTIONS'
# alias ll='ls $LS_OPTIONS -l'
# alias l='ls $LS_OPTIONS -lA'
#
# Some more alias to avoid making mistakes:
# alias rm='rm -i'
# alias cp='cp -i'
# alias mv='mv -i'

HISTCONTROL=ignoreboth:erasedups

# Console visuals
parse_git_branch() {
  git branch 2>/dev/null | grep '*' | sed 's/* / (/;s/$/)/'
}

PS1='\[\e[1;31m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\[\e[1;33m\]$(parse_git_branch)\[\e[0m\]\$ '
export PATH="$HOME/.local/bin:$PATH"
EOF

info "~/.bashrc updated"
info "Run 'source ~/.bashrc' to apply changes in the current session"
