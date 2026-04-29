project(
  'mbedtls',
  'c',
  version: '4.1.0',
  default_options: ['c_std=c99', 'warning_level=1'],
  meson_version: '>=0.56.0'
)

cc = meson.get_compiler('c')

public_inc = include_directories(
  'include',
  'tf-psa-crypto/include',
  'tf-psa-crypto/drivers/builtin/include'
)

private_inc = include_directories(
  'library',
  'tf-psa-crypto/core',
  'tf-psa-crypto/dispatch',
  'tf-psa-crypto/drivers/builtin/src',
  'tf-psa-crypto/extras',
  'tf-psa-crypto/platform',
  'tf-psa-crypto/utilities'
)

mbedtls_inc = [public_inc, private_inc]

platform_deps = []
host = host_machine.system()

if host == 'windows'
  platform_deps += cc.find_library('bcrypt')
  platform_deps += cc.find_library('ws2_32')
elif host == 'haiku'
  platform_deps += cc.find_library('network')
  platform_deps += cc.find_library('m', required: false)
  platform_deps += dependency('threads', required: false)
else
  platform_deps += cc.find_library('m', required: false)
  platform_deps += dependency('threads', required: false)
endif

tfpsacrypto_sources = files(
  'tf-psa-crypto/core/psa_crypto.c',
  'tf-psa-crypto/core/psa_crypto_client.c',
  'tf-psa-crypto/core/psa_crypto_driver_wrappers_no_static.c',
  'tf-psa-crypto/core/psa_crypto_random.c',
  'tf-psa-crypto/core/psa_crypto_slot_management.c',
  'tf-psa-crypto/core/psa_crypto_storage.c',
  'tf-psa-crypto/core/psa_its_file.c',
  'tf-psa-crypto/core/psa_util.c',
  'tf-psa-crypto/core/tf_psa_crypto_config.c',
  'tf-psa-crypto/core/tf_psa_crypto_version.c',
  'tf-psa-crypto/drivers/builtin/src/aes.c',
  'tf-psa-crypto/drivers/builtin/src/aesce.c',
  'tf-psa-crypto/drivers/builtin/src/aesni.c',
  'tf-psa-crypto/drivers/builtin/src/aria.c',
  'tf-psa-crypto/drivers/builtin/src/bignum.c',
  'tf-psa-crypto/drivers/builtin/src/bignum_core.c',
  'tf-psa-crypto/drivers/builtin/src/bignum_mod.c',
  'tf-psa-crypto/drivers/builtin/src/bignum_mod_raw.c',
  'tf-psa-crypto/drivers/builtin/src/block_cipher.c',
  'tf-psa-crypto/drivers/builtin/src/camellia.c',
  'tf-psa-crypto/drivers/builtin/src/ccm.c',
  'tf-psa-crypto/drivers/builtin/src/chacha20.c',
  'tf-psa-crypto/drivers/builtin/src/chacha20_neon.c',
  'tf-psa-crypto/drivers/builtin/src/chachapoly.c',
  'tf-psa-crypto/drivers/builtin/src/cipher.c',
  'tf-psa-crypto/drivers/builtin/src/cipher_wrap.c',
  'tf-psa-crypto/drivers/builtin/src/cmac.c',
  'tf-psa-crypto/drivers/builtin/src/ctr_drbg.c',
  'tf-psa-crypto/drivers/builtin/src/ecdsa.c',
  'tf-psa-crypto/drivers/builtin/src/ecjpake.c',
  'tf-psa-crypto/drivers/builtin/src/ecp.c',
  'tf-psa-crypto/drivers/builtin/src/ecp_curves.c',
  'tf-psa-crypto/drivers/builtin/src/ecp_curves_new.c',
  'tf-psa-crypto/drivers/builtin/src/entropy.c',
  'tf-psa-crypto/drivers/builtin/src/entropy_poll.c',
  'tf-psa-crypto/drivers/builtin/src/gcm.c',
  'tf-psa-crypto/drivers/builtin/src/hmac_drbg.c',
  'tf-psa-crypto/drivers/builtin/src/md5.c',
  'tf-psa-crypto/drivers/builtin/src/poly1305.c',
  'tf-psa-crypto/drivers/builtin/src/psa_crypto_aead.c',
  'tf-psa-crypto/drivers/builtin/src/psa_crypto_cipher.c',
  'tf-psa-crypto/drivers/builtin/src/psa_crypto_ecp.c',
  'tf-psa-crypto/drivers/builtin/src/psa_crypto_ffdh.c',
  'tf-psa-crypto/drivers/builtin/src/psa_crypto_hash.c',
  'tf-psa-crypto/drivers/builtin/src/psa_crypto_mac.c',
  'tf-psa-crypto/drivers/builtin/src/psa_crypto_pake.c',
  'tf-psa-crypto/drivers/builtin/src/psa_crypto_rsa.c',
  'tf-psa-crypto/drivers/builtin/src/psa_crypto_xof.c',
  'tf-psa-crypto/drivers/builtin/src/psa_util_internal.c',
  'tf-psa-crypto/drivers/builtin/src/ripemd160.c',
  'tf-psa-crypto/drivers/builtin/src/rsa.c',
  'tf-psa-crypto/drivers/builtin/src/rsa_alt_helpers.c',
  'tf-psa-crypto/drivers/builtin/src/sha1.c',
  'tf-psa-crypto/drivers/builtin/src/sha256.c',
  'tf-psa-crypto/drivers/builtin/src/sha3.c',
  'tf-psa-crypto/drivers/builtin/src/sha512.c',
  'tf-psa-crypto/extras/lmots.c',
  'tf-psa-crypto/extras/lms.c',
  'tf-psa-crypto/extras/md.c',
  'tf-psa-crypto/extras/nist_kw.c',
  'tf-psa-crypto/extras/pk.c',
  'tf-psa-crypto/extras/pk_ecc.c',
  'tf-psa-crypto/extras/pkparse.c',
  'tf-psa-crypto/extras/pk_rsa.c',
  'tf-psa-crypto/extras/pk_wrap.c',
  'tf-psa-crypto/extras/pkwrite.c',
  'tf-psa-crypto/platform/memory_buffer_alloc.c',
  'tf-psa-crypto/platform/platform.c',
  'tf-psa-crypto/platform/platform_util.c',
  'tf-psa-crypto/platform/threading.c',
  'tf-psa-crypto/utilities/asn1parse.c',
  'tf-psa-crypto/utilities/asn1write.c',
  'tf-psa-crypto/utilities/base64.c',
  'tf-psa-crypto/utilities/constant_time.c',
  'tf-psa-crypto/utilities/oid.c',
  'tf-psa-crypto/utilities/pem.c',
  'tf-psa-crypto/utilities/pkcs5.c'
)

