const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const version = @import("version");
const zzz = @import("zzz");
const known_folders = @import("known-folders");
const curl = @import("curl");

const Dependency = @import("Dependency.zig");
const Engine = @import("Engine.zig");
const Project = @import("Project.zig");
const ThreadSafeArenaAllocator = @import("ThreadSafeArenaAllocator.zig");
const api = @import("api.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;

fn assertFileExistsInCwd(subpath: []const u8) !void {
    std.fs.cwd().access(subpath, .{ .mode = .read_only }) catch |err| {
        return if (err == error.FileNotFound) blk: {
            std.log.err("no {s} in current working directory", .{subpath});
            break :blk error.Explained;
        } else err;
    };
}

// move to an explicit step later, for now make it automatic and slick
fn migrateGithubLockfile(allocator: Allocator, file: std.fs.File) !void {
    var to_lines = std.ArrayList([]const u8).init(allocator);
    defer to_lines.deinit();

    var github_lines = std.ArrayList([]const u8).init(allocator);
    defer github_lines.deinit();

    const text = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(text);

    // sort between good entries and github entries
    var it = std.mem.tokenize(u8, text, "\n");
    while (it.next()) |line|
        if (std.mem.startsWith(u8, line, "github"))
            try github_lines.append(line)
        else
            try to_lines.append(line);

    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    // convert each github entry to a git entry
    for (github_lines.items) |line| {
        var line_it = std.mem.tokenize(u8, line, " ");

        // github label
        _ = line_it.next() orelse unreachable;

        const new_line = try std.fmt.allocPrint(
            arena.allocator(),
            "git https://github.com/{s}/{s}.git {s} {s} {s}",
            .{
                .user = line_it.next() orelse return error.NoUser,
                .repo = line_it.next() orelse return error.NoRepo,
                .ref = line_it.next() orelse return error.NoRef,
                .root = line_it.next() orelse return error.NoRoot,
                .commit = line_it.next() orelse return error.NoCommit,
            },
        );

        try to_lines.append(new_line);
    }

    // clear file and write all entries to it
    try file.setEndPos(0);
    try file.seekTo(0);

    const writer = file.writer();
    for (to_lines.items) |line| {
        try writer.writeAll(line);
        try writer.writeByte('\n');
    }

    // seek to beginning so that any future reading is from the beginning of the file
    try file.seekTo(0);
}

pub fn fetch(allocator: Allocator) !void {
    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    const project = try Project.fromDirPath(&arena, ".");
    defer project.destroy();

    const lockfile = try std.fs.cwd().createFile("gyro.lock", .{
        .read = true,
        .truncate = false,
    });
    defer lockfile.close();

    try migrateGithubLockfile(allocator, lockfile);
    const deps_file = try std.fs.cwd().createFile("deps.zig", .{
        .truncate = true,
    });
    defer deps_file.close();

    var engine = try Engine.init(allocator, project, lockfile.reader());
    defer engine.deinit();

    try engine.fetch();
    try lockfile.setEndPos(0);
    try lockfile.seekTo(0);
    try engine.writeLockfile(lockfile.writer());
    try engine.writeDepsZig(deps_file.writer());

    const project_file = try std.fs.cwd().openFile("gyro.zzz", .{ .mode = .read_write });
    defer project_file.close();

    try project.toFile(project_file);
}

pub fn update(
    allocator: Allocator,
    targets: []const []const u8,
) !void {
    if (targets.len == 0) {
        try std.fs.cwd().deleteFile("gyro.lock");
        try fetch(allocator);
        return;
    }

    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    const project = try Project.fromDirPath(&arena, ".");
    defer project.destroy();

    const lockfile = try std.fs.cwd().createFile("gyro.lock", .{
        .read = true,
        .truncate = false,
    });
    defer lockfile.close();

    try migrateGithubLockfile(allocator, lockfile);
    const deps_file = try std.fs.cwd().createFile("deps.zig", .{
        .truncate = true,
    });
    defer deps_file.close();

    var engine = try Engine.init(allocator, project, lockfile.reader());
    defer engine.deinit();

    for (targets) |target|
        try engine.clearResolution(target);

    try engine.fetch();
    try lockfile.setEndPos(0);
    try lockfile.seekTo(0);
    try engine.writeLockfile(lockfile.writer());
    try engine.writeDepsZig(deps_file.writer());
}

const EnvInfo = struct {
    zig_exe: []const u8,
    lib_dir: []const u8,
    std_dir: []const u8,
    global_cache_dir: []const u8,
    version: []const u8,
};

pub fn build(allocator: Allocator, args: *std.process.ArgIterator) !void {
    try assertFileExistsInCwd("build.zig");

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

    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    const project = blk: {
        const project_file = std.fs.cwd().openFile("gyro.zzz", .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try Project.fromUnownedText(&arena, ".", ""),
            else => |e| return e,
        };
        defer project_file.close();

        break :blk try Project.fromFile(&arena, ".", project_file);
    };
    defer project.destroy();

    const lockfile = try std.fs.cwd().createFile("gyro.lock", .{
        .read = true,
        .truncate = false,
    });
    defer lockfile.close();

    try migrateGithubLockfile(allocator, lockfile);
    const deps_file = try std.fs.cwd().createFile("deps.zig", .{
        .truncate = true,
    });
    defer deps_file.close();

    var engine = try Engine.init(allocator, project, lockfile.reader());
    defer engine.deinit();

    try engine.fetch();

    try lockfile.setEndPos(0);
    try lockfile.seekTo(0);
    try engine.writeLockfile(lockfile.writer());

    try engine.writeDepsZig(deps_file.writer());

    // TODO: configurable local cache

    const pkgs = try engine.genBuildDeps(&arena);
    defer pkgs.deinit();

    const b = try std.build.Builder.create(
        arena.allocator(),
        env.zig_exe,
        ".",
        "zig-cache",
        env.global_cache_dir,
    );
    defer b.destroy();

    b.resolveInstallPrefix(null, .{});
    const runner = b.addExecutable("build", "build_runner.zig");
    runner.addPackage(std.build.Pkg{
        .name = "@build",
        .path = .{
            .path = "build.zig",
        },
        .dependencies = pkgs.items,
    });

    const run_cmd = runner.run();
    run_cmd.addArgs(&[_][]const u8{
        env.zig_exe,
        ".",
        "zig-cache",
        env.global_cache_dir,
    });

    while (args.next()) |arg| run_cmd.addArg(arg);
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
            error.UnexpectedExitCode => return error.Explained,
            else => return err,
        }
    };

    const project_file = try std.fs.cwd().openFile("gyro.zzz", .{ .mode = .read_write });
    defer project_file.close();

    try project.toFile(project_file);
}

