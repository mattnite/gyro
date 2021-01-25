usingnamespace std.build;
const std = @import("std");
const ssl = @import(pkgs.ssl.path);
const pkgs = @import("deps.zig").pkgs;

const clap = .{
    .name = "clap",
    .path = "libs/zig-clap/clap.zig",
};

const version = .{
    .name = "version",
    .path = "libs/version/src/main.zig",
    .dependencies = &[_]Pkg{
        .{
            .name = "mecha",
            .path = "libs/mecha/mecha.zig",
        },
    },
};

const tar = .{
    .name = "tar",
    .path = "libs/tar/src/main.zig",
};

const zzz = .{
    .name = "zzz",
    .path = "libs/zzz/src/main.zig",
};

const glob = .{
    .name = "glob",
    .path = "libs/glob/src/main.zig",
};

const hzzp = .{
    .name = "hzzp",
    .path = "libs/hzzp/src/main.zig",
};

const zfetch = .{
    .name = "zfetch",
    .path = "libs/zfetch/src/main.zig",
    .dependencies = &[_]std.build.Pkg{
        hzzp,
        uri,
        .{
            .name = "network",
            .path = "libs/zig-network/network.zig",
        },
        .{
            .name = "iguanatls",
            .path = "libs/iguanaTLS/src/main.zig",
        },
    },
};

const uri = .{
    .name = "uri",
    .path = "libs/zig-uri/uri.zig",
};

fn addAllPkgs(lib: *LibExeObjStep) void {
    lib.addPackage(clap);
    lib.addPackage(version);
    lib.addPackage(tar);
    lib.addPackage(zzz);
    lib.addPackage(glob);
    lib.addPackage(hzzp);
    lib.addPackage(zfetch);
    lib.addPackage(uri);
}
pub fn build(b: *Builder) !void {
    var target = b.standardTargetOptions(.{});
    if (target.abi == null) {
        target.abi = switch (std.builtin.os.tag) {
            .windows => .gnu,
            else => .musl,
        };
    }

    const mode = b.standardReleaseOptions();

    const bootstrap = b.option(bool, "bootstrap", "bootstrapping with just the zig compiler");

    const gyro = b.addExecutable("gyro", "src/main.zig");
    gyro.setTarget(target);
    gyro.setBuildMode(mode);
    if (bootstrap) |bs| {
        if (bs) {
            addAllPkgs(gyro);
        } else {
            pkgs.addAllTo(gyro);
        }
    } else {
        pkgs.addAllTo(gyro);
    }

    gyro.install();

    const tests = b.addTest("src/main.zig");
    tests.setBuildMode(mode);
    addAllPkgs(tests);
    tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
