#!/usr/bin/env bash

: ${CC=gcc}
: ${HOSTCC=$CC}
: ${AR=ar}
: ${MAKE=make}
: ${BIN=ppm}
: ${JOBS=4}

SRCS="src/*.c"
COMPILE_FLAGS="$CFLAGS -Ilib/prefix/include" # We specifically rename this and LDFLAGS, because exotic build environments export these to subprcoesses.
LINK_FLAGS="$LDFLAGS -lm -Llib/prefix/lib -Llib/prefix/lib64"   # And ideally we don't want to mess with the underlying build processes, unless we're explicit about it.

[[ "$@" == "clean" ]] && rm -rf lib/libgit2/build lib/zlib/build lib/libzip/build lib/mbedtls/build lib/prefix lua $BIN *.exe src/ppm.luac src/ppm.lua.c && exit 0
cmake --version >/dev/null 2>/dev/null || { echo "Please ensure that you have cmake installed." && exit -1; }

# Build supporting libraries, libz, libmbedtls, libmbedcrypto, libgit2, libzip, libmicrotar, liblua
[[ " $@" != *" -g"* ]] && CMAKE_DEFAULT_FLAGS="$CMAKE_DEFAULT_FLAGS -DCMAKE_BUILD_TYPE=Release" || CMAKE_DEFUALT_FLAGS="$CMAKE_DEFAULT_FLAGS -DCMAKE_BUILD_TYPE=Debug"
CMAKE_DEFAULT_FLAGS=" $CMAKE_DEFAULT_FLAGS -DCMAKE_PREFIX_PATH=`pwd`/lib/prefix -DCMAKE_INSTALL_PREFIX=`pwd`/lib/prefix -DBUILD_SHARED_LIBS=OFF"
mkdir -p lib/prefix/include lib/prefix/lib
if [[ "$@" != *"-lz"* ]]; then
  [ ! -e "lib/zlib" ] && echo "Make sure you've cloned submodules. (git submodule update --init --depth=1)" && exit -1
  [[ ! -e "lib/zlib/build" ]] && { cd lib/zlib && mkdir build && cd build && $CC $COMPILE_FLAGS -O3 -D_LARGEFILE64_SOURCE -I.. ../*.c -c && $AR rc libz.a *.o && cp libz.a ../../prefix/lib && cp ../*.h ../../prefix/include && cd ../../../ || exit -1; }
  LINK_FLAGS="$LINK_FLAGS -lz"
fi
if [[ "$@" != *"-lmbedtls"* && "$@" != *"-lmbedcrypto"* && "$@" != *"-lmbedx509"* ]]; then
  [ ! -e "lib/mbedtls/build" ] && { cd lib/mbedtls && mkdir build && cd build && CFLAGS="$COMPILE_FLAGS $CFLAGS_MBEDTLS -DMBEDTLS_MD4_C=1 -DMBEDTLS_DEBUG_C -w" cmake .. $CMAKE_DEFAULT_FLAGS  -G "Unix Makefiles" -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF $SSL_CONFIGURE && CFLAGS="$COMPILE_FLAGS $CFLAGS_MBEDTLS -DMBEDTLS_MD4_C=1 -w" $MAKE -j $JOBS && $MAKE install && cd ../../../ || exit -1; }
  LINK_FLAGS="$LINK_FLAGS -lmbedtls -lmbedx509 -lmbedcrypto"
fi
if [[ "$@" != *"-lgit2"* ]]; then
  [ ! -e "lib/libgit2/build" ] && { cd lib/libgit2 && mkdir build && cd build && cmake .. -G "Unix Makefiles" $GIT2_CONFIGURE $CMAKE_DEFAULT_FLAGS -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DREGEX_BACKEND=builtin -DUSE_SSH=OFF -DUSE_HTTPS=mbedTLS && $MAKE -j $JOBS && $MAKE install && cd ../../../ || exit -1; }
  LINK_FLAGS="-lgit2 $LINK_FLAGS"
fi
if [[ "$@" != *"-lzip"* ]]; then
  [ ! -e "lib/libzip/build" ] && { cd lib/libzip && mkdir build && cd build && CFLAGS="$COMPILE_FLAGS -Wno-incompatible-pointer-types" cmake .. -G "Unix Makefiles" $CMAKE_DEFAULT_FLAGS -DBUILD_TOOLS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOC=OFF -DENABLE_COMMONCRYPTO=OFF -DENABLE_GNUTLS=OFF -DENABLE_OPENSSL=OFF -DENABLE_BZIP2=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF && $MAKE -j $JOBS && $MAKE install && cd ../../../ || exit -1; }
  LINK_FLAGS="$LINK_FLAGS -lzip"
fi
[[ "$@" != *"-lmicrotar"* ]] && COMPILE_FLAGS="$COMPILE_FLAGS -Ilib/microtar/src" && SRCS="$SRCS lib/microtar/src/microtar.c"
[[ "$@" != *"-llua"* ]] && COMPILE_FLAGS="$COMPILE_FLAGS -Ilib/lua -DMAKE_LIB=1" && SRCS="$SRCS lib/lua/onelua.c"

# Build the pre-packaged lua file into the executbale.
if [[ "$@" == *"-DPPM_STATIC"* ]]; then
  [[ ! -e "lua.exe" ]] && { $HOSTCC -Ilib/lua -o lua.exe lib/lua/onelua.c -lm || exit -1; }
  ./lua.exe -e 'io.open("src/ppm.lua.c", "wb"):write("unsigned char ppm_luac[] = \""..string.dump(load(io.lines("src/ppm.lua","L"), "=ppm.lua")):gsub(".",function(c) return string.format("\\x%02X",string.byte(c)) end).."\";unsigned int ppm_luac_len = sizeof(ppm_luac)-1;")'
fi

[[ $OSTYPE != 'msys'* && $OSTYPE != 'cygwin' && $CC != *'mingw'* && $CC != "emcc" ]] && COMPILE_FLAGS="$COMPILE_FLAGS -DLUA_USE_LINUX" && LINK_FLAGS="$LINK_FLAGS -ldl"
[[ $OSTYPE == 'msys'* || $OSTYPE == 'cygwin' || $CC == *'mingw'* ]]                  && LINK_FLAGS="$LINK_FLAGS -lbcrypt -lws2_32 -lz -lwinhttp -lole32 -lcrypt32 -lrpcrt4 -lsecur32"
[[ $OSTYPE == *'darwin'* ]]                                   && LINK_FLAGS="$LINK_FLAGS -liconv -framework Security -framework Foundation"

[[ " $@" != *" -g"* && " $@" != *" -O"* ]] && COMPILE_FLAGS="$COMPILE_FLAGS -O3" && LINK_FLAGS="$LINK_FLAGS -s -flto"
$CC $COMPILE_FLAGS $SRCS $@ -o $BIN $LINK_FLAGS
