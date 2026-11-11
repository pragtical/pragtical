#include "fallbackfont.h"
#include "grapheme.h"

#include <SDL3/SDL.h>
#include <limits.h>

#if defined(_WIN32)
#include <windows.h>
#include <dwrite_3.h>
#elif defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>
#endif

struct FallbackFontResolver {
  char *family;
  float size;
  bool bold, italic;
#if defined(__APPLE__)
  CTFontRef base;
#endif
};

#if defined(_WIN32)

static IDWriteFactory2 *factory;
static IDWriteFontFallback *system_fallback;
static bool initialized;

/* DirectWrite's SDK interfaces are C++; Meson compiles this file as C++ on
 * Windows only. The public interface retains C linkage on every platform. */
class FallbackTextSource : public IDWriteTextAnalysisSource {
public:
  const WCHAR *text;
  UINT32 length;
  WCHAR locale[LOCALE_NAME_MAX_LENGTH];

  FallbackTextSource(const WCHAR *value, UINT32 len) : text(value), length(len) {
    if (!GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH))
      locale[0] = 0;
  }
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override {
    if (iid == __uuidof(IUnknown) || iid == __uuidof(IDWriteTextAnalysisSource)) {
      *object = static_cast<IDWriteTextAnalysisSource *>(this);
      AddRef();
      return S_OK;
    }
    *object = NULL;
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return 1; }
  ULONG STDMETHODCALLTYPE Release() override { return 1; }
  HRESULT STDMETHODCALLTYPE GetTextAtPosition(UINT32 pos, const WCHAR **value, UINT32 *len) override {
    *value = pos < length ? text + pos : NULL;
    *len = pos < length ? length - pos : 0;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetTextBeforePosition(UINT32 pos, const WCHAR **value, UINT32 *len) override {
    *value = pos <= length && pos ? text : NULL;
    *len = pos <= length ? pos : 0;
    return S_OK;
  }
  DWRITE_READING_DIRECTION STDMETHODCALLTYPE GetParagraphReadingDirection() override {
    return DWRITE_READING_DIRECTION_LEFT_TO_RIGHT;
  }
  HRESULT STDMETHODCALLTYPE GetLocaleName(UINT32 pos, UINT32 *len, const WCHAR **name) override {
    *len = pos < length ? length - pos : 0;
    *name = locale;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetNumberSubstitution(UINT32 pos, UINT32 *len, IDWriteNumberSubstitution **substitution) override {
    *len = pos < length ? length - pos : 0;
    *substitution = NULL;
    return S_OK;
  }
};

static WCHAR *to_wide(const char *text, size_t len, UINT32 *length) {
  if (len > INT_MAX) return NULL;
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)len, NULL, 0);
  if (!n) return NULL;
  WCHAR *value = (WCHAR *)SDL_malloc((n + 1) * sizeof(WCHAR));
  if (!value) return NULL;
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)len, value, n);
  value[n] = 0;
  if (length) *length = n;
  return value;
}

static bool native_init(void) {
  if (!initialized) {
    initialized = true;
    if (SUCCEEDED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
        __uuidof(IDWriteFactory2), (IUnknown **)&factory)))
      factory->GetSystemFontFallback(&system_fallback);
  }
  return system_fallback != NULL;
}

