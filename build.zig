const std = @import("std");
const libgit2 = @import("libs/zig-libgit2/libgit2.zig");
const mbedtls = @import("libs/zig-mbedtls/mbedtls.zig");
const libssh2 = @import("libs/zig-libssh2/libssh2.zig");
const zlib = @import("libs/zig-zlib/zlib.zig");

const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Pkg = std.build.Pkg;

const clap = .{
    .name = "clap",
    .path = .{ .path = "libs/zig-clap/clap.zig" },
};

const zfetch = .{
    .name = "zfetch",
    .path = .{ .path = "libs/zfetch/src/main.zig" },
    .dependencies = &[_]Pkg{
        .{
            .name = "iguanaTLS",
            .path = .{ .path = "libs/iguanaTLS/src/main.zig" },
        },
        .{
            .name = "network",
            .path = .{ .path = "libs/zig-network/network.zig" },
        },
        .{
            .name = "uri",
            .path = .{ .path = "libs/zig-uri/uri.zig" },
        },
        .{
            .name = "hzzp",
            .path = .{ .path = "libs/hzzp/src/main.zig" },
        },
    },
};

const zzz = .{
    .name = "zzz",
    .path = .{ .path = "libs/zzz/src/main.zig" },
};

const glob = .{
    .name = "glob",
    .path = .{ .path = "libs/glob/src/main.zig" },
};

const tar = .{
    .name = "tar",
    .path = .{ .path = "libs/tar/src/main.zig" },
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
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const z = zlib.create(b, target, mode);
    const tls = mbedtls.create(b, target, mode);
    const ssh2 = libssh2.create(b, target, mode);
    tls.link(ssh2.step);

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
    addAllPkgs(gyro);
    gyro.install();

    // release-* builds for windows end up missing a _tls_index symbol, turning
    // off lto fixes this *shrug*
    if (target.isWindows())
        gyro.want_lto = false;

    const tests = b.addTest("src/main.zig");
    tests.setBuildMode(mode);
    tests.setTarget(target);
    addAllPkgs(tests);

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
