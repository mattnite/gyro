const std = @import("std");
const builtin = @import("builtin");

extern fn git_mbedtls__set_cert_location(path: ?[*:0]const u8, file: ?[*:0]const u8) c_int;
extern fn git_mbedtls__set_cert_buf(buf: [*]const u8, len: usize) c_int;

/// based off of golang's system cert finding code: https://golang.org/src/crypto/x509/
pub fn loadSystemCerts(allocator: *std.mem.Allocator) !void {
    switch (builtin.target.os.tag) {
        .windows => {
            const c = @cImport({
                @cInclude("wincrypt.h");
            });

            const store = c.CertOpenSystemStoreA(null, "ROOT");
            if (store == null) {
                std.log.err("failed to open system cert store", .{});
                return error.Explained;
            }
            defer _ = c.CertCloseStore(store, 0);

            //var cert: ?*c.PCCERT_CONTEXT = null;
            //while (true) {
            //    cert = c.CertEnumCertificatesInStore(store, cert);
            //    if (cert_context == null) {
            //        // TODO: handle errors and end of certs
            //    }

            //    // TODO: check for X509_ASN_ENCODING
            //    mbedtls_x509_crt_parse(ca_chain, cert.pbCertEncoded, cert.cbCertEncoded);
            //}

            //mbedtls_ssl_conf_ca_chain();
        },
        .ios => @compileError("TODO: ios certs"),
        .macos => {},
        .linux,
        .aix,
        .dragonfly,
        .netbsd,
        .freebsd,
        .openbsd,
        .plan9,
        .solaris,
        => try loadUnixCerts(allocator),
        else => std.log.warn("don't know how to load system certs for this os", .{}),
    }
}

fn loadUnixCerts(allocator: *std.mem.Allocator) !void {
    // TODO: env var overload
    const has_env_var = try std.process.hasEnvVar(allocator, "SSL_CERT_FILE");
    const files: []const [:0]const u8 = if (has_env_var) blk: {
        const file_path = try std.process.getEnvVarOwned(allocator, "SSL_CERT_FILE");
        defer allocator.free(file_path);

        break :blk &.{try allocator.dupeZ(u8, file_path)};
    } else switch (builtin.target.os.tag) {
        .linux => &.{
            // Debian/Ubuntu/Gentoo etc.
            "/etc/ssl/certs/ca-certificates.crt",
            // Fedora/RHEL 6
            "/etc/pki/tls/certs/ca-bundle.crt",
            // OpenSUSE
            "/etc/ssl/ca-bundle.pem",
            // OpenELEC
            "/etc/pki/tls/cacert.pem",
            // CentOS/RHEL 7
            "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
            // Alpine Linux
            "/etc/ssl/cert.pem",
        },
        .aix => &.{"/var/ssl/certs/ca-bundle.crt"},
        .dragonfly => &.{"/usr/local/share/certs/ca-root-nss.crt"},
        .netbsd => &.{"/etc/openssl/certs/ca-certificates.crt"},
        .freebsd => &.{"/usr/local/etc/ssl/cert.pem"},
        .openbsd => &.{"/etc/ssl/cert.pem"},
        .plan9 => &.{"/sys/lib/tls/ca.pem"},
        .solaris => &.{
            // Solaris 11.2+
            "/etc/certs/ca-certificates.crt",
            // Joyent SmartOS
            "/etc/ssl/certs/ca-certificates.crt",
            // OmniOS
            "/etc/ssl/cacert.pem",
        },
        else => @compileError("Don't know how to load system certs for this unix os"),
    };
    defer if (has_env_var) allocator.free(files[0]);

    for (files) |path| {
        const rc = git_mbedtls__set_cert_location(path, null);
        if (rc == 0) {
            std.log.debug("cert path: {s}", .{path});
            return;
        }
    }
}
