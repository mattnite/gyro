usingnamespace std.build;
const std = @import("std");
const ssl = @import(pkgs.ssl.path);

const pkgs = .{
    .clap = .{
        .name = "clap",
        .path = "libs/zig-clap/clap.zig",
    },
    .http = .{
        .name = "http",
        .path = "libs/hzzp/src/main.zig",
    },
    .net = .{
        .name = "net",
        .path = "libs/zig-network/network.zig",
    },
    .ssl = .{
        .name = "ssl",
        .path = "libs/zig-bearssl/bearssl.zig",
    },
    .uri = .{
        .name = "uri",
        .path = "libs/zuri/src/zuri.zig",
    },
    .zzz = .{
        .name = "zzz",
        .path = "libs/zzz/src/main.zig",
    },
};

pub fn build(b: *Builder) !void {
    var target = b.standardTargetOptions(.{
        .default_target = try std.zig.CrossTarget.parse(.{
            .arch_os_abi = if (std.builtin.os.tag == .windows)
                "native-native-gnu" // on windows, use gnu by default
            else
                "native-linux-musl", // glibc has some problems by-default, use musl instead
        }),
    });

    if (target.abi == null) {
        target.abi = switch (std.builtin.os.tag) {
            .windows => .gnu,
            else => .musl,
        };
    }

    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zkg", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    const tests = b.addTest("tests/main.zig");
    tests.setBuildMode(mode);
    inline for (std.meta.fields(@TypeOf(pkgs))) |field| {
        exe.addPackage(@field(pkgs, field.name));
        tests.addPackage(@field(pkgs, field.name));
    }

    ssl.linkBearSSL("libs/zig-bearssl", exe, target);
    exe.linkLibC();
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run zkg");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    run_step.dependOn(&tests.step);
}
