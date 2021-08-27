const std = @import("std");
const builtin = @import("builtin");
const clap = @import("clap");
const version = @import("version");
const zzz = @import("zzz");
const known_folders = @import("known-folders");
const build_options = @import("build_options");
const api = @import("api.zig");
const Project = @import("Project.zig");
const Dependency = @import("Dependency.zig");
const Engine = @import("Engine.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;

fn assertFileExistsInCwd(subpath: []const u8) !void {
    std.fs.cwd().access(subpath, .{ .read = true }) catch |err| {
        return if (err == error.FileNotFound) blk: {
            std.log.err("no {s} in current working directory", .{subpath});
            break :blk error.Explained;
        } else err;
    };
}

pub fn fetch(allocator: *Allocator) !void {
    try assertFileExistsInCwd("gyro.zzz");

    const project_file = try std.fs.cwd().openFile("gyro.zzz", .{});
    defer project_file.close();

    const project = try Project.fromFile(allocator, project_file);
    defer project.destroy();

    const lockfile = try std.fs.cwd().createFile("gyro.lock", .{
        .read = true,
        .truncate = false,
    });
    defer lockfile.close();

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
    try assertFileExistsInCwd("build.zig");
    try assertFileExistsInCwd("gyro.zzz");

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

    const project_file = try std.fs.cwd().openFile("gyro.zzz", .{});
    defer project_file.close();

    const project = try Project.fromFile(allocator, project_file);
    defer project.destroy();

    const lockfile = try std.fs.cwd().createFile("gyro.lock", .{
        .read = true,
        .truncate = false,
    });
    defer lockfile.close();

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
    const pkgs = try engine.genBuildDeps();
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

    b.resolveInstallPrefix(null, .{});
    const runner = b.addExecutable("build", "build_runner.zig");
    runner.addPackage(std.build.Pkg{
        .name = "@build",
        .path = .{
            .path = "build.zig",
        },
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

pub fn add(
    allocator: *Allocator,
    src_tag: Dependency.SourceType,
    alias: ?[]const u8,
    build_deps: bool,
    root_path: ?[]const u8,
    targets: []const []const u8,
) !void {
    switch (src_tag) {
        .pkg, .github, .local => {},
        else => return error.Todo,
    }

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

    const dep_list = if (build_deps)
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
                std.log.err("{s} is already a dependency", .{target});
                return error.Explained;
            }
        }
    }

    for (targets) |target| {
        const info = try utils.parseUserRepo(target);
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
                    const subproject = try Project.fromUnownedText(&arena.allocator, t);
                    defer subproject.destroy();

                    var ret: []const u8 = utils.default_root;
                    if (subproject.packages.count() == 1)
                        ret = if (subproject.packages.iterator().next().?.value_ptr.root) |r|
                            try arena.allocator.dupe(u8, r)
                        else
                            utils.default_root;

                    // TODO try other matching methods

                    break :get_root ret;
                } else utils.default_root;

                const name = try utils.normalizeName(info.repo);
                try verifyUniqueAlias(name, dep_list.items);

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
                            .repository = build_options.default_repo,
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
                const subproject = try Project.fromUnownedText(&arena.allocator, text);
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

                try verifyUniqueAlias(a, dep_list.items);

                const r = root_path orelse (detected_root orelse root_blk: {
                    std.log.info("no explicit or detected root path for '{s}', using default: " ++ utils.default_root, .{
                        target,
                    });
                    break :root_blk utils.default_root;
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
    targets: []const []const u8,
) !void {
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
fn validateNoRedirects(allocator: *Allocator) !void {
    var gyro_dir = try std.fs.cwd().makeOpenPath(".gyro", .{});
    defer gyro_dir.close();

    const redirect_file = try gyro_dir.createFile("redirects", .{
        .truncate = false,
        .read = true,
    });
    defer redirect_file.close();

    var redirects = try Project.fromFile(allocator, redirect_file);
    defer redirects.destroy();

    if (redirects.deps.items.len > 0 or redirects.build_deps.items.len > 0) {
        return error.RedirectsExist;
    }
}

pub fn redirect(
    allocator: *Allocator,
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

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const project_file = try std.fs.cwd().openFile("gyro.zzz", .{
        .read = true,
        .write = true,
    });
    defer project_file.close();

    var gyro_dir = try std.fs.cwd().makeOpenPath(".gyro", .{});
    defer gyro_dir.close();

    const redirect_file = try gyro_dir.createFile("redirects", .{
        .truncate = false,
        .read = true,
    });
    defer redirect_file.close();

    var project = try Project.fromFile(allocator, project_file);
    defer project.destroy();

    var redirects = try Project.fromFile(allocator, redirect_file);
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
                const local_path = try std.fs.path.resolve(allocator, &.{
                    path,
                    "gyro.zzz",
                });
                defer allocator.free(local_path);

                const local_project_file = try std.fs.openFileAbsolute(local_path, .{});
                defer local_project_file.close();

                var local_project = try Project.fromFile(allocator, local_project_file);
                defer local_project.destroy();

                const result = local_project.packages.get(pkg.name) orelse {
                    std.log.err("the project located in {s} doesn't export '{s}'", .{
                        path,
                        alias,
                    });
                    return error.Explained;
                };
                break :blk try arena.allocator.dupe(u8, result.root orelse "src/main.zig");
            },
            .github => |github| github.root,
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
