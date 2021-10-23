const std = @import("std");
const uri = @import("uri");
const api = @import("api.zig");
const cache = @import("cache.zig");
const Engine = @import("Engine.zig");
const Dependency = @import("Dependency.zig");
const Project = @import("Project.zig");
const utils = @import("utils.zig");
const local = @import("local.zig");

const c = @cImport({
    @cInclude("git2.h");
});

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const name = "git";
pub const Resolution = []const u8;
pub const ResolutionEntry = struct {
    url: []const u8,
    ref: []const u8,
    commit: []const u8,
    root: []const u8,
    dep_idx: ?usize = null,

    pub fn format(
        entry: ResolutionEntry,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;

        try writer.print("{s}:{s}/{s} -> {}", .{
            entry.url,
            entry.commit,
            entry.root,
            entry.dep_idx,
        });
    }
};
pub const FetchError =
    @typeInfo(@typeInfo(@TypeOf(getHeadCommit)).Fn.return_type.?).ErrorUnion.error_set ||
    @typeInfo(@typeInfo(@TypeOf(fetch)).Fn.return_type.?).ErrorUnion.error_set;

const FetchQueue = Engine.MultiQueueImpl(Resolution, FetchError);
const ResolutionTable = std.ArrayListUnmanaged(ResolutionEntry);

pub fn deserializeLockfileEntry(
    allocator: *Allocator,
    it: *std.mem.TokenIterator(u8),
    resolutions: *ResolutionTable,
) !void {
    try resolutions.append(allocator, .{
        .url = it.next() orelse return error.Url,
        .ref = it.next() orelse return error.NoRef,
        .root = it.next() orelse return error.NoRoot,
        .commit = it.next() orelse return error.NoCommit,
    });
}

pub fn serializeResolutions(
    resolutions: []const ResolutionEntry,
    writer: anytype,
) !void {
    for (resolutions) |entry| {
        if (entry.dep_idx != null)
            try writer.print("git {s} {s} {s} {s}\n", .{
                entry.url,
                entry.ref,
                entry.root,
                entry.commit,
            });
    }
}

fn findResolution(
    dep: Dependency.Source,
    resolutions: []const ResolutionEntry,
) ?usize {
    const root = dep.git.root orelse utils.default_root;
    return for (resolutions) |entry, j| {
        if (std.mem.eql(u8, dep.git.url, entry.url) and
            std.mem.eql(u8, dep.git.ref, entry.ref) and
            std.mem.eql(u8, root, entry.root))
        {
            break j;
        }
    } else null;
}

fn findMatch(
    dep_table: []const Dependency.Source,
    dep_idx: usize,
    edges: []const Engine.Edge,
) ?usize {
    const dep = dep_table[dep_idx].git;
    const root = dep.root orelse utils.default_root;
    return for (edges) |edge| {
        const other = dep_table[edge.to].git;
        const other_root = other.root orelse utils.default_root;
        if (std.mem.eql(u8, dep.url, other.url) and
            std.mem.eql(u8, dep.ref, other.ref) and
            std.mem.eql(u8, root, other_root))
        {
            break edge.to;
        }
    } else null;
}

const RemoteHeadEntry = struct {
    oid: [c.GIT_OID_HEXSZ]u8,
    name: []const u8,
};