pub fn package(
    allocator: Allocator,
    output_dir: ?[]const u8,
    names: []const []const u8,
) !void {
    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    const project = try Project.fromDirPath(&arena, ".");
    defer project.destroy();

    if (project.packages.count() == 0) {
        std.log.err("there are no packages to package!", .{});
        return error.Explained;
    }

    validateNoRedirects(allocator) catch |e| switch (e) {
        error.RedirectsExist => {
            std.log.err("you need to clear redirects before packaging with 'gyro redirect --clean'", .{});
            return error.Explained;
        },
        else => return e,
    };

    var found_not_pkg = false;
    for (names) |name|
        if (!project.contains(name)) {
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
    allocator: Allocator,
    link: ?[]const u8,
) !void {
    const file = std.fs.cwd().createFile("gyro.zzz", .{ .exclusive = true }) catch |err| {
        return if (err == error.PathAlreadyExists) blk: {
            std.log.err("gyro.zzz already exists", .{});
            break :blk error.Explained;
        } else err;
    };
    errdefer std.fs.cwd().deleteFile("gyro.zzz") catch {};
    defer file.close();

    const info = try utils.parseUserRepo(link orelse return);

    var repo_tree = try api.getGithubRepo(allocator, info.user, info.repo);
    defer repo_tree.deinit();

    var topics_tree = try api.getGithubTopics(allocator, info.user, info.repo);
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
        \\
    , .{try utils.normalizeName(info.repo)});

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

// check for alias collisions
fn verifyUniqueAlias(alias: []const u8, deps: []const Dependency) !void {
    for (deps) |dep| {
        if (std.mem.eql(u8, alias, dep.alias)) {
            std.log.err("The alias '{s}' is already in use for this project", .{alias});
            return error.Explained;
        }
    }
}

fn gitDependency(
    arena: *ThreadSafeArenaAllocator,
    url: []const u8,
    alias_opt: ?[]const u8,
    ref_opt: ?[]const u8,
    root_opt: ?[]const u8,
) !Dependency {
    const git = @import("git.zig");
    const cache = @import("cache.zig");

    const allocator = arena.child_allocator;
    const commit = if (ref_opt) |r|
        try git.getHeadCommitOfRef(allocator, url, r)
    else
        try git.getHEADCommit(allocator, url);
    const ref = if (ref_opt) |r| r else commit;

    const entry_name = try git.fmtCachePath(allocator, url, commit);
    defer allocator.free(entry_name);

    var entry = try cache.getEntry(entry_name);
    defer entry.deinit();

    const base_path = try std.fs.path.join(allocator, &.{
        ".gyro",
        entry_name,
        "pkg",
    });
    defer allocator.free(base_path);

    if (!try entry.isDone()) {
        if (builtin.target.os.tag != .windows) {
            if (std.fs.cwd().access(base_path, .{})) {
                try std.fs.cwd().deleteTree(base_path);
            } else |_| {}
            // TODO: if base_path exists then deleteTree it
        }

        try git.clone(
            arena,
            url,
            commit,
            base_path,
        );

        try entry.done();
    }

    // if root is not specified then try to read the manifest and find a match
    // for the alias, if no alias is specified then it would have been
    // calculated from the url

    var alias = alias_opt;
    var root = root_opt;
    if (root) |r| {
        const root_path = try std.fs.path.join(allocator, &.{ base_path, r });
        defer allocator.free(root_path);

        std.fs.cwd().access(root_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.err("the path '{s}' does not exist in {s}", .{ r, url });
                return error.Explained;
            },
            else => return err,
        };

        if (alias != null)
            return Dependency{
                .alias = alias.?,
                .src = .{
                    .git = .{
                        .url = url,
                        .ref = ref,
                        .root = root.?,
                    },
                },
            };
    }

    var base_dir = try std.fs.cwd().openDir(base_path, .{});
    defer base_dir.close();

    const project_file = try base_dir.createFile("gyro.zzz", .{
        .read = true,
        .truncate = false,
        .exclusive = false,
    });
    defer project_file.close();

    const text = try project_file.reader().readAllAlloc(
        arena.allocator(),
        std.math.maxInt(usize),
    );
    const project = try Project.fromUnownedText(arena, base_path, text);
    defer project.destroy();

    if (project.packages.count() == 1) {
        const pkg_entry = project.packages.iterator().next().?;
        if (alias == null)
            alias = pkg_entry.key_ptr.*;

        if (root == null)
            root = pkg_entry.value_ptr.root orelse utils.default_root;

        return Dependency{
            .alias = alias.?,
            .src = .{
                .git = .{
                    .url = url,
                    .ref = ref,
                    .root = root.?,
                },
            },
        };
    }

    if (project.packages.count() == 0 and root == null) {
        std.log.err("this repo has no advertised packages, you need to manually specify the root path with '--root' or '-r'", .{});
        return error.Explained;
    }

    // TODO: if no alias, print error about ambiguity
    if (alias == null and root == null) {
        std.log.err("this repo advertises multiple packages, you must choose an alias:", .{});
        var it = project.packages.iterator();
        while (it.next()) |pkgs_entry| {
            const pkg_root = pkgs_entry.value_ptr.root orelse utils.default_root;
            std.log.err("    {s}: {s}", .{ pkgs_entry.key_ptr.*, pkg_root });
        }

        return error.Explained;
    }

    if (root == null) {
        var iterator = project.packages.iterator();
        while (iterator.next()) |pkgs_entry| {
            if (std.mem.eql(u8, pkgs_entry.key_ptr.*, alias.?)) {
                root = pkgs_entry.value_ptr.root orelse utils.default_root;
                break;
            }
        } else {
            std.log.err("failed to find package that matched the alias '{s}', the advertised packages are:", .{alias});
            var it = project.packages.iterator();
            while (it.next()) |pkgs_entry| {
                const pkg_root = pkgs_entry.value_ptr.root orelse utils.default_root;
                std.log.err("    {s}: {s}", .{ pkgs_entry.key_ptr.*, pkg_root });
            }

            return error.Explained;
        }
    }

    if (alias == null) {
        const url_z = try arena.allocator().dupeZ(u8, url);
        const curl_url = try curl.Url.init();
        defer curl_url.cleanup();

        try curl_url.set(url_z);
        alias = std.fs.path.basename(std.mem.span(try curl_url.getPath()));
        const ext = std.fs.path.extension(alias.?);
        alias = try utils.normalizeName(alias.?[0 .. alias.?.len - ext.len]);

        if (alias.?.len == 0) {
            std.log.err("failed to figure out an alias from the url, please manually specify it with '--alias' or '-a'", .{});
            return error.Explained;
        }
    }

    return Dependency{
        .alias = alias.?,
        .src = .{
            .git = .{
                .url = url,
                .ref = ref,
                .root = root.?,
            },
        },
    };
}

