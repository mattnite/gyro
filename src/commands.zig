const std = @import("std");
const Project = @import("Project.zig");
const Lockfile = @import("Lockfile.zig");
const DependencyTree = @import("DependencyTree.zig");

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

pub fn fetch(allocator: *Allocator) !void {
    const project_file = try std.fs.cwd().openFile(
        "project.zzz",
        .{ .read = true },
    );
    defer project_file.close();

    const lock_file = try std.fs.cwd().createFile(
        "gyro.lock",
        .{ .truncate = false, .read = true },
    );
    defer lock_file.close();

    var project = try Project.fromFile(allocator, project_file);
    defer project.deinit();

    var lockfile = try Lockfile.fromFile(allocator, lock_file);
    defer lockfile.deinit();

    const dep_tree = try DependencyTree.generate(
        allocator,
        &lockfile,
        project.dependencies,
    );
    defer dep_tree.deinit();

    const build_dep_tree = try DependencyTree.generate(
        allocator,
        &lockfile,
        project.build_dependencies,
    );
    defer build_dep_tree.deinit();

    try lockfile.fetchAll();
}

pub fn update(allocator: *Allocator) !void {
    try std.fs.cwd().deleteFile("gyro.lock");
    try fetch(allocator);
}