fn getHeadCommit(
    allocator: *Allocator,
    url: []const u8,
    ref: []const u8,
) ![]const u8 {
    // if ref is the same size as an OID and hex format then treat it as a
    // commit
    if (ref.len == c.GIT_OID_HEXSZ) {
        for (ref) |char| {
            if (!std.ascii.isXDigit(char))
                break;
        } else return allocator.dupe(u8, ref);
    }

    const url_z = try std.mem.dupeZ(allocator, u8, url);
    defer allocator.free(url_z);

    var remote: ?*c.git_remote = null;
    var err = c.git_remote_create_anonymous(&remote, null, url_z);
    if (err < 0) {
        const last_error = c.git_error_last();
        std.log.err("{s}", .{last_error.*.message});
        return error.GitRemoteCreate;
    }
    defer c.git_remote_free(remote);

    var callbacks: c.git_remote_callbacks = undefined;
    err = c.git_remote_init_callbacks(
        &callbacks,
        c.GIT_REMOTE_CALLBACKS_VERSION,
    );
    if (err < 0) {
        const last_error = c.git_error_last();
        std.log.err("{s}", .{last_error.*.message});
        return error.GitRemoteInitCallbacks;
    }

    err = c.git_remote_connect(
        remote,
        c.GIT_DIRECTION_FETCH,
        &callbacks,
        null,
        null,
    );
    if (err < 0) {
        const last_error = c.git_error_last();
        std.log.err("{s}", .{last_error.*.message});
        return error.GitRemoteConnect;
    }

    var refs_ptr: [*c][*c]c.git_remote_head = undefined;
    var refs_len: usize = undefined;
    err = c.git_remote_ls(&refs_ptr, &refs_len, remote);
    if (err < 0) {
        const last_error = c.git_error_last();
        std.log.err("{s}", .{last_error.*.message});
        return error.GitRemoteLs;
    }

    var refs = std.ArrayList(RemoteHeadEntry).init(allocator);
    defer {
        for (refs.items) |entry|
            allocator.free(entry.name);

        refs.deinit();
    }

    var i: usize = 0;
    while (i < refs_len) : (i += 1) {
        const len = std.mem.lenZ(refs_ptr[i].*.name);
        try refs.append(.{
            .oid = undefined,
            .name = try allocator.dupeZ(u8, refs_ptr[i].*.name[0..len]),
        });

        _ = c.git_oid_fmt(
            &refs.items[refs.items.len - 1].oid,
            &refs_ptr[i].*.oid,
        );
    }

    inline for (&[_][]const u8{ "refs/tags/", "refs/heads/" }) |prefix| {
        for (refs.items) |entry| {
            if (std.mem.startsWith(u8, entry.name, prefix) and
                std.mem.eql(u8, entry.name[prefix.len..], ref))
            {
                return allocator.dupe(u8, &entry.oid);
            }
        }
    }

    std.log.err("'{s}' ref not found", .{ref});
    return error.RefNotFound;
}

const CloneState = struct {
    allocator: *Allocator,
    base_path: []const u8,
};

fn submoduleCb(sm: ?*c.git_submodule, sm_name: [*c]const u8, payload: ?*c_void) callconv(.C) c_int {
    return if (submoduleCbImpl(sm, sm_name, payload)) 0 else |_| -1;
}

fn submoduleCbImpl(sm: ?*c.git_submodule, sm_name: [*c]const u8, payload: ?*c_void) !void {
    const parent_state = @ptrCast(*CloneState, @alignCast(@alignOf(*CloneState), payload));
    const allocator = parent_state.allocator;
    const base_path = try std.fs.path.join(allocator, &.{ parent_state.base_path, std.mem.spanZ(sm_name) });
    defer allocator.free(base_path);

    var state = CloneState{
        .allocator = allocator,
        .base_path = base_path,
    };

    std.log.info("cloning submodule: {s}", .{c.git_submodule_url(sm)});
    var options: c.git_submodule_update_options = undefined;
    _ = c.git_submodule_update_options_init(&options, c.GIT_SUBMODULE_UPDATE_OPTIONS_VERSION);

    var err = c.git_submodule_update(sm, 1, &options);
    if (err != 0)
        return error.GitSubmoduleUpdate;

    var repo: ?*c.git_repository = null;
    err = c.git_submodule_open(&repo, sm);
    if (err != 0)
        return error.GitSubmoduleOpen;
    defer c.git_repository_free(repo);

    err = c.git_submodule_foreach(repo, submoduleCb, &state);
    if (err != 0) {
        std.log.err("{s}", .{c.git_error_last().*.message});
        return error.GitSubmoduleForeach;
    }
}