pub fn add(
    allocator: Allocator,
    src_tag: Dependency.SourceType,
    alias: ?[]const u8,
    build_deps: bool,
    ref: ?[]const u8,
    root_path: ?[]const u8,
    repository_opt: ?[]const u8,
    target: []const u8,
) !void {
    switch (src_tag) {
        .pkg, .github, .local, .git => {},
        else => return error.Todo,
    }

    const repository = repository_opt orelse utils.default_repo;
    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().createFile("gyro.zzz", .{
        .truncate = false,
        .read = true,
        .exclusive = false,
    });
    defer file.close();

    var project = try Project.fromFile(&arena, ".", file);
    defer project.destroy();

    const dep_list = if (build_deps)
        &project.build_deps
    else
        &project.deps;

    const dep = switch (src_tag) {
        .github => blk: {
            const info = try utils.parseUserRepo(target);
            const url = try std.fmt.allocPrint(arena.allocator(), "https://github.com/{s}/{s}.git", .{
                info.user,
                info.repo,
            });

            break :blk try gitDependency(&arena, url, alias, ref, root_path);
        },
        .git => try gitDependency(&arena, target, alias, ref, root_path),
        .pkg => blk: {
            const info = try utils.parseUserRepo(target);
            const latest = try api.getLatest(arena.allocator(), repository, info.user, info.repo, null);
            var buf = try arena.allocator().alloc(u8, 80);
            var stream = std.io.fixedBufferStream(buf);
            try stream.writer().print("^{}", .{latest});

            try verifyUniqueAlias(info.repo, dep_list.items);

            break :blk Dependency{
                .alias = info.repo,
                .src = .{
                    .pkg = .{
                        .user = info.user,
                        .name = info.repo,
                        .version = version.Range{
                            .min = latest,
                            .kind = .caret,
                        },
                        .repository = repository,
                    },
                },
            };
        },
        .local => blk: {
            const subproject = try Project.fromDirPath(&arena, target);
            defer subproject.destroy();

            const name = alias orelse try utils.normalizeName(std.fs.path.basename(target));
            try verifyUniqueAlias(name, dep_list.items);

            const root = root_path orelse
                if (try subproject.findBestMatchingPackage(name)) |pkg|
                pkg.root orelse utils.default_root
            else
                utils.default_root;

            break :blk Dependency{
                .alias = name,
                .src = .{
                    .local = .{
                        .path = target,
                        .root = root,
                    },
                },
            };
        },
        else => return error.Todo,
    };

    for (dep_list.items) |d| {
        if (std.mem.eql(u8, d.alias, dep.alias)) {
            std.log.err("alias '{s}' is already being used", .{dep.alias});
            return error.Explained;
        }
    }

    try dep_list.append(dep);
    try project.toFile(file);
}

