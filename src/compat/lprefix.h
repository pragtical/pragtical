/*
** $Id: lprefix.h,v 1.2 2014/12/29 16:54:13 roberto Exp $
** Definitions for Lua code that must come before any other header file
** See Copyright Notice in lua.h
*/

#ifndef lprefix_h
#define lprefix_h


/*
** Allows POSIX/XSI stuff
*/
#if !defined(LUA_USE_C89)	/* { */

#if !defined(_XOPEN_SOURCE)
#define _XOPEN_SOURCE           600
#elif _XOPEN_SOURCE == 0
#undef _XOPEN_SOURCE  /* use -D_XOPEN_SOURCE=0 to undefine it */
#endif

/*
** Allows manipulation of large files in gcc and some other compilers
*/
#if !defined(LUA_32BITS) && !defined(_FILE_OFFSET_BITS)
#define _LARGEFILE_SOURCE       1
#define _FILE_OFFSET_BITS       64
#endif

#endif				/* } */


/*
** Windows stuff
*/
#if defined(_WIN32) 	/* { */

#if !defined(_CRT_SECURE_NO_WARNINGS)
#define _CRT_SECURE_NO_WARNINGS  /* avoid warnings about ISO C functions */
#endif

#endif			/* } */


/* COMPAT53 adaptation */
#include "compat-5.3.h"

#undef LUAMOD_API
#define LUAMOD_API extern


#ifdef lutf8lib_c
#  define luaopen_utf8 luaopen_compat53_utf8
/* we don't support the %U format string of lua_pushfstring!
 * code below adapted from the Lua 5.3 sources:
 */
static const char *compat53_utf8_escape (lua_State* L, long x) {
  if (x < 0x80) { /* ASCII */
    char c = (char)x;
    lua_pushlstring(L, &c, 1);
  } else {
    char buff[8] = { 0 };
    unsigned int mfb = 0x3f;
    int n = 1;
    do {
      buff[8 - (n++)] = (char)(0x80|(x & 0x3f));
      x >>= 6;
      mfb >>= 1;
    } while (x > mfb);
    buff[8-n] = (char)((~mfb << 1) | x);
    lua_pushlstring(L, buff+8-n, n);
  }
  return lua_tostring(L, -1);
}
#  define lua_pushfstring(L, fmt, l) \
  compat53_utf8_escape(L, l)
#endif


#ifdef ltablib_c
#  define luaopen_table luaopen_compat53_table
#  ifndef LUA_MAXINTEGER
/* conservative estimate: */
#    define LUA_MAXINTEGER INT_MAX
#  endif
#endif /* ltablib_c */


#ifdef lstrlib_c
#include <locale.h>
#include <lualib.h>
/* move the string library open function out of the way (we only take
 * the string packing functions)!
 */
#  define luaopen_string luaopen_string_XXX
/* used in string.format implementation, which we don't use: */
#  ifndef LUA_INTEGER_FRMLEN
#    define LUA_INTEGER_FRMLEN ""
#    define LUA_NUMBER_FRMLEN ""
#  endif
#  ifndef LUA_MININTEGER
#    define LUA_MININTEGER 0
#  endif
#  ifndef LUA_INTEGER_FMT
#    define LUA_INTEGER_FMT "%d"
#  endif
#  ifndef LUAI_UACINT
#    define LUAI_UACINT lua_Integer
#  endif
/* different Lua 5.3 versions have conflicting variants of this macro
 * in luaconf.h, there's a fallback implementation in lstrlib.c, and
 * the macro isn't used for string (un)packing anyway!
 * */
#  undef lua_number2strx
#  if LUA_VERSION_NUM < 503
/* lstrlib assumes that lua_Integer and lua_Unsigned have the same
 * size, so we use the unsigned equivalent of ptrdiff_t! */
#    define lua_Unsigned size_t
#  endif
#  ifndef l_mathlim
#    ifdef LUA_NUMBER_DOUBLE
#      define l_mathlim(n) (DBL_##n)
#    else
#      define l_mathlim(n) (FLT_##n)
#    endif
#  endif
#  ifndef l_mathop
#    ifdef LUA_NUMBER_DOUBLE
#      define l_mathop(op) op
#    else
#      define l_mathop(op) op##f
#    endif
#  endif
#  ifndef lua_getlocaledecpoint
#    define lua_getlocaledecpoint() (localeconv()->decimal_point[0])
#  endif
#  ifndef l_sprintf
#    if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
#      define l_sprintf(s,sz,f,i) (snprintf(s, sz, f, i))
#    else
#      define l_sprintf(s,sz,f,i) ((void)(sz), sprintf(s, f, i))
#    endif
#  endif