static bool accept_dwrite_font(IDWriteFont *font, FLOAT scale,
                              FallbackFontAccept accept, void *userdata) {
  bool accepted = false;
  IDWriteFontFace *face = NULL;
  if (SUCCEEDED(font->CreateFontFace(&face))) {
    UINT32 file_count = 0;
    if (SUCCEEDED(face->GetFiles(&file_count, NULL)) && file_count == 1) {
      IDWriteFontFile *file = NULL;
      if (SUCCEEDED(face->GetFiles(&file_count, &file))) {
        IDWriteFontFileLoader *loader = NULL;
        IDWriteLocalFontFileLoader *local = NULL;
        const void *key = NULL;
        UINT32 key_size = 0, path_len = 0;
        if (SUCCEEDED(file->GetLoader(&loader))
            && SUCCEEDED(loader->QueryInterface(__uuidof(IDWriteLocalFontFileLoader), (void **)&local))
            && SUCCEEDED(file->GetReferenceKey(&key, &key_size))
            && SUCCEEDED(local->GetFilePathLengthFromKey(key, key_size, &path_len))) {
          WCHAR *path = (WCHAR *)SDL_malloc((path_len + 1) * sizeof(WCHAR));
          if (path && SUCCEEDED(local->GetFilePathFromKey(key, key_size, path, path_len + 1))) {
            char *utf8 = SDL_iconv_string("UTF-8", "UTF-16LE", (const char *)path, (path_len + 1) * sizeof(WCHAR));
            FallbackFontMatch match = {};
            match.path = utf8;
            match.face_index = face->GetIndex();
            match.scale = scale;
            IDWriteFontFace5 *variable = NULL;
            FallbackFontAxis *axes = NULL;
            if (SUCCEEDED(face->QueryInterface(__uuidof(IDWriteFontFace5), (void **)&variable))) {
              UINT32 count = variable->GetFontAxisValueCount();
              DWRITE_FONT_AXIS_VALUE *values = (DWRITE_FONT_AXIS_VALUE *)SDL_calloc(count, sizeof(*values));
              axes = (FallbackFontAxis *)SDL_calloc(count, sizeof(*axes));
              if (values && axes && SUCCEEDED(variable->GetFontAxisValues(values, count))) {
                match.axes = axes;
                match.axis_count = count;
                for (UINT32 i = 0; i < count; i++) {
                  /* DirectWrite axis tags use little-endian byte order. */
                  UINT32 tag = values[i].axisTag;
                  axes[i].tag = SDL_Swap32(tag);
                  axes[i].value = values[i].value;
                }
              }
              SDL_free(values);
              variable->Release();
            }
            if (utf8) accepted = accept(userdata, &match);
            SDL_free(axes);
            SDL_free(utf8);
          }
          SDL_free(path);
        }
        if (local) local->Release();
        if (loader) loader->Release();
        file->Release();
      }
    }
    face->Release();
  }
  return accepted;
}

static bool native_resolve(FallbackFontResolver *resolver, const char *text, size_t len,
                           FallbackFontAccept accept, void *userdata) {
  UINT32 length;
  WCHAR *wide = to_wide(text, len, &length);
  if (!wide) return false;
  WCHAR *family = to_wide(resolver->family, SDL_strlen(resolver->family), NULL);
  FallbackTextSource source(wide, length);
  bool accepted = false;
  UINT32 offset = 0;
  while (offset < length && !accepted) {
    IDWriteFont *font = NULL;
    UINT32 mapped = 0;
    FLOAT scale = 1;
    HRESULT result = system_fallback->MapCharacters(&source, offset, length - offset, NULL, family,
      resolver->bold ? DWRITE_FONT_WEIGHT_BOLD : DWRITE_FONT_WEIGHT_NORMAL,
      resolver->italic ? DWRITE_FONT_STYLE_ITALIC : DWRITE_FONT_STYLE_NORMAL,
      DWRITE_FONT_STRETCH_NORMAL, &mapped, &font, &scale);
    if (SUCCEEDED(result) && font)
      accepted = accept_dwrite_font(font, scale, accept, userdata);
    if (font) font->Release();
    if (FAILED(result) || !mapped) break;
    /* A base and its combining mark may map separately. Offer each native
     * candidate; the renderer accepts only a face covering the entire cluster.
     */
    offset += mapped;
  }
  SDL_free(family);
  SDL_free(wide);
  return accepted;
}

#elif defined(__APPLE__)

static char *string_utf8(CFStringRef string) {
  if (!string) return NULL;
  CFIndex size = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
  char *value = SDL_malloc(size);
  if (value && !CFStringGetCString(string, value, size, kCFStringEncodingUTF8)) {
    SDL_free(value);
    return NULL;
  }
  return value;
}