x509_sources = files(
  'library/error.c',
  'library/mbedtls_config.c',
  'library/pkcs7.c',
  'library/x509.c',
  'library/x509_create.c',
  'library/x509_crl.c',
  'library/x509_crt.c',
  'library/x509_csr.c',
  'library/x509_oid.c',
  'library/x509write.c',
  'library/x509write_crt.c',
  'library/x509write_csr.c'
)

tls_sources = files(
  'library/debug.c',
  'library/mps_reader.c',
  'library/mps_trace.c',
  'library/net_sockets.c',
  'library/ssl_cache.c',
  'library/ssl_ciphersuites.c',
  'library/ssl_client.c',
  'library/ssl_cookie.c',
  'library/ssl_debug_helpers_generated.c',
  'library/ssl_msg.c',
  'library/ssl_ticket.c',
  'library/ssl_tls.c',
  'library/ssl_tls12_client.c',
  'library/ssl_tls12_server.c',
  'library/ssl_tls13_client.c',
  'library/ssl_tls13_generic.c',
  'library/ssl_tls13_keys.c',
  'library/ssl_tls13_server.c',
  'library/timing.c',
  'library/version.c',
  'library/version_features.c'
)

libtfpsacrypto = static_library('tfpsacrypto',
  tfpsacrypto_sources,
  include_directories: mbedtls_inc,
  dependencies: platform_deps,
  install: false
)

tfpsacrypto_dep = declare_dependency(
  include_directories: public_inc,
  link_with: libtfpsacrypto,
  dependencies: platform_deps
)

libmbedx509 = static_library('mbedx509',
  x509_sources,
  include_directories: mbedtls_inc,
  dependencies: platform_deps,
  link_with: libtfpsacrypto,
  install: false
)

mbedx509_dep = declare_dependency(
  include_directories: public_inc,
  link_with: libmbedx509,
  dependencies: platform_deps + [tfpsacrypto_dep]
)

libmbedtls = static_library('mbedtls',
  tls_sources,
  include_directories: mbedtls_inc,
  dependencies: platform_deps,
  link_with: [libtfpsacrypto, libmbedx509],
  install: false
)

mbedtls_dep = declare_dependency(
  include_directories: public_inc,
  link_with: libmbedtls,
  dependencies: platform_deps + [tfpsacrypto_dep, mbedx509_dep]
)