pub fn rm(
    allocator: Allocator,
    build_deps: bool,
    targets: []const []const u8,
) !void {
    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().createFile("gyro.zzz", .{
        .truncate = false,
        .read = true,
        .exclusive = false,
    });
    defer file.close();

    var project = try Project.fromFile(&arena, ".", file);
    defer project.destroy();

    const dep_list = if (build_deps)
        &project.build_deps
    else
        &project.deps;

    // make sure targets are unique
    for (targets) |_, i| {
        var j: usize = i + 1;
        while (j < targets.len) : (j += 1) {
            if (std.mem.eql(u8, targets[i], targets[j])) {
                std.log.err("duplicated target: {s}", .{targets[i]});
                return error.Explained;
            }
        }
    }

    // ensure all targets are valid
    for (targets) |target| {
        for (dep_list.items) |dep| {
            if (std.mem.eql(u8, target, dep.alias)) break;
        } else {
            std.log.err("{s} is not a dependency", .{target});

            return error.Explained;
        }
    }

    // remove targets
    for (targets) |target| {
        for (dep_list.items) |dep, i| {
            if (std.mem.eql(u8, target, dep.alias)) {
                _ = dep_list.swapRemove(i);
                break;
            }
        }
    }

    try project.toFile(file);
}

pub fn publish(allocator: Allocator, repository: ?[]const u8, pkg: ?[]const u8) anyerror!void {
    const client_id = "ea14bba19a49f4cba053";
    const scope = "read:user user:email";

    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    const file = std.fs.cwd().openFile("gyro.zzz", .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("missing gyro.zzz file", .{});
            return error.Explained;
        } else return err;
    };
    defer file.close();

    var project = try Project.fromFile(&arena, ".", file);
    defer project.destroy();

    if (project.packages.count() == 0) {
        std.log.err("there are no packages to publish!", .{});
        return error.Explained;
    }

    validateNoRedirects(allocator) catch |e| switch (e) {
        error.RedirectsExist => {
            std.log.err("you need to clear redirects before publishing with 'gyro redirect --clean'", .{});
            return error.Explained;
        },
        else => return e,
    };

    const name = if (pkg) |p| blk: {
        if (!project.contains(p)) {
            std.log.err("{s} is not a package", .{p});
            return error.Explained;
        }

        break :blk p;
    } else if (project.packages.count() == 1)
        project.iterator().next().?.name
    else {
        std.log.err("there are multiple packages exported, choose one", .{});
        return error.Explained;
    };

    var access_token: ?[]const u8 = std.process.getEnvVarOwned(allocator, "GYRO_ACCESS_TOKEN") catch |err| blk: {
        if (err == error.EnvironmentVariableNotFound)
            break :blk null
        else
            return err;
    };
    defer if (access_token) |at| allocator.free(at);

    const from_env = access_token != null;
    if (access_token == null) {
        access_token = blk: {
            var dir = if (try known_folders.open(allocator, .cache, .{ .access_sub_paths = true })) |d|
                d
            else
                break :blk null;
            defer dir.close();

            const cache_file = dir.openFile("gyro-access-token", .{}) catch |err| {
                if (err == error.FileNotFound)
                    break :blk null
                else
                    return err;
            };
            defer cache_file.close();

            break :blk try cache_file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
        };
    }

    if (access_token == null) {
        const open_program: []const u8 = switch (builtin.os.tag) {
            .windows => "explorer",
            .macos => "open",
            else => "xdg-open",
        };
        var browser = std.ChildProcess.init(&.{ open_program, "https://github.com/login/device" }, allocator);

        _ = browser.spawnAndWait() catch {
            try std.io.getStdErr().writer().print("Failed to open your browser, please go to https://github.com/login/device", .{});
        };

        var device_code_resp = try api.postDeviceCode(allocator, client_id, scope);
        defer std.json.parseFree(api.DeviceCodeResponse, device_code_resp, .{ .allocator = allocator });

        const stderr = std.io.getStdErr().writer();
        try stderr.print("enter this code: {s}\nwaiting for github authentication...\n", .{device_code_resp.user_code});

        const end_time = device_code_resp.expires_in + @intCast(u64, std.time.timestamp());
        const interval_ns = device_code_resp.interval * std.time.ns_per_s;
        access_token = while (std.time.timestamp() < end_time) : (std.time.sleep(interval_ns)) {
            if (try api.pollDeviceCode(allocator, client_id, device_code_resp.device_code)) |resp| {
                if (try known_folders.open(allocator, .cache, .{ .access_sub_paths = true })) |*dir| {
                    defer dir.close();

                    const cache_file = try dir.createFile("gyro-access-token", .{ .truncate = true });
                    defer cache_file.close();

                    try cache_file.writer().writeAll(resp);
                }

                break resp;
            }
        } else {
            std.log.err("timed out device polling", .{});
            return error.Explained;
        };
    }

    if (access_token == null) {
        std.log.err("failed to get access token", .{});
        return error.Explained;
    }

    api.postPublish(allocator, repository, access_token.?, project.get(name).?) catch |err| switch (err) {
        error.Unauthorized => {
            if (from_env) {
                std.log.err("the access token from the env var 'GYRO_ACCESS_TOKEN' is using an outdated format for github. You need to get a new one.", .{});
                return error.Explained;
            }
            std.log.info("looks like you were using an old token, deleting your cached one.", .{});
            if (try known_folders.open(allocator, .cache, .{ .access_sub_paths = true })) |*dir| {
                defer dir.close();
                try dir.deleteFile("gyro-access-token");
            }

            std.log.info("getting you a new token...", .{});
            try publish(allocator, repository, pkg);
        },
        else => return err,
    };
}