static bool native_resolve(FallbackFontResolver *resolver, const char *text, size_t len,
                           FallbackFontAccept accept, void *userdata) {
  CFStringRef string = CFStringCreateWithBytes(NULL, (const UInt8 *)text, len, kCFStringEncodingUTF8, false);
  if (!string) return false;
  CTFontRef font = CTFontCreateForString(resolver->base, string, CFRangeMake(0, CFStringGetLength(string)));
  CFRelease(string);
  if (!font) return false;
  CFURLRef url = CTFontCopyAttribute(font, kCTFontURLAttribute);
  CFStringRef path_string = url ? CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle) : NULL;
  /* CoreText can expose a UI alias or a named variable instance. The graphics
   * font identifies the physical collection face; variations are kept below.
   */
  CGFontRef graphics = CTFontCopyGraphicsFont(font, NULL);
  CFStringRef name = graphics ? CGFontCopyPostScriptName(graphics) : CTFontCopyPostScriptName(font);
  if (graphics) CGFontRelease(graphics);
  char *path = string_utf8(path_string), *postscript = string_utf8(name);
  CFDictionaryRef variation = CTFontCopyVariation(font);
  CFIndex count = variation ? CFDictionaryGetCount(variation) : 0;
  FallbackFontAxis *axes = count ? SDL_calloc(count, sizeof(*axes)) : NULL;
  const void **keys = count ? SDL_malloc(count * sizeof(*keys)) : NULL;
  const void **values = count ? SDL_malloc(count * sizeof(*values)) : NULL;
  if (axes && keys && values) {
    CFDictionaryGetKeysAndValues(variation, keys, values);
    for (CFIndex i = 0; i < count; i++) {
      int64_t tag;
      CFNumberGetValue(keys[i], kCFNumberSInt64Type, &tag);
      axes[i].tag = (uint32_t)tag;
      CFNumberGetValue(values[i], kCFNumberDoubleType, &axes[i].value);
    }
  } else {
    count = 0;
  }
  FallbackFontMatch match = {path, postscript, -1, 1, axes, (size_t)count};
  bool accepted = path && accept(userdata, &match);
  SDL_free(axes);
  SDL_free(keys);
  SDL_free(values);
  SDL_free(path);
  SDL_free(postscript);
  if (variation) CFRelease(variation);
  if (name) CFRelease(name);
  if (path_string) CFRelease(path_string);
  if (url) CFRelease(url);
  CFRelease(font);
  return accepted;
}

#else

/* The small public Fontconfig ABI used here is stable across Fontconfig 2.x.
 * Resolve it dynamically so portable builds need neither headers nor a bundled
 * font database/library. Keep native details out of fallbackfont.h.
 */
typedef struct _FcConfig FcConfig;
typedef struct _FcPattern FcPattern;
typedef struct _FcCharSet FcCharSet;
typedef struct { int nfont, sfont; FcPattern **fonts; } FcFontSet;
typedef struct {
  SDL_SharedObject *library;
  FcConfig *config;
  bool initialized, config_failed;
  FcConfig *(*InitLoadConfigAndFonts)(void);
  void (*ConfigDestroy)(FcConfig *);
  FcPattern *(*PatternCreate)(void);
  void (*PatternDestroy)(FcPattern *);
  int (*PatternAddString)(FcPattern *, const char *, const unsigned char *);
  int (*PatternAddInteger)(FcPattern *, const char *, int);
  int (*PatternAddDouble)(FcPattern *, const char *, double);
  int (*PatternAddBool)(FcPattern *, const char *, int);
  int (*PatternAddCharSet)(FcPattern *, const char *, const FcCharSet *);
  int (*PatternGetString)(const FcPattern *, const char *, int, unsigned char **);
  int (*PatternGetInteger)(const FcPattern *, const char *, int, int *);
  int (*PatternGetCharSet)(const FcPattern *, const char *, int, FcCharSet **);
  FcCharSet *(*CharSetCreate)(void);
  void (*CharSetDestroy)(FcCharSet *);
  int (*CharSetAddChar)(FcCharSet *, unsigned int);
  int (*CharSetIsSubset)(const FcCharSet *, const FcCharSet *);
  int (*ConfigSubstitute)(FcConfig *, FcPattern *, int);
  void (*DefaultSubstitute)(FcPattern *);
  void (*ConfigSetDefaultSubstitute)(FcConfig *, FcPattern *);
  FcFontSet *(*FontSort)(FcConfig *, FcPattern *, int, FcCharSet **, int *);
  FcPattern *(*FontRenderPrepare)(FcConfig *, FcPattern *, FcPattern *);
  void (*FontSetDestroy)(FcFontSet *);
} Fontconfig;
static Fontconfig fc;

