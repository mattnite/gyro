const std = @import("std");
const builtin = @import("builtin");
const deps = @import("deps.zig");

const libgit2 = deps.build_pkgs.libgit2;
const mbedtls = deps.build_pkgs.mbedtls;
const libssh2 = deps.build_pkgs.libssh2;
const zlib = deps.build_pkgs.zlib;
const libcurl = deps.build_pkgs.libcurl;

const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Pkg = std.build.Pkg;

pub fn build(b: *Builder) !void {
    const target = b.standardTargetOptions(.{
        .default_target = std.zig.CrossTarget{
            .abi = if (builtin.os.tag == .linux) .musl else null,
        },
    });
    const mode = b.standardReleaseOptions();

    if (target.isLinux() and target.isGnuLibC()) {
        std.log.err("glibc builds don't work right now, use musl instead. The issue is tracked here: https://github.com/ziglang/zig/issues/9485", .{});
        return error.WaitingOnFix;
    }

    const z = zlib.create(b, target, mode);
    const tls = mbedtls.create(b, target, mode);
    const ssh2 = libssh2.create(b, target, mode);
    tls.link(ssh2.step);

    const curl = try libcurl.create(b, target, mode);
    ssh2.link(curl.step);
    tls.link(curl.step);
    z.link(curl.step, .{});

    const git2 = try libgit2.create(b, target, mode);
    z.link(git2.step, .{});
    tls.link(git2.step);
    ssh2.link(git2.step);

    const gyro = b.addExecutable("gyro", "src/main.zig");
    gyro.setTarget(target);
    gyro.setBuildMode(mode);
    z.link(gyro, .{});
    tls.link(gyro);
    ssh2.link(gyro);
    git2.link(gyro);
    curl.link(gyro, .{ .import_name = "curl" });
    deps.pkgs.addAllTo(gyro);
    gyro.install();

    // release-* builds for windows end up missing a _tls_index symbol, turning
    // off lto fixes this *shrug*
    if (target.isWindows())
        gyro.want_lto = false;

    const tests = b.addTest("src/main.zig");
    tests.setBuildMode(mode);
    tests.setTarget(target);
    deps.pkgs.addAllTo(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);

    const run_cmd = gyro.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
