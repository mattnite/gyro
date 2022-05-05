const std = @import("std");
const libgit2 = @import("libgit2.zig");
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

    const git2 = try libgit2.create(b, target, mode);
    ssh2.link(git2.step);
    tls.link(git2.step);
    z.link(git2.step, .{});
    git2.step.install();

    const test_step = b.step("test", "Run tests");
    _ = test_step;
}