static bool native_init(void) {
  if (fc.initialized) return fc.library != NULL;
  fc.initialized = true;
  fc.library = SDL_LoadObject("libfontconfig.so.1");
  if (!fc.library) fc.library = SDL_LoadObject("libfontconfig.so");
  if (!fc.library) return false;
#define FC_LOAD(name) do { \
  SDL_FunctionPointer symbol = SDL_LoadFunction(fc.library, "Fc" #name); \
  SDL_memcpy(&fc.name, &symbol, sizeof(fc.name)); \
  if (!fc.name) goto failure; \
} while (0)
  FC_LOAD(InitLoadConfigAndFonts);
  FC_LOAD(ConfigDestroy);
  FC_LOAD(PatternCreate);
  FC_LOAD(PatternDestroy);
  FC_LOAD(PatternAddString);
  FC_LOAD(PatternAddInteger);
  FC_LOAD(PatternAddDouble);
  FC_LOAD(PatternAddBool);
  FC_LOAD(PatternAddCharSet);
  FC_LOAD(PatternGetString);
  FC_LOAD(PatternGetInteger);
  FC_LOAD(PatternGetCharSet);
  FC_LOAD(CharSetCreate);
  FC_LOAD(CharSetDestroy);
  FC_LOAD(CharSetAddChar);
  FC_LOAD(CharSetIsSubset);
  FC_LOAD(ConfigSubstitute);
  FC_LOAD(DefaultSubstitute);
  FC_LOAD(FontSort);
  FC_LOAD(FontRenderPrepare);
  FC_LOAD(FontSetDestroy);
#undef FC_LOAD
  /* Recent Fontconfig can use our private config for defaults too. Its legacy
   * entry point otherwise creates a second, process-global font catalogue.
   */
  SDL_FunctionPointer defaults = SDL_LoadFunction(fc.library, "FcConfigSetDefaultSubstitute");
  SDL_memcpy(&fc.ConfigSetDefaultSubstitute, &defaults, sizeof(fc.ConfigSetDefaultSubstitute));
  return true;
failure:
  SDL_UnloadObject(fc.library);
  fc.library = NULL;
  return false;
}

static bool native_resolve(FallbackFontResolver *resolver, const char *text, size_t len,
                           FallbackFontAccept accept, void *userdata) {
  if (!fc.config && !fc.config_failed) {
    fc.config = fc.InitLoadConfigAndFonts();
    fc.config_failed = fc.config == NULL;
  }
  if (!fc.config) return false;
  FcPattern *pattern = fc.PatternCreate();
  FcCharSet *charset = fc.CharSetCreate();
  if (!pattern || !charset) {
    if (pattern) fc.PatternDestroy(pattern);
    if (charset) fc.CharSetDestroy(charset);
    return false;
  }
  const char *p = text;
  size_t remaining = len;
  bool emoji = false, text_presentation = false;
  while (remaining) {
    Uint32 cp = SDL_StepUTF8(&p, &remaining);
    /* Selectors, joiners and emoji tags need shaping, not nominal glyphs. */
    if (cp == 0xFE0F || cp == 0x20E3 || (cp >= 0x1F000 && cp <= 0x1FAFF)) emoji = true;
    if (cp == 0xFE0E) text_presentation = true;
    if (!Lutf8_isdefaultignorable(cp))
      fc.CharSetAddChar(charset, cp);
  }
  emoji = emoji && !text_presentation;
  fc.PatternAddString(pattern, "family", (const unsigned char *)(emoji ? "emoji" : resolver->family));
  fc.PatternAddInteger(pattern, "weight", resolver->bold ? 200 : 80);
  fc.PatternAddInteger(pattern, "slant", resolver->italic ? 100 : 0);
  fc.PatternAddDouble(pattern, "pixelsize", resolver->size);
  fc.PatternAddCharSet(pattern, "charset", charset);
  if (emoji) fc.PatternAddBool(pattern, "color", 1);
  if (text_presentation) fc.PatternAddBool(pattern, "color", 0);
  fc.ConfigSubstitute(fc.config, pattern, 0 /* FcMatchPattern */);
  if (fc.ConfigSetDefaultSubstitute) fc.ConfigSetDefaultSubstitute(fc.config, pattern);
  else fc.DefaultSubstitute(pattern);
  int result;
  FcFontSet *fonts = fc.FontSort(fc.config, pattern, 0, NULL, &result);
  bool accepted = false;
  if (fonts) {
    for (int i = 0; i < fonts->nfont && !accepted; i++) {
      unsigned char *path = NULL, *variations = NULL;
      int index = 0;
      FcCharSet *coverage = NULL;
      if (fc.PatternGetCharSet(fonts->fonts[i], "charset", 0, &coverage) != 0
          || !fc.CharSetIsSubset(charset, coverage)) continue;
      FcPattern *prepared = fc.FontRenderPrepare(fc.config, pattern, fonts->fonts[i]);
      if (!prepared) continue;
      if (fc.PatternGetString(prepared, "file", 0, &path) != 0) {
        fc.PatternDestroy(prepared);
        continue;
      }
      fc.PatternGetInteger(prepared, "index", 0, &index);
      fc.PatternGetString(prepared, "fontvariations", 0, &variations);
      size_t capacity = variations && *variations ? 1 : 0;
      if (variations) {
        for (const unsigned char *v = variations; *v; v++) if (*v == ',') capacity++;
      }
      FallbackFontAxis *axes = capacity ? SDL_calloc(capacity, sizeof(*axes)) : NULL;
      if (capacity && !axes) { fc.PatternDestroy(prepared); continue; }
      size_t count = 0;
      /* Fontconfig's standard variation format is tag=value,tag=value. */
      const char *v = (const char *)variations;
      while (v && SDL_strlen(v) >= 5 && count < capacity) {
        const char *equal = SDL_strchr(v, '=');
        if (!equal || equal - v != 4) break;
        axes[count].tag = (Uint32)(Uint8)v[0] << 24 | (Uint32)(Uint8)v[1] << 16
          | (Uint32)(Uint8)v[2] << 8 | (Uint8)v[3];
        char *tail;
        axes[count].value = SDL_strtod(equal + 1, &tail);
        if (tail == equal + 1) break;
        count++;
        v = *tail == ',' ? tail + 1 : NULL;
      }
      FallbackFontMatch match = {(const char *)path, NULL, index, 1, axes, count};
      accepted = accept(userdata, &match);
      SDL_free(axes);
      fc.PatternDestroy(prepared);
    }
    fc.FontSetDestroy(fonts);
  }
  fc.CharSetDestroy(charset);
  fc.PatternDestroy(pattern);
  return accepted;
}
#endif

