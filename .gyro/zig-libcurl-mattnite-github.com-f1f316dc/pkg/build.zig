const std = @import("std");
const libcurl = @import("libcurl.zig");
const mbedtls = @import("mbedtls");
const libssh2 = @import("libssh2");
const zlib = @import("zlib");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const z = zlib.create(b, target, mode);
    const tls = mbedtls.create(b, target, mode);
    const ssh2 = libssh2.create(b, target, mode);
    tls.link(ssh2.step);

    const curl = try libcurl.create(b, target, mode);
    ssh2.link(curl.step);
    tls.link(curl.step);
    z.link(curl.step, .{});
    curl.step.install();

    const tests = b.addTest("src/main.zig");
    tests.setBuildMode(mode);
    tests.setTarget(target);
    curl.link(tests, .{});
    z.link(tests, .{});
    tls.link(tests);
    ssh2.link(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
