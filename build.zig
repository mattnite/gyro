usingnamespace std.build;
const std = @import("std");
const ssl = @import(pkgs.ssl.path);
const pkgs = @import("deps.zig").pkgs;

const clap = .{
    .name = "clap",
    .path = .{ .path = "libs/zig-clap/clap.zig" },
};

const version = .{
    .name = "version",
    .path = .{ .path = "libs/version/src/main.zig" },
    .dependencies = &[_]Pkg{
        .{
            .name = "mecha",
            .path = .{ .path = "libs/mecha/mecha.zig" },
        },
    },
};

const tar = .{
    .name = "tar",
    .path = .{ .path = "libs/tar/src/main.zig" },
};

const zzz = .{
    .name = "zzz",
    .path = .{ .path = "libs/zzz/src/main.zig" },
};

const glob = .{
    .name = "glob",
    .path = .{ .path = "libs/glob/src/main.zig" },
};

const hzzp = .{
    .name = "hzzp",
    .path = .{ .path = "libs/hzzp/src/main.zig" },
};

const zfetch = .{
    .name = "zfetch",
    .path = .{ .path = "libs/zfetch/src/main.zig" },
    .dependencies = &[_]std.build.Pkg{
        hzzp,
        uri,
        .{
            .name = "network",
            .path = .{ .path = "libs/zig-network/network.zig" },
        },
        .{
            .name = "iguanaTLS",
            .path = .{ .path = "libs/iguanaTLS/src/main.zig" },
        },
    },
};

const uri = .{
    .name = "uri",
    .path = .{ .path = "libs/zig-uri/uri.zig" },
};

const known_folders = .{
    .name = "known-folders",
    .path = .{ .path = "libs/known-folders/known-folders.zig" },
};

fn addAllPkgs(lib: *LibExeObjStep) void {
    lib.addPackage(clap);
    lib.addPackage(version);
    lib.addPackage(tar);
    lib.addPackage(zzz);
    lib.addPackage(glob);
    lib.addPackage(zfetch);
    lib.addPackage(uri);
    lib.addPackage(known_folders);
}
pub fn build(b: *Builder) !void {
    var target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const bootstrap = b.option(bool, "bootstrap", "bootstrapping with just the zig compiler");
    const repository = b.option([]const u8, "repo", "default package index (default is astrolabe.pm)");

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

    gyro.addBuildOption([]const u8, "default_repo", repository orelse "astrolabe.pm");
    gyro.install();

    const tests = b.addTest("src/main.zig");
    tests.setBuildMode(mode);
    addAllPkgs(tests);
    tests.addBuildOption([]const u8, "default_repo", repository orelse "astrolabe.pm");
    tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests.step);
}