fn clone(
    allocator: *Allocator,
    url: []const u8,
    commit: []const u8,
    path: []const u8,
) !void {
    std.log.info("cloning {s}: {s}", .{ url, commit });

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const commit_z = try allocator.dupeZ(u8, commit);
    defer allocator.free(commit_z);

    var repo: ?*c.git_repository = null;
    var options: c.git_clone_options = undefined;
    _ = c.git_clone_options_init(&options, c.GIT_CLONE_OPTIONS_VERSION);

    var err = c.git_clone(&repo, url_z, path_z, &options);
    if (err != 0) {
        std.log.err("{s}", .{c.git_error_last().*.message});
        return error.GitClone;
    }
    defer c.git_repository_free(repo);

    var oid: c.git_oid = undefined;
    err = c.git_oid_fromstr(&oid, commit_z);
    if (err != 0) {
        std.log.err("{s}", .{c.git_error_last().*.message});
        return error.GitOidFromString;
    }

    var obj: ?*c.git_object = undefined;
    err = c.git_object_lookup(&obj, repo, &oid, c.GIT_OBJECT_COMMIT);
    if (err != 0) {
        std.log.err("{s}", .{c.git_error_last().*.message});
        return error.GitObjectLookup;
    }

    var checkout_opts: c.git_checkout_options = undefined;
    _ = c.git_checkout_options_init(&checkout_opts, c.GIT_CHECKOUT_OPTIONS_VERSION);
    err = c.git_checkout_tree(repo, obj, &checkout_opts);
    if (err != 0) {
        std.log.err("{s}", .{c.git_error_last().*.message});
        return error.GitCheckoutTree;
    }

    var state = CloneState{
        .allocator = allocator,
        .base_path = path,
    };

    err = c.git_submodule_foreach(repo, submoduleCb, &state);
    if (err != 0) {
        std.log.err("{s}", .{c.git_error_last().*.message});
        return error.GitSubmoduleForeach;
    }
}

fn findPartialMatch(
    allocator: *Allocator,
    dep_table: []const Dependency.Source,
    commit: []const u8,
    dep_idx: usize,
    edges: []const Engine.Edge,
) !?usize {
    const dep = dep_table[dep_idx].git;
    return for (edges) |edge| {
        const other = dep_table[edge.to].git;
        if (std.mem.eql(u8, dep.url, other.url)) {
            const other_commit = try getHeadCommit(
                allocator,
                other.url,
                other.ref,
            );
            defer allocator.free(other_commit);

            if (std.mem.eql(u8, commit, other_commit)) {
                break edge.to;
            }
        }
    } else null;
}

fn fetch(
    arena: *std.heap.ArenaAllocator,
    dep: Dependency.Source,
    done: bool,
    commit: Resolution,
    deps: *std.ArrayListUnmanaged(Dependency),
    path: *?[]const u8,
) !void {
    const allocator = arena.child_allocator;

    var components = std.ArrayList([]const u8).init(allocator);
    defer components.deinit();

    const link = try uri.parse(dep.git.url);
    const scheme = link.scheme orelse return error.NoUriScheme;
    const end = dep.git.url.len - if (std.mem.endsWith(u8, dep.git.url, ".git"))
        ".git".len
    else
        0;

    var it = std.mem.tokenize(u8, dep.git.url[scheme.len + 1 .. end], "/");
    while (it.next()) |comp|
        try components.insert(0, comp);

    try components.append(commit[0..8]);
    const entry_name = try std.mem.join(allocator, "-", components.items);
    defer allocator.free(entry_name);

    var entry = try cache.getEntry(entry_name);
    defer entry.deinit();

    const base_path = try std.fs.path.join(allocator, &.{
        ".gyro",
        entry_name,
        "pkg",
    });
    defer allocator.free(base_path);

    if (!done and !try entry.isDone()) {
        try clone(
            allocator,
            dep.git.url,
            commit,
            base_path,
        );

        try entry.done();
    }

    const root = dep.git.root orelse utils.default_root;
    path.* = try utils.joinPathConvertSep(arena, &.{ base_path, root });

    if (!done) {
        var base_dir = try std.fs.cwd().openDir(base_path, .{});
        defer base_dir.close();

        const project_file = try base_dir.createFile("gyro.zzz", .{
            .read = true,
            .truncate = false,
            .exclusive = false,
        });
        defer project_file.close();

        const text = try project_file.reader().readAllAlloc(
            &arena.allocator,
            std.math.maxInt(usize),
        );
        const project = try Project.fromUnownedText(allocator, base_path, text);
        defer {
            project.transferToArena(arena);
            project.destroy();
        }

        try deps.appendSlice(allocator, project.deps.items);
    }
}

pub fn dedupeResolveAndFetch(
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) void {
    dedupeResolveAndFetchImpl(
        dep_table,
        resolutions,
        fetch_queue,
        i,
    ) catch |err| {
        fetch_queue.items(.result)[i] = .{ .err = err };
    };
}

