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
};

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zkg", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    for (pkgs) |pkg| {
        exe.addPackage(pkg);
    }

    ssl.linkBearSSL("libs/zig-bearssl", exe, target);
    exe.install();

    b.installLibFile("src/zkg.zig", "zig/zkg/zkg.zig");
    b.installLibFile("src/import.zig", "zig/zkg/import.zig");
    b.installLibFile("src/zkg_runner.zig", "zig/zkg/zkg_runner.zig");

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run zkg");
    run_step.dependOn(&run_cmd.step);
}
