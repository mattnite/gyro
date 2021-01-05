const std = @import("std");
const Project = @import("Project.zig");

const Allocator = std.mem.Allocator;

pub fn package(
    allocator: *Allocator,
    output_dir: ?[]const u8,
    names: []const []const u8,
) !void {
    const file = try std.fs.cwd().openFile("project.zzz", .{ .read = true });
    defer file.close();

    var project = try Project.fromFile(allocator, file);
    defer project.deinit();

    for (names) |name| if (!project.contains(name)) {
        std.log.err("{} is not a package", .{name});
    };

    const dir = if (output_dir) |output|
        try std.fs.cwd().openDir(
            output,
            .{
                .iterate = true,
                .access_sub_paths = true,
            },
        )
    else
        std.fs.cwd();

    if (names.len > 0) {
        for (names) |name| try project.get(name).?.bundle(std.fs.cwd(), dir);
    } else {
        var it = project.iterator();
        while (it.next()) |pkg| try pkg.bundle(std.fs.cwd(), dir);
    }
}
