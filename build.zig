usingnamespace std.build;
const std = @import("std");

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zkg", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    b.installLibFile("src/zkg.zig", "zig/zkg/zkg.zig");
    b.installLibFile("src/import.zig", "zig/zkg/import.zig");
    b.installLibFile("src/zkg_runner.zig", "zig/zkg/zkg_runner.zig");

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run zkg");
    run_step.dependOn(&run_cmd.step);
}
