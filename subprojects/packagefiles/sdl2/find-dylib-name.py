#!/usr/bin/env python3
"""
helper script to find libraries by their
name independent of their full SONAME.

Used to detect if its possible to dynamically
link against against certain dependencies
instead of statically.

Only used when `prefer_dlopen` is enabled

functional equivalent to
https://github.com/libsdl-org/SDL/blob/072db7b/cmake/sdlchecks.cmake#L1

e.g. SDL2 -> libSDL2-2.0.so.0
"""

import subprocess
import os
import re
import sys
import pathlib


def verbose(*args):
    print(*args, file=sys.stderr)


# TODO cross-compilation support for this awful hack somehow
def ldconf_dirs(ldconf='/etc/ld.so.conf'):
    ldconf = pathlib.Path(ldconf)

    try:
        text = ldconf.read_text()
    except Exception as e:
        verbose('Failed to read ', str(ldconf), ': ', str(e))
        return []

    entries = []

    for line in text.split('\n'):
        line = line.strip()

        if not line or line.startswith('#'):
            continue

        if line.startswith('include '):
            for d in glob.glob(line[8:].lstrip()):
                entries += ldconf_dirs(d)
        else:
            entries.append(line)

    return entries


def main(argv):
    libname = argv[1]
    cc = argv[2:]

    verbose('Looking for', libname)
    verbose('cc:', cc)

    o = subprocess.run(cc + ['-print-search-dirs'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    libdirs = re.search(r'[\^\n]libraries: =(.*)', o.stdout.decode('utf-8')).group(1).strip().split(os.pathsep)

    verbose('Search path:\n\t' + '\n\t'.join(libdirs))

    for libdir in libdirs:
        p = pathlib.Path(libdir) / 'lib{}.so'.format(libname)
        if p.is_file():
            verbose('Found', p)
            p = p.resolve()
            verbose('Real path', p)
            verbose('Name', p.name)
            dlname = re.search(r'(.*?\.so(?:\.[^.]+)?)', p.name).group(0)
            verbose('Reduced name', dlname)
            assert p.with_name(dlname).resolve() == p
            print(dlname)
            quit(0)

    quit(1)


if __name__ == '__main__':
    main(sys.argv)
