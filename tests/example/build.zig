const Builder = @import("std").build.Builder;
const packages = @import("zig-cache/packages.zig").list;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zag-example", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    for (packages) |pkg| {
        exe.addPackage(pkg);
    }
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
