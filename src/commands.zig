const std = @import("std");
const clap = @import("clap");
const api = @import("api.zig");
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
    const project_file = std.fs.cwd().openFile(
        "gyro.zzz",
        .{ .read = true },
    ) catch |err| {
        return if (err == error.FileNotFound) blk: {
            std.log.err("Missing gyro.zzz project file", .{});
            break :blk error.Explained;
        } else err;
    };
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

const EnvInfo = struct {
    zig_exe: []const u8,
    lib_dir: []const u8,
    std_dir: []const u8,
    global_cache_dir: []const u8,
    version: []const u8,
};

pub fn build(allocator: *Allocator, args: *clap.args.OsIterator) !void {
    var ctx = try fetchImpl(allocator);
    defer ctx.deinit();

    std.fs.cwd().access("build.zig", .{ .read = true }) catch |err| {
        return if (err == error.FileNotFound) blk: {
            std.log.err("no build.zig in current working directory", .{});
            break :blk error.Explained;
        } else err;
    };

    var fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} }).init(allocator);
    defer fifo.deinit();

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

    const parse_opts = std.json.ParseOptions{ .allocator = allocator };
    const env = try std.json.parse(
        EnvInfo,
        &std.json.TokenStream.init(result.stdout),
        parse_opts,
    );
    defer std.json.parseFree(EnvInfo, env, parse_opts);

    const path = try std.fs.path.join(
        allocator,
        &[_][]const u8{ env.std_dir, "special" },
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

    //const build_pkgs = try ctx.build_dep_tree.createPkgs(allocator);
    //defer pkgs.deinit();

    // TODO: configurable local cache
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const b = try std.build.Builder.create(
        &arena.allocator,
        env.zig_exe,
        ".",
        "zig-cache",
        env.global_cache_dir,
    );
    defer b.destroy();

    const deps_file = try std.fs.cwd().createFile("deps.zig", .{ .truncate = true });
    defer deps_file.close();

    try ctx.dep_tree.printZig(deps_file.writer());

    b.resolveInstallPrefix();
    const runner = b.addExecutable("build", "build_runner.zig");
    runner.addPackage(std.build.Pkg{
        .name = "@build",
        .path = "build.zig",
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "gyro",
                .path = "deps.zig",
            },
        },
    });

    // // add build_deps here
    // try pkgs.addAllTo(runner)
    //
    // // add normal deps as build_option

    const run_cmd = runner.run();
    run_cmd.addArgs(&[_][]const u8{
        env.zig_exe,
        ".",
        "zig-cache",
        env.global_cache_dir,
    });

    while (try args.next()) |arg| run_cmd.addArg(arg);
    b.default_step.dependOn(&run_cmd.step);
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

fn maybePrintKey(
    json_key: []const u8,
    zzz_key: []const u8,
    root: anytype,
    writer: anytype,
) !void {
    if (root.get(json_key)) |val| {
        switch (val) {
            .String => |str| try writer.print("    {s}: \"{s}\"\n", .{ zzz_key, str }),
            else => {},
        }
    }
}

pub fn init(
    allocator: *Allocator,
    link: []const u8,
) !void {
    const file = std.fs.cwd().createFile("gyro.zzz", .{ .exclusive = true }) catch |err| {
        return if (err == error.PathAlreadyExists) blk: {
            std.log.err("gyro.zzz already exists", .{});
            break :blk error.Explained;
        } else err;
    };
    errdefer std.fs.cwd().deleteFile("gyro.zzz") catch {};
    defer file.close();

    const info = blk: {
        const gh_url = "github.com";
        const begin = if (std.mem.indexOf(u8, link, gh_url)) |i|
            if (link.len >= i + gh_url.len + 1) i + gh_url.len + 1 else {
                std.log.err("couldn't parse link", .{});
                return error.Explained;
            }
        else
            0;
        const end = if (std.mem.endsWith(u8, link, ".git")) link.len - 4 else link.len;

        const ret = link[begin..end];
        if (std.mem.count(u8, ret, "/") != 1) {
            std.log.err(
                "got '{s}' from '{s}', it needs to have a single '/' so I can figure out the user/repo",
                .{ ret, link },
            );
            return error.Explained;
        }

        break :blk ret;
    };

    var it = std.mem.tokenize(info, "/");
    const user = it.next().?;
    const repo = it.next().?;
    var repo_tree = try api.getGithubRepo(allocator, user, repo);
    defer repo_tree.deinit();

    var topics_tree = try api.getGithubTopics(allocator, user, repo);
    defer topics_tree.deinit();

    if (repo_tree.root != .Object or topics_tree.root != .Object) {
        std.log.err("Invalid JSON response from Github", .{});
        return error.Explained;
    }

    const repo_root = repo_tree.root.Object;
    const topics_root = topics_tree.root.Object;
    const writer = file.writer();
    try writer.print(
        \\pkgs:
        \\  {s}:
        \\    version: 0.0.0
        \\    author: {s}
        \\
    , .{ repo, user });

    try maybePrintKey("description", "description", repo_root, writer);

    // pretty gross ngl
    if (repo_root.get("license")) |license| {
        switch (license) {
            .Object => |obj| {
                if (obj.get("spdx_id")) |spdx| {
                    switch (spdx) {
                        .String => |id| {
                            try writer.print("    license: {s}\n", .{id});
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }

    try maybePrintKey("html_url", "source_url", repo_root, writer);
    if (topics_root.get("names")) |topics| {
        switch (topics) {
            .Array => |arr| {
                if (arr.items.len > 0) {
                    try writer.print("    tags:\n", .{});
                    for (arr.items) |topic| {
                        switch (topic) {
                            .String => |str| if (std.mem.indexOf(u8, str, "zig") == null) {
                                try writer.print("      {s}\n", .{str});
                            },
                            else => {},
                        }
                    }
                }
            },
            else => {},
        }
    }
    try writer.print(
        \\
        \\    root: src/main.zig
        \\    files:
        \\      README.md
        \\      LICENSE
        \\
    , .{});
}