fn validateDepsAliases(redirected_deps: []const Dependency, project_deps: []const Dependency) !void {
    for (redirected_deps) |redirected_dep| {
        for (project_deps) |project_dep| {
            if (std.mem.eql(u8, redirected_dep.alias, project_dep.alias)) break;
        } else {
            std.log.err("'{s}' redirect does not exist in project dependencies", .{redirected_dep.alias});
            return error.Explained;
        }
    }
}

fn moveDeps(redirected_deps: []const Dependency, project_deps: []Dependency) !void {
    for (redirected_deps) |redirected_dep| {
        for (project_deps) |*project_dep| {
            if (std.mem.eql(u8, redirected_dep.alias, project_dep.alias)) {
                project_dep.* = redirected_dep;
                break;
            }
        } else unreachable;
    }
}

/// make sure there are no entries in the redirect file
fn validateNoRedirects(allocator: Allocator) !void {
    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    var gyro_dir = try std.fs.cwd().makeOpenPath(".gyro", .{});
    defer gyro_dir.close();

    const redirect_file = try gyro_dir.createFile("redirects", .{
        .truncate = false,
        .read = true,
    });
    defer redirect_file.close();

    var redirects = try Project.fromFile(&arena, ".", redirect_file);
    defer redirects.destroy();

    if (redirects.deps.items.len > 0 or redirects.build_deps.items.len > 0) {
        return error.RedirectsExist;
    }
}

