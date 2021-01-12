const std = @import("std");
const clap = @import("clap");
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

        self.build_dep_tree.destroy();
        self.dep_tree.destroy();
        self.lockfile.deinit();
        self.project.deinit();

        // TODO: delete lockfile if it doesn't have anything in it

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
    errdefer dep_tree.destroy();

    const build_dep_tree = try DependencyTree.generate(
        allocator,
        &lockfile,
        project.build_dependencies,
    );
    errdefer build_dep_tree.destroy();

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
    var ctx = try fetchImpl(allocator);
    defer ctx.deinit();
}

pub fn update(allocator: *Allocator) !void {
    try std.fs.cwd().deleteFile("gyro.lock");
    try fetch(allocator);
}

pub fn build(allocator: *Allocator, it: *clap.args.OsIterator) !void {
    //var ctx = try fetchImpl(allocator);
    //defer ctx.deinit();
    std.fs.cwd().access("build.zig", .{ .read = true }) catch |err| {
        return if (err == error.FileNotFound) blk: {
            std.log.err("no build.zig in current working directory", .{});
            break :blk error.Explained;
        } else err;
    };

    var fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} }).init(allocator);
    defer fifo.deinit();

    // get env from zig
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "zig", "env" },
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .Exited => |val| {
            if (val != 0) {
                std.log.err("zig compiler returned error code: {}", .{val});
                return error.Explained;
            }
        },
        .Signal => |sig| {
            std.log.err("zig compiler interrupted by signal: {}", .{sig});
            return error.Explained;
        },
        else => return error.UnknownTerm,
    }

    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    var value_tree = try parser.parse(result.stdout);
    defer value_tree.deinit();

    const std_path = try switch (value_tree.root) {
        .Object => |obj| if (obj.get("std_dir")) |key| switch (key) {
            .String => |str| str,
            else => error.InvalidJson,
        } else error.InvalidJson,
        else => return error.InvalidJson,
    };

    const path = try std.fs.path.join(
        allocator,
        &[_][]const u8{ std_path, "special" },
    );
    defer allocator.free(path);

    var special_dir = try std.fs.openDirAbsolute(
        path,
        .{ .access_sub_paths = true },
    );
    defer special_dir.close();

    try special_dir.copyFile(
        "build_runner.zig",
        std.fs.cwd(),
        "build_runner.zig",
        .{},
    );
    defer std.fs.cwd().deleteFile("build_runner.zig") catch {};

    //const pkgs = try ctx.build_dep_tree.createPkgs(allocator);
    //defer pkgs.deinit();

    const b = try std.build.Builder.create(
        allocator,
        "/usr/local/bin/zig",
        ".",
        "zig-cache",
        "/home/mknight/.cache/zig",
    );
    defer b.destroy();

    b.resolveInstallPrefix();

    // build script here
    const runner = b.addExecutable("build", "build_runner.zig");
    runner.addPackage(std.build.Pkg{
        .name = "@build",
        .path = "build.zig",
    });

    const run_cmd = runner.run();
    b.default_step.dependOn(&run_cmd.step);

    // add positionals here

    if (b.validateUserInputDidItFail()) {
        return error.UserInputFailed;
    }

    b.make(&[_][]const u8{"install"}) catch |err| {
        switch (err) {
            error.UncleanExit => {
                std.log.err("Compiler had an unclean exit", .{});
                return error.Explained;
            },
            else => return err,
        }
    };
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

    if (project.packages.count() == 0) {
        std.log.err("there are no packages to package!", .{});
        return error.Explained;
    }

    var found_not_pkg = false;
    for (names) |name| if (!project.contains(name)) {
        std.log.err("{s} is not a package", .{name});
        found_not_pkg = true;
    };

    if (found_not_pkg) return error.Explained;
    var write_dir = try std.fs.cwd().openDir(
        if (output_dir) |output| output else ".",
        .{ .iterate = true, .access_sub_paths = true },
    );
    defer write_dir.close();

    var read_dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer read_dir.close();

    if (names.len > 0) {
        for (names) |name| try project.get(name).?.bundle(read_dir, write_dir);
    } else {
        var it = project.iterator();
        while (it.next()) |pkg| try pkg.bundle(read_dir, write_dir);
    }
}