FallbackFontResolver *fallback_font_create(const char *path, const char *family,
  const char *postscript_name, float size, bool bold, bool italic) {
#if !defined(__APPLE__)
  (void)path;
  (void)postscript_name;
  if (!native_init()) return NULL;
#endif
  FallbackFontResolver *resolver = (FallbackFontResolver *)SDL_calloc(1, sizeof(*resolver));
  if (!resolver) return NULL;
  resolver->family = SDL_strdup(family ? family : "sans-serif");
  resolver->size = size;
  resolver->bold = bold;
  resolver->italic = italic;
  if (!resolver->family) { SDL_free(resolver); return NULL; }
#if defined(__APPLE__)
  CFStringRef name = CFStringCreateWithCString(NULL, postscript_name ? postscript_name : resolver->family, kCFStringEncodingUTF8);
  CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, SDL_strlen(path), false);
  CFArrayRef descriptors = url ? CTFontManagerCreateFontDescriptorsFromURL(url) : NULL;
  if (descriptors) {
    for (CFIndex i = 0; i < CFArrayGetCount(descriptors); i++) {
      CTFontDescriptorRef descriptor = CFArrayGetValueAtIndex(descriptors, i);
      CFStringRef candidate = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
      bool matches = candidate && name && CFEqual(candidate, name);
      if (candidate) CFRelease(candidate);
      if (matches) {
        resolver->base = CTFontCreateWithFontDescriptor(descriptor, size, NULL);
        break;
      }
    }
    CFRelease(descriptors);
  }
  if (!resolver->base && name) resolver->base = CTFontCreateWithName(name, size, NULL);
  if (resolver->base && (bold || italic)) {
    CTFontSymbolicTraits traits = (bold ? kCTFontBoldTrait : 0) | (italic ? kCTFontItalicTrait : 0);
    CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(resolver->base, size, NULL,
      traits, kCTFontBoldTrait | kCTFontItalicTrait);
    if (styled) { CFRelease(resolver->base); resolver->base = styled; }
  }
  if (url) CFRelease(url);
  if (name) CFRelease(name);
  if (!resolver->base) { fallback_font_free(resolver); return NULL; }
#endif
  return resolver;
}

bool fallback_font_resolve(FallbackFontResolver *resolver, const char *text,
  size_t len, FallbackFontAccept accept, void *userdata) {
  return resolver && len && native_resolve(resolver, text, len, accept, userdata);
}

void fallback_font_free(FallbackFontResolver *resolver) {
  if (!resolver) return;
#if defined(__APPLE__)
  if (resolver->base) CFRelease(resolver->base);
#endif
  SDL_free(resolver->family);
  SDL_free(resolver);
}

void fallback_font_trim(void) {
#if !defined(_WIN32) && !defined(__APPLE__)
  /* A user's catalogue can contain thousands of fonts. Keep it for a frame's
   * discoveries, then release it instead of charging that memory to the editor
   * for the remainder of the session. Renderer faces and choices are separate.
   */
  if (fc.config) fc.ConfigDestroy(fc.config);
  fc.config = NULL;
#endif
}

void fallback_font_shutdown(void) {
#if defined(_WIN32)
  if (system_fallback) system_fallback->Release();
  if (factory) factory->Release();
  system_fallback = NULL;
  factory = NULL;
  initialized = false;
#elif !defined(__APPLE__)
  if (fc.config) fc.ConfigDestroy(fc.config);
  if (fc.library) SDL_UnloadObject(fc.library);
  SDL_zero(fc);
#endif
}
