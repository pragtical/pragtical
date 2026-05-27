#!/usr/bin/env sh
set -eu

run() {
  local name="${1:-demo}"
  for file in "$@"; do
    case "$file" in
      *.lua) printf '%s\n' "$name:$file" ;;
      *) continue ;;
    esac
  done
}

if [ "${DEBUG:-0}" = "1" ]; then
  run "debug" "$@"
fi

alias break case cd continue declare do done echo elif else enable esac eval exec exit export false fi for function getopts hash help history if in jobs kill let local mapfile printf pwd read readarray readonly return select set shift source test then time true type unalias unset until while ;