static int str_pack (lua_State *L);
static int str_packsize (lua_State *L);
static int str_unpack (lua_State *L);
LUAMOD_API int luaopen_compat53_string (lua_State *L) {
  luaL_Reg const funcs[] = {
    { "pack", str_pack },
    { "packsize", str_packsize },
    { "unpack", str_unpack },
    { NULL, NULL }
  };
  luaL_newlib(L, funcs);
  return 1;
}
/* fake CLANG feature detection on other compilers */
#  ifndef __has_attribute
#    define __has_attribute(x) 0
#  endif
/* make luaopen_string(_XXX) static, so it (and all other referenced
 * string functions) won't be included in the resulting dll
 * (hopefully).
 */
#  undef LUAMOD_API
#  if defined(__GNUC__) || __has_attribute(__unused__)
#    define LUAMOD_API __attribute__((__unused__)) static
#  else
#    define LUAMOD_API static
#  endif
#endif /* lstrlib.c */

#endif


#ifdef liolib_c
/* move the io library open function out of the way (we only take
 * the popen and type functions)!
 */
#  define luaopen_io luaopen_io_XXX

#include <locale.h>
#include <lualib.h>

#  if !defined(lua_getlocaledecpoint)
#    define lua_getlocaledecpoint() (localeconv()->decimal_point[0])
#  endif

#  ifndef LUA_INTEGER_FMT
#    define LUA_INTEGER_FMT "%ld"
#  endif
#  ifndef LUAI_UACINT
#    define LUAI_UACINT lua_Integer
#  endif

/* choose which popen implementation to pick */
#  if (defined(_WIN32) && !defined(__CYGWIN__))
#    define LUA_USE_WINDOWS 1
#  endif
#  if (!defined(LUA_USE_WINDOWS) && !defined(LUA_USE_POSIX)) && \
      ((defined(_POSIX_C_SOURCE) && _POSIX_C_SOURCE >= 200112L) || \
       (defined(_XOPEN_SOURCE) && _XOPEN_SOURCE >= 600) || \
       defined(__APPLE__))
#    define LUA_USE_POSIX 1
#  endif

typedef struct COMPAT53_luaL_Stream {
  FILE *f;  /* stream (NULL for incompletely created streams) */
  lua_CFunction closef;  /* to close stream (NULL for closed streams) */
} COMPAT53_luaL_Stream;

#define luaL_Stream COMPAT53_luaL_Stream

#define COMPAT53_LUA_PFILEHANDLE "PFILE*"

#if defined(LUA_VERSION_NUM) && LUA_VERSION_NUM == 501 && !defined(LUA_JITLIBNAME)

static int io_ptype (lua_State *L) {
  luaL_Stream *p;
  luaL_checkany(L, 1);
  p = (luaL_Stream *)luaL_testudata(L, 1, COMPAT53_LUA_PFILEHANDLE);
  if (p) {
    /* Lua 5.3 implementation, for popen files */
    if (p->closef == NULL)
      lua_pushliteral(L, "closed file");
    else
      lua_pushliteral(L, "file");
    return 1;
  } else {
    /* Lua 5.1 implementation, for plain files */
    void *ud = lua_touserdata(L, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, LUA_FILEHANDLE);
    if (ud == NULL || !lua_getmetatable(L, 1) || !lua_rawequal(L, -2, -1))
      lua_pushnil(L);  /* not a file */
    else if (*((FILE **)ud) == NULL)
      lua_pushliteral(L, "closed file");
    else
      lua_pushliteral(L, "file");
    return 1;
  }
}

#endif

static int io_popen (lua_State *L);
static void createmeta (lua_State *L);

#  undef LUA_FILEHANDLE
#  define LUA_FILEHANDLE COMPAT53_LUA_PFILEHANDLE

LUAMOD_API int luaopen_compat53_io (lua_State *L) {
  luaL_Reg const funcs[] = {

/* for PUC-Rio Lua 5.1 only */
#  if defined(LUA_VERSION_NUM) && LUA_VERSION_NUM == 501 && !defined(LUA_JITLIBNAME)

    { "popen", io_popen },
    { "type", io_ptype },

#  endif /* for PUC-Rio Lua 5.1 only */

    { NULL, NULL }
  };
  luaL_newlib(L, funcs);
  createmeta(L);
  return 1;
}


/* fake CLANG feature detection on other compilers */
#  ifndef __has_attribute
#    define __has_attribute(x) 0
#  endif
/* make luaopen_io(_XXX) static, so it (and all other referenced
 * io functions) won't be included in the resulting dll
 * (hopefully).
 */
#  undef LUAMOD_API
#  if defined(__GNUC__) || __has_attribute(__unused__)
#    define LUAMOD_API __attribute__((__unused__)) static
#  else
#    define LUAMOD_API static
#  endif

#endif /* iolib.c */