fn dedupeResolveAndFetchImpl(
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) FetchError!void {
    const arena = &fetch_queue.items(.arena)[i];
    const dep_idx = fetch_queue.items(.edge)[i].to;

    var commit: []const u8 = undefined;
    if (findResolution(dep_table[dep_idx], resolutions)) |res_idx| {
        if (resolutions[res_idx].dep_idx) |idx| {
            fetch_queue.items(.result)[i] = .{
                .replace_me = idx,
            };

            return;
        } else if (findMatch(
            dep_table,
            dep_idx,
            fetch_queue.items(.edge)[0..i],
        )) |idx| {
            fetch_queue.items(.result)[i] = .{
                .replace_me = idx,
            };

            return;
        } else {
            fetch_queue.items(.result)[i] = .{
                .fill_resolution = res_idx,
            };
        }
    } else if (findMatch(
        dep_table,
        dep_idx,
        fetch_queue.items(.edge)[0..i],
    )) |idx| {
        fetch_queue.items(.result)[i] = .{
            .replace_me = idx,
        };

        return;
    } else {
        commit = try getHeadCommit(
            &arena.allocator,
            dep_table[dep_idx].git.url,
            dep_table[dep_idx].git.ref,
        );

        if (try findPartialMatch(
            arena.child_allocator,
            dep_table,
            commit,
            dep_idx,
            fetch_queue.items(.edge)[0..i],
        )) |idx| {
            std.log.err("found partial match: {}", .{idx});
            fetch_queue.items(.result)[i] = .{
                .copy_deps = idx,
            };
        } else {
            fetch_queue.items(.result)[i] = .{
                .new_entry = commit,
            };
        }
    }

    var done = false;
    const resolution = switch (fetch_queue.items(.result)[i]) {
        .fill_resolution => |res_idx| resolutions[res_idx].commit,
        .new_entry => |entry_commit| entry_commit,
        .copy_deps => blk: {
            done = true;
            break :blk commit;
        },
        else => unreachable,
    };

    try fetch(
        arena,
        dep_table[dep_idx],
        done,
        resolution,
        &fetch_queue.items(.deps)[i],
        &fetch_queue.items(.path)[i],
    );

    assert(fetch_queue.items(.path)[i] != null);
}

pub fn updateResolution(
    allocator: *Allocator,
    resolutions: *ResolutionTable,
    dep_table: []const Dependency.Source,
    fetch_queue: *FetchQueue,
    i: usize,
) !void {
    switch (fetch_queue.items(.result)[i]) {
        .fill_resolution => |res_idx| {
            const dep_idx = fetch_queue.items(.edge)[i].to;
            assert(resolutions.items[res_idx].dep_idx == null);
            resolutions.items[res_idx].dep_idx = dep_idx;
        },
        .new_entry => |commit| {
            const dep_idx = fetch_queue.items(.edge)[i].to;
            const git = &dep_table[dep_idx].git;
            const root = git.root orelse utils.default_root;
            try resolutions.append(allocator, .{
                .url = git.url,
                .ref = git.ref,
                .root = root,
                .commit = commit,
                .dep_idx = dep_idx,
            });
        },
        .replace_me => |dep_idx| fetch_queue.items(.edge)[i].to = dep_idx,
        .err => |err| {
            std.log.err("recieved error: {s} while getting dep: {}", .{
                @errorName(err),
                dep_table[fetch_queue.items(.edge)[i].to],
            });
            return error.Explained;
        },
        .copy_deps => |queue_idx| {
            std.log.err("queue_idx: {}", .{queue_idx});
            const commit = resolutions.items[
                findResolution(
                    dep_table[fetch_queue.items(.edge)[queue_idx].to],
                    resolutions.items,
                ).?
            ].commit;

            const dep_idx = fetch_queue.items(.edge)[i].to;
            const git = &dep_table[dep_idx].git;
            const root = git.root orelse utils.default_root;
            try resolutions.append(allocator, .{
                .url = git.url,
                .ref = git.ref,
                .root = root,
                .commit = commit,
                .dep_idx = dep_idx,
            });

            try fetch_queue.items(.deps)[i].appendSlice(
                allocator,
                fetch_queue.items(.deps)[queue_idx].items,
            );
        },
    }
}