pub fn redirect(
    allocator: Allocator,
    check: bool,
    clean: bool,
    build_dep: bool,
    alias_opt: ?[]const u8,
    path_opt: ?[]const u8,
) !void {
    const do_redirect = alias_opt != null or path_opt != null;
    if ((check and clean) or
        (check and do_redirect) or
        (clean and do_redirect))
    {
        std.log.err("you can only one at a time: clean, check, or redirect", .{});
        return error.Explained;
    }

    var arena = ThreadSafeArenaAllocator.init(allocator);
    defer arena.deinit();

    const project_file = try std.fs.cwd().openFile("gyro.zzz", .{ .mode = .read_write });
    defer project_file.close();

    var gyro_dir = try std.fs.cwd().makeOpenPath(".gyro", .{});
    defer gyro_dir.close();

    const redirect_file = try gyro_dir.createFile("redirects", .{
        .truncate = false,
        .read = true,
    });
    defer redirect_file.close();

    var project = try Project.fromFile(&arena, ".", project_file);
    defer project.destroy();

    var redirects = try Project.fromFile(&arena, ".", redirect_file);
    defer redirects.destroy();

    if (check) {
        if (redirects.deps.items.len > 0 or redirects.build_deps.items.len > 0) {
            std.log.err("there are gyro redirects", .{});
            return error.Explained;
        } else return;
    } else if (clean) {
        try validateDepsAliases(redirects.deps.items, project.deps.items);
        try validateDepsAliases(redirects.build_deps.items, project.build_deps.items);

        try moveDeps(redirects.deps.items, project.deps.items);
        try moveDeps(redirects.build_deps.items, project.build_deps.items);

        redirects.deps.clearRetainingCapacity();
        redirects.build_deps.clearRetainingCapacity();
    } else {
        const alias = alias_opt orelse {
            std.log.err("missing alias argument", .{});
            return error.Explained;
        };

        const path = path_opt orelse {
            std.log.err("missing path argument", .{});
            return error.Explained;
        };

        const deps = if (build_dep) &project.build_deps else &project.deps;
        const dep = for (deps.items) |*d| {
            if (std.mem.eql(u8, d.alias, alias)) break d;
        } else {
            const deps_type = if (build_dep) "build dependencies" else "dependencies";
            std.log.err("Failed to find '{s}' in {s}", .{ alias, deps_type });
            return error.Explained;
        };

        const redirect_deps = if (build_dep) &redirects.build_deps else &redirects.deps;
        for (redirect_deps.items) |d| if (std.mem.eql(u8, d.alias, alias)) {
            std.log.err("'{s}' is already redirected", .{alias});
            return error.Explained;
        };

        try redirect_deps.append(dep.*);
        const root = switch (dep.src) {
            .pkg => |pkg| blk: {
                var local_project = try Project.fromDirPath(&arena, path);
                defer local_project.destroy();

                const result = local_project.packages.get(pkg.name) orelse {
                    std.log.err("the project located in {s} doesn't export '{s}'", .{
                        path,
                        alias,
                    });
                    return error.Explained;
                };

                // TODO: the orelse here should probably be an error
                break :blk try arena.allocator().dupe(u8, result.root orelse utils.default_root);
            },
            .github => |github| github.root,
            .git => |git| git.root,
            .url => |url| url.root,
            .local => |local| local.root,
        };

        dep.* = Dependency{
            .alias = alias,
            .src = .{
                .local = .{
                    .path = path,
                    .root = root,
                },
            },
        };
    }

    try redirects.toFile(redirect_file);
    try project.toFile(project_file);
}
