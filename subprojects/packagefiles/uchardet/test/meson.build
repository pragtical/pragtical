
uchardet_test = static_library(
    'uchardet_test',
    objects: uchardet.extract_all_objects(recursive: true),
)

uchardet_test_dep = declare_dependency(link_with : uchardet_test)

test_executable = executable(
    'uchardet-tests',
    'uchardet-tests.c',
    dependencies: uchardet_test_dep
)

test_langs = [
    'ar', 'bg', 'cs', 'da',
    'de', 'el', 'en', 'eo',
    'es', 'et', 'fi', 'fr',
    'ga', 'he', 'hr', 'hu',
    'it', 'ja', 'ko', 'lt',
    'lv', 'mt', 'pl', 'pt',
    'ro', 'ru', 'sk', 'sl',
    'sv', 'th', 'tr', 'vi',
    'zh',
]

test_charsets = [
    'ascii',
    'big5',
    'euc-jp', 'euc-tw',
    'gb18030',
    'ibm852', 'ibm855',
    'ibm866',
    'iso-2022-jp', 'iso-2022-kr',
    'iso-8859-1', 'iso-8859-2',
    'iso-8859-3', 'iso-8859-4',
    'iso-8859-5', 'iso-8859-6',
    'iso-8859-7', 'iso-8859-8',
    'iso-8859-9', 'iso-8859-10',
    'iso-8859-11', 'iso-8859-13',
    'iso-8859-15', 'iso-8859-16',
    'koi8-r',
    'mac-centraleurope',
    'mac-cyrillic',
    'shift_jis',
    'tis-620',
    'utf-16be', 'utf-16le',
    'utf-8',
    'viscii',
    'windows-1250', 'windows-1251',
    'windows-1252', 'windows-1253',
    'windows-1255', 'windows-1256',
    'windows-1257', 'windows-1258',
]

fs = import('fs')
foreach lang : test_langs
    foreach charset : test_charsets
        lang_charset = '@0@:@1@'.format(lang, charset)
        lang_charset_path = '@0@/@1@.txt'.format(lang, charset)
        if (fs.exists(lang_charset_path) and
            lang_charset != 'ja:utf-16le' and
            lang_charset != 'ja:utf-16be' and
            lang_charset != 'es:iso-8859-15' and
            lang_charset != 'da:iso-8859-1' and
            lang_charset != 'he:iso-8859-8')

            lang_charset_file = files(lang_charset_path)
            test(
                lang_charset.replace(':', '_'),
                test_executable,
                args : lang_charset_file
            )
        endif
    endforeach
endforeach
