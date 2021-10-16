const std = @import("std");

fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

fn pathJoinRoot(comptime components: []const []const u8) []const u8 {
    var ret = root();
    inline for (components) |component|
        ret = ret ++ std.fs.path.sep_str ++ component;

    return ret;
}

const srcs = blk: {
    @setEvalBranchQuota(4000);
    var ret = &.{
        pathJoinRoot(&.{ "c", "library", "aes.c" }),
        pathJoinRoot(&.{ "c", "library", "aesni.c" }),
        pathJoinRoot(&.{ "c", "library", "arc4.c" }),
        pathJoinRoot(&.{ "c", "library", "aria.c" }),
        pathJoinRoot(&.{ "c", "library", "asn1parse.c" }),
        pathJoinRoot(&.{ "c", "library", "asn1write.c" }),
        pathJoinRoot(&.{ "c", "library", "base64.c" }),
        pathJoinRoot(&.{ "c", "library", "bignum.c" }),
        pathJoinRoot(&.{ "c", "library", "blowfish.c" }),
        pathJoinRoot(&.{ "c", "library", "camellia.c" }),
        pathJoinRoot(&.{ "c", "library", "ccm.c" }),
        pathJoinRoot(&.{ "c", "library", "certs.c" }),
        pathJoinRoot(&.{ "c", "library", "chacha20.c" }),
        pathJoinRoot(&.{ "c", "library", "chachapoly.c" }),
        pathJoinRoot(&.{ "c", "library", "cipher.c" }),
        pathJoinRoot(&.{ "c", "library", "cipher_wrap.c" }),
        pathJoinRoot(&.{ "c", "library", "cmac.c" }),
        pathJoinRoot(&.{ "c", "library", "ctr_drbg.c" }),
        pathJoinRoot(&.{ "c", "library", "debug.c" }),
        pathJoinRoot(&.{ "c", "library", "des.c" }),
        pathJoinRoot(&.{ "c", "library", "dhm.c" }),
        pathJoinRoot(&.{ "c", "library", "ecdh.c" }),
        pathJoinRoot(&.{ "c", "library", "ecdsa.c" }),
        pathJoinRoot(&.{ "c", "library", "ecjpake.c" }),
        pathJoinRoot(&.{ "c", "library", "ecp.c" }),
        pathJoinRoot(&.{ "c", "library", "ecp_curves.c" }),
        pathJoinRoot(&.{ "c", "library", "entropy.c" }),
        pathJoinRoot(&.{ "c", "library", "entropy_poll.c" }),
        pathJoinRoot(&.{ "c", "library", "error.c" }),
        pathJoinRoot(&.{ "c", "library", "gcm.c" }),
        pathJoinRoot(&.{ "c", "library", "havege.c" }),
        pathJoinRoot(&.{ "c", "library", "hkdf.c" }),
        pathJoinRoot(&.{ "c", "library", "hmac_drbg.c" }),
        pathJoinRoot(&.{ "c", "library", "md2.c" }),
        pathJoinRoot(&.{ "c", "library", "md4.c" }),
        pathJoinRoot(&.{ "c", "library", "md5.c" }),
        pathJoinRoot(&.{ "c", "library", "md.c" }),
        pathJoinRoot(&.{ "c", "library", "memory_buffer_alloc.c" }),
        pathJoinRoot(&.{ "c", "library", "mps_reader.c" }),
        pathJoinRoot(&.{ "c", "library", "mps_trace.c" }),
        pathJoinRoot(&.{ "c", "library", "net_sockets.c" }),
        pathJoinRoot(&.{ "c", "library", "nist_kw.c" }),
        pathJoinRoot(&.{ "c", "library", "oid.c" }),
        pathJoinRoot(&.{ "c", "library", "padlock.c" }),
        pathJoinRoot(&.{ "c", "library", "pem.c" }),
        pathJoinRoot(&.{ "c", "library", "pk.c" }),
        pathJoinRoot(&.{ "c", "library", "pkcs11.c" }),
        pathJoinRoot(&.{ "c", "library", "pkcs12.c" }),
        pathJoinRoot(&.{ "c", "library", "pkcs5.c" }),
        pathJoinRoot(&.{ "c", "library", "pkparse.c" }),
        pathJoinRoot(&.{ "c", "library", "pk_wrap.c" }),
        pathJoinRoot(&.{ "c", "library", "pkwrite.c" }),
        pathJoinRoot(&.{ "c", "library", "platform.c" }),
        pathJoinRoot(&.{ "c", "library", "platform_util.c" }),
        pathJoinRoot(&.{ "c", "library", "poly1305.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_aead.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_cipher.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_client.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_driver_wrappers.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_ecp.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_hash.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_mac.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_rsa.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_se.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_slot_management.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_crypto_storage.c" }),
        pathJoinRoot(&.{ "c", "library", "psa_its_file.c" }),
        pathJoinRoot(&.{ "c", "library", "ripemd160.c" }),
        pathJoinRoot(&.{ "c", "library", "rsa.c" }),
        pathJoinRoot(&.{ "c", "library", "rsa_internal.c" }),
        pathJoinRoot(&.{ "c", "library", "sha1.c" }),
        pathJoinRoot(&.{ "c", "library", "sha256.c" }),
        pathJoinRoot(&.{ "c", "library", "sha512.c" }),
        pathJoinRoot(&.{ "c", "library", "ssl_cache.c" }),
        pathJoinRoot(&.{ "c", "library", "ssl_ciphersuites.c" }),
        pathJoinRoot(&.{ "c", "library", "ssl_cli.c" }),
        pathJoinRoot(&.{ "c", "library", "ssl_cookie.c" }),
        pathJoinRoot(&.{ "c", "library", "ssl_msg.c" }),
        pathJoinRoot(&.{ "c", "library", "ssl_srv.c" }),
        pathJoinRoot(&.{ "c", "library", "ssl_ticket.c" }),
        pathJoinRoot(&.{ "c", "library", "ssl_tls13_keys.c" }),
        pathJoinRoot(&.{ "c", "library", "ssl_tls.c" }),
        pathJoinRoot(&.{ "c", "library", "threading.c" }),
        pathJoinRoot(&.{ "c", "library", "timing.c" }),
        pathJoinRoot(&.{ "c", "library", "version.c" }),
        pathJoinRoot(&.{ "c", "library", "version_features.c" }),
        pathJoinRoot(&.{ "c", "library", "x509.c" }),
        pathJoinRoot(&.{ "c", "library", "x509_create.c" }),
        pathJoinRoot(&.{ "c", "library", "x509_crl.c" }),
        pathJoinRoot(&.{ "c", "library", "x509_crt.c" }),
        pathJoinRoot(&.{ "c", "library", "x509_csr.c" }),
        pathJoinRoot(&.{ "c", "library", "x509write_crt.c" }),
        pathJoinRoot(&.{ "c", "library", "x509write_csr.c" }),
        pathJoinRoot(&.{ "c", "library", "xtea.c" }),
    };
    break :blk ret;
};

const include_dir = pathJoinRoot(&.{ "c", "include" });
const library_include = pathJoinRoot(&.{ "c", "library" });

pub fn link(artifact: *std.build.LibExeObjStep) void {
    artifact.addIncludeDir(include_dir);
    artifact.addIncludeDir(library_include);
    artifact.addCSourceFiles(srcs, &.{});
    artifact.linkLibC();
}
