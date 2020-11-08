usingnamespace std.build;
const std = @import("std");

const ssl = @import("libs/zig-bearssl/bearssl.zig");

const pkgs = [_]Pkg{
    Pkg{
        .name = "clap",
        .path = "libs/zig-clap/clap.zig",
    },
    Pkg{
        .name = "http",
        .path = "libs/hzzp/src/main.zig",
    },
    Pkg{
        .name = "net",
        .path = "libs/zig-network/network.zig",
    },
    Pkg{
        .name = "ssl",
        .path = "libs/zig-bearssl/bearssl.zig",
    },
    Pkg{
        .name = "uri",
        .path = "libs/zuri/src/zuri.zig",
    },
    Pkg{
        .name = "zzz",
        .path = "libs/zzz/src/main.zig",
    },
};

pub fn build(b: *Builder) void {
    var target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    if (target.abi == null) {
        target.abi = .musl;
    }

    const exe = b.addExecutable("zkg", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    for (pkgs) |pkg| {
        exe.addPackage(pkg);
    }

    ssl.linkBearSSL("libs/zig-bearssl", exe, target);
    exe.linkSystemLibrary("git2");
    exe.linkSystemLibrary("openssl");
    exe.linkSystemLibrary("crypto");
    exe.linkSystemLibrary("ssh2");
    exe.linkSystemLibrary("zlib");
    exe.linkSystemLibrary("pcre");
    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run zkg");
    run_step.dependOn(&run_cmd.step);
}
