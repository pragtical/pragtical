# Meson builds and links the libiconv archive after SDL's configuration probes.
# An empty interface keeps CMake from adding an external iconv.lib link;
# Meson supplies the actual dependency and headers to the translated targets.
include_guard(GLOBAL)

add_library(iconv INTERFACE IMPORTED)

# The bundled GNU implementation provides these APIs; its archive is not yet
# available for CMake's configure-time link tests.
set(ICONV_IN_LIBC 0 CACHE INTERNAL "iconv is provided by Meson" FORCE)
set(ICONV_IN_LIBICONV 1 CACHE INTERNAL "GNU libiconv is provided by Meson" FORCE)
set(LIBC_HAS_ICONV_H 1 CACHE INTERNAL "GNU libiconv headers are provided by Meson" FORCE)
