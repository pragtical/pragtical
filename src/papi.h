#ifndef PRAGTICAL_PAPI_H
#define PRAGTICAL_PAPI_H

#ifdef __cplusplus
#define PAPI_BEGIN_EXTERN extern "C" {
#define PAPI_END_EXTERN }
#else
#define PAPI_BEGIN_EXTERN
#define PAPI_END_EXTERN
#endif

#ifdef __GNUC__
#define UNUSED __attribute__((__unused__))
#else
#define UNUSED
#endif

#ifndef PAPI
# ifdef _WIN32
#  ifdef PRAGTICAL_LIB
#   define PAPI __declspec(dllexport)
#  else
#   define PAPI __declspec(dllimport)
#  endif
# else
#  if defined(__GNUC__) && __GNUC__ >= 4
#   define PAPI __attribute__ ((visibility("default")))
#  else
#   define PAPI
#  endif
# endif
#endif

#ifndef PAPICALL
#if defined(_WIN32) && !defined(__GNUC__)
#define PAPICALL __cdecl
#else
#define PAPICALL
#endif
#endif

#endif /* PRAGTICAL_PAPI_H */
