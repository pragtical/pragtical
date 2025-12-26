project(
  'mbedtls',
  'c',
  version: '3.6.5',
  default_options: ['c_std=c99', 'warning_level=1'],
  meson_version: '>=0.56.0'
)

cc = meson.get_compiler('c')
inc = include_directories('include')

# -----------------------------
# Platform-specific dependencies
# -----------------------------
platform_deps = []
host = host_machine.system()

if host == 'windows'
  platform_deps += cc.find_library('bcrypt')
  platform_deps += cc.find_library('ws2_32')
else
  platform_deps += cc.find_library('m', required: false)
  platform_deps += dependency('threads', required: false)
endif

# -----------------------------
# Source files
# -----------------------------

# Crypto (mbedcrypto)
crypto_sources = files(
  'library/aes.c', 'library/aesce.c', 'library/aesni.c', 'library/aria.c', 'library/asn1parse.c',
  'library/asn1write.c', 'library/base64.c', 'library/bignum.c', 'library/bignum_core.c',
  'library/bignum_mod.c', 'library/bignum_mod_raw.c', 'library/block_cipher.c',
  'library/camellia.c', 'library/ccm.c', 'library/chacha20.c', 'library/chachapoly.c',
  'library/cipher.c', 'library/cipher_wrap.c', 'library/cmac.c', 'library/constant_time.c',
  'library/ctr_drbg.c', 'library/des.c', 'library/dhm.c', 'library/ecdh.c',
  'library/ecdsa.c', 'library/ecjpake.c', 'library/ecp.c', 'library/ecp_curves.c',
  'library/ecp_curves_new.c', 'library/entropy.c', 'library/entropy_poll.c',
  'library/error.c', 'library/gcm.c', 'library/hkdf.c', 'library/hmac_drbg.c',
  'library/lmots.c', 'library/lms.c', 'library/md.c', 'library/md5.c',
  'library/memory_buffer_alloc.c', 'library/nist_kw.c', 'library/oid.c',
  'library/pk.c', 'library/pk_ecc.c', 'library/pkcs12.c', 'library/pkcs5.c',
  'library/pkcs7.c', 'library/pkparse.c', 'library/pk_wrap.c', 'library/pkwrite.c',
  'library/platform.c', 'library/platform_util.c', 'library/poly1305.c',
  'library/psa_crypto.c', 'library/psa_crypto_aead.c', 'library/psa_crypto_cipher.c',
  'library/psa_crypto_client.c', 'library/psa_crypto_driver_wrappers_no_static.c',
  'library/psa_crypto_ecp.c', 'library/psa_crypto_ffdh.c', 'library/psa_crypto_hash.c',
  'library/psa_crypto_mac.c', 'library/psa_crypto_pake.c', 'library/psa_crypto_rsa.c',
  'library/psa_crypto_se.c', 'library/psa_crypto_slot_management.c',
  'library/psa_crypto_storage.c', 'library/psa_its_file.c', 'library/psa_util.c',
  'library/rsa.c', 'library/rsa_alt_helpers.c', 'library/sha1.c', 'library/sha256.c',
  'library/sha3.c', 'library/sha512.c', 'library/threading.c', 'library/timing.c',
  'library/version.c', 'library/version_features.c', 'library/pem.c', 'library/ripemd160.c'
)

# X509 (mbedx509)
x509_sources = files(
  'library/x509.c', 'library/x509_create.c', 'library/x509_crl.c',
  'library/x509_crt.c', 'library/x509_csr.c', 'library/x509write.c',
  'library/x509write_crt.c', 'library/x509write_csr.c'
)

# TLS (mbedtls)
tls_sources = files(
  'library/debug.c', 'library/mps_reader.c', 'library/mps_trace.c',
  'library/net_sockets.c', 'library/ssl_cache.c', 'library/ssl_ciphersuites.c',
  'library/ssl_client.c', 'library/ssl_cookie.c', 'library/ssl_debug_helpers_generated.c',
  'library/ssl_msg.c', 'library/ssl_ticket.c', 'library/ssl_tls.c',
  'library/ssl_tls12_client.c', 'library/ssl_tls12_server.c',
  'library/ssl_tls13_client.c', 'library/ssl_tls13_generic.c',
  'library/ssl_tls13_keys.c', 'library/ssl_tls13_server.c'
)

# -----------------------------
# Build libraries
# -----------------------------

libmbedcrypto = library('mbedcrypto', crypto_sources,
  include_directories: inc,
  dependencies: platform_deps,
  install: true
)

mbedcrypto_dep = declare_dependency(
  include_directories: inc,
  link_with: libmbedcrypto,
  dependencies: platform_deps
)

libmbedx509 = library('mbedx509', x509_sources,
  include_directories: inc,
  link_with: libmbedcrypto,
  install: true
)

mbedx509_dep = declare_dependency(
  include_directories: inc,
  link_with: libmbedx509,
  dependencies: mbedcrypto_dep
)

libmbedtls = library('mbedtls', tls_sources,
  include_directories: inc,
  link_with: [libmbedcrypto, libmbedx509],
  install: true
)

mbedtls_dep = declare_dependency(
  include_directories: inc,
  link_with: libmbedtls,
  dependencies: [mbedcrypto_dep, mbedx509_dep]
)
