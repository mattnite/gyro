const std = @import("std");
const Project = @import("Project.zig");
const Lockfile = @import("Lockfile.zig");
const DependencyTree = @import("DependencyTree.zig");

const Allocator = std.mem.Allocator;

const FetchContext = struct {
    project_file: std.fs.File,
    lock_file: std.fs.File,

    project: Project,
    lockfile: Lockfile,
    dep_tree: *DependencyTree,
    build_dep_tree: *DependencyTree,

    fn deinit(self: *FetchContext) void {
        self.lockfile.save(self.lock_file) catch {};

        self.build_dep_tree.deinit();
        self.dep_tree.deinit();
        self.lockfile.deinit();
        self.project.deinit();
        self.lock_file.close();
        self.project_file.close();
    }
};

pub fn fetchImpl(allocator: *Allocator) !FetchContext {
    const project_file = try std.fs.cwd().openFile(
        "gyro.zzz",
        .{ .read = true },
    );
    errdefer project_file.close();

    const lock_file = try std.fs.cwd().createFile(
        "gyro.lock",
        .{ .truncate = false, .read = true },
    );
    errdefer lock_file.close();

    var project = try Project.fromFile(allocator, project_file);
    errdefer project.deinit();

    var lockfile = try Lockfile.fromFile(allocator, lock_file);
    errdefer lockfile.deinit();

    const dep_tree = try DependencyTree.generate(
        allocator,
        &lockfile,
        project.dependencies,
    );
    errdefer dep_tree.deinit();

    const build_dep_tree = try DependencyTree.generate(
        allocator,
        &lockfile,
        project.build_dependencies,
    );
    errdefer build_dep_tree.deinit();

    try lockfile.fetchAll();
    return FetchContext{
        .project_file = project_file,
        .lock_file = lock_file,
        .project = project,
        .lockfile = lockfile,
        .dep_tree = dep_tree,
        .build_dep_tree = build_dep_tree,
    };
}

pub fn fetch(allocator: *Allocator) !void {
    (try fetchImpl(allocator)).deinit();
}

pub fn update(allocator: *Allocator) !void {
    try std.fs.cwd().deleteFile("gyro.lock");
    try fetch(allocator);
}

pub fn build(allocator: *Allocator) !void {
    const ctx = fetchImpl(allocator);
    defer ctx.deinit();

    const pkgs = ctx.build_dep_tree.createPkgs(allocator);
    defer pkgs.deinit();

    // TODO: build build_runner, run it with args
}

pub fn package(
    allocator: *Allocator,
    output_dir: ?[]const u8,
    names: []const []const u8,
) !void {
    const file = try std.fs.cwd().openFile("gyro.zzz", .{ .read = true });
    defer file.close();

    var project = try Project.fromFile(allocator, file);
    defer project.deinit();

    for (names) |name| if (!project.contains(name)) {
        std.log.err("{} is not a package", .{name});
    };

    const dir = if (output_dir) |output|
        try std.fs.cwd().openDir(
            output,
            .{ .iterate = true, .access_sub_paths = true },
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
