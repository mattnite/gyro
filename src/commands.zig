const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const version = @import("version");
const zzz = @import("zzz");
const known_folders = @import("known-folders");
const build_options = @import("build_options");
const api = @import("api.zig");
const Project = @import("Project.zig");
const Lockfile = @import("Lockfile.zig");
const Dependency = @import("Dependency.zig");
const DependencyTree = @import("DependencyTree.zig");
usingnamespace @import("common.zig");

const Allocator = std.mem.Allocator;

const FetchContext = struct {
    project_file: std.fs.File,
    lock_file: std.fs.File,

    project: *Project,
    lockfile: Lockfile,
    dep_tree: *DependencyTree,
    build_dep_tree: *DependencyTree,

    fn deinit(self: *FetchContext) void {
        self.lockfile.save(self.lock_file) catch {};
        self.build_dep_tree.destroy();
        self.dep_tree.destroy();
        self.lockfile.deinit();
        self.project.destroy();

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
    errdefer project.destroy();

    var lockfile = try Lockfile.fromFile(allocator, lock_file);
    errdefer lockfile.deinit();

    const dep_tree = try DependencyTree.generate(
        allocator,
        &lockfile,
        project,
        false,
    );
    errdefer dep_tree.destroy();

    const build_dep_tree = try DependencyTree.generate(
        allocator,
        &lockfile,
        project,
        true,
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

pub fn update(
    allocator: *Allocator,
    in: ?[]const u8,
    targets: []const []const u8,
) !void {
    if (in != null or targets.len > 0) {
        return error.Todo;
    }

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

    // TODO: configurable local cache
    const pkgs = try ctx.build_dep_tree.assemblePkgs(std.build.Pkg{
        .name = "gyro",
        .path = "deps.zig",
    });

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

    b.resolveInstallPrefix(null);
    const runner = b.addExecutable("build", "build_runner.zig");
    runner.addPackage(std.build.Pkg{
        .name = "@build",
        .path = "build.zig",
        .dependencies = pkgs,
    });

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
    defer project.destroy();

    if (project.packages.count() == 0) {
        std.log.err("there are no packages to package!", .{});
        return error.Explained;
    }

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
    allocator: *Allocator,
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

    const info = try parseUserRepo(link orelse return);

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
    , .{try normalizeName(info.repo)});

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
fn verifyUniqueAlias(alias: []const u8, deps: []const Dependency, to: ?[]const u8) !void {
    for (deps) |dep| {
        if (std.mem.eql(u8, alias, dep.alias)) {
            if (to) |t|
                std.log.err("The alias '{s}' is already in use for a subdependency of '{s}'", .{
                    alias,
                    t,
                })
            else
                std.log.err("The alias '{s}' is already in use for this project", .{alias});
            return error.Explained;
        }
    }
}

pub fn add(
    allocator: *Allocator,
    src_tag: Dependency.SourceType,
    alias: ?[]const u8,
    build_deps: bool,
    root_path: ?[]const u8,
    to: ?[]const u8,
    targets: []const []const u8,
) !void {
    switch (src_tag) {
        .pkg, .github, .local => {},
        else => return error.Todo,
    }

    // TODO: detect collisions in subpackages (both directions)
    const repository = build_options.default_repo;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().createFile("gyro.zzz", .{
        .truncate = false,
        .read = true,
        .exclusive = false,
    });
    defer file.close();

    var project = try Project.fromFile(allocator, file);
    defer project.destroy();

    const dep_list = if (to) |t|
        if (project.packages.getEntry(t)) |entry| &entry.value_ptr.deps else {
            std.log.err("{s} is not a an exported package", .{t});
            return error.Explained;
        }
    else if (build_deps)
        &project.build_deps
    else
        &project.deps;

    // TODO: handle user/pkg in targets

    // make sure targets are unique
    for (targets[0 .. targets.len - 1]) |_, i| {
        for (targets[i + 1 ..]) |_, j| {
            if (std.mem.eql(u8, targets[i], targets[j])) {
                std.log.err("duplicated target: {s}", .{targets[i]});
                return error.Explained;
            }
        }
    }

    // ensure all targets are valid
    for (targets) |target| {
        for (dep_list.items) |dep| {
            if (std.mem.eql(u8, target, dep.alias)) {
                if (to) |t|
                    std.log.err("{s} is already a dependency of {s}", .{ target, t })
                else
                    std.log.err("{s} is already a dependency", .{target});
                return error.Explained;
            }
        }
    }

    for (targets) |target| {
        const info = try parseUserRepo(target);
        const dep = switch (src_tag) {
            .github => blk: {
                var value_tree = try api.getGithubRepo(&arena.allocator, info.user, info.repo);
                if (value_tree.root != .Object) {
                    std.log.err("Invalid JSON response from Github", .{});
                    return error.Explained;
                }

                const root_json = value_tree.root.Object;
                const default_branch = if (root_json.get("default_branch")) |val| switch (val) {
                    .String => |str| str,
                    else => "main",
                } else "main";

                const text_opt = try api.getGithubGyroFile(
                    &arena.allocator,
                    info.user,
                    info.repo,
                    try api.getHeadCommit(&arena.allocator, info.user, info.repo, default_branch),
                );

                const root_file = if (root_path) |rp| rp else if (text_opt) |t| get_root: {
                    const subproject = try Project.fromText(&arena.allocator, t);
                    defer subproject.destroy();

                    var ret: []const u8 = default_root;
                    if (subproject.packages.count() == 1)
                        ret = if (subproject.packages.iterator().next().?.value_ptr.root) |r|
                            try arena.allocator.dupe(u8, r)
                        else
                            default_root;

                    // TODO try other matching methods

                    break :get_root ret;
                } else default_root;

                const name = try normalizeName(info.repo);
                try verifyUniqueAlias(name, dep_list.items, to);

                break :blk Dependency{
                    .alias = name,
                    .src = .{
                        .github = .{
                            .user = info.user,
                            .repo = info.repo,
                            .ref = default_branch,
                            .root = root_file,
                        },
                    },
                };
            },
            .pkg => blk: {
                const latest = try api.getLatest(&arena.allocator, repository, info.user, info.repo, null);
                var buf = try arena.allocator.alloc(u8, 80);
                var stream = std.io.fixedBufferStream(buf);
                try stream.writer().print("^{}", .{latest});

                try verifyUniqueAlias(info.repo, dep_list.items, to);

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
                            .repository = build_options.default_repo,
                            .ver_str = stream.getWritten(),
                        },
                    },
                };
            },
            .local => blk: {
                const path = try std.fs.path.join(allocator, &.{ target, "gyro.zzz" });
                defer allocator.free(path);

                const project_file = try std.fs.cwd().openFile(path, .{});
                defer project_file.close();

                const text = try project_file.readToEndAlloc(&arena.allocator, std.math.maxInt(usize));
                const subproject = try Project.fromText(&arena.allocator, text);
                defer subproject.destroy();

                const detected_root = if (subproject.packages.count() == 1)
                    if (subproject.packages.iterator().next().?.value_ptr.root) |r|
                        try arena.allocator.dupe(u8, r)
                    else
                        null
                else
                    null;

                const detected_alias = if (subproject.packages.count() == 1)
                    try arena.allocator.dupe(u8, subproject.packages.iterator().next().?.value_ptr.name)
                else
                    null;

                const a = alias orelse (detected_alias orelse {
                    if (subproject.packages.count() == 0) {
                        std.log.err("no exported packages in '{s}', need an explicit alias, use -a", .{target});
                    } else if (subproject.packages.count() > 1) {
                        std.log.err("don't know which package to use from '{s}', need an explicit alias, use -a", .{target});
                    }

                    return error.Explained;
                });

                try verifyUniqueAlias(a, dep_list.items, to);

                const r = root_path orelse (detected_root orelse root_blk: {
                    std.log.info("no explicit or detected root path for '{s}', using default: " ++ default_root, .{
                        target,
                    });
                    break :root_blk default_root;
                });
                break :blk Dependency{
                    .alias = a,

                    .src = .{
                        .local = .{
                            .path = target,
                            .root = r,
                        },
                    },
                };
            },
            else => return error.Todo,
        };

        try dep_list.append(dep);
    }

    try project.toFile(file);
}

