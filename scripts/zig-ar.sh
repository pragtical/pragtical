#!/bin/sh

set -eu

# Meson passes "T" to ar when creating thin archives.
# A normal archive stores the object file contents inside the .a file, while
# a thin archive only stores references to the original .o files.
# Zig's linker later rejects those thin archives in this build, so strip the
# thin-archive flag here and let zig ar produce a regular archive instead.
if [ "$#" -gt 0 ]; then
  case "$1" in
    *T*)
      first_arg=$(printf '%s' "$1" | tr -d 'T')
      shift
      set -- "$first_arg" "$@"
      ;;
  esac
fi

exec zig ar "$@"