pub fn rm(
    allocator: *Allocator,
    build_deps: bool,
    from: ?[]const u8,
    targets: []const []const u8,
) !void {
    if (build_deps and from != null) {
        std.log.err("packages can't have build subdependencies", .{});
        return error.Explained;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const file = try std.fs.cwd().createFile("gyro.zzz", .{
        .truncate = false,
        .read = true,
        .exclusive = false,
    });
    defer file.close();

    var project = try Project.fromFile(allocator, file);
    defer project.destroy();

    std.log.debug("packages at start: {}", .{project.packages.count()});

    const dep_list = if (from) |f|
        if (project.packages.getEntry(f)) |entry| &entry.value_ptr.deps else {
            std.log.err("{s} is not a an exported package", .{f});
            return error.Explained;
        }
    else if (build_deps)
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
            if (from) |f|
                std.log.err("{s} is not a dependency of {s}", .{ target, f })
            else
                std.log.err("{s} is not a dependency", .{target});

            return error.Explained;
        }
    }

    // remove targets
    for (targets) |target| {
        for (dep_list.items) |dep, i| {
            if (std.mem.eql(u8, target, dep.alias)) {
                std.log.debug("removing target: {s}", .{target});
                _ = dep_list.swapRemove(i);
                break;
            }
        }
    }

    std.log.debug("packages: {}", .{project.packages.count()});

    try project.toFile(file);
}

pub fn publish(allocator: *Allocator, pkg: ?[]const u8) !void {
    const client_id = "ea14bba19a49f4cba053";
    const scope = "read:user user:email";

    const file = std.fs.cwd().openFile("gyro.zzz", .{ .read = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("missing gyro.zzz file", .{});
            return error.Explained;
        } else return err;
    };
    defer file.close();

    var project = try Project.fromFile(allocator, file);
    defer project.destroy();

    if (project.packages.count() == 0) {
        std.log.err("there are no packages to publish!", .{});
        return error.Explained;
    }

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
        var browser = try std.ChildProcess.init(&.{ open_program, "https://github.com/login/device" }, allocator);
        defer browser.deinit();

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

    try api.postPublish(allocator, access_token.?, project.get(name).?);
}
