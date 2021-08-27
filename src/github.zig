const std = @import("std");
const api = @import("api.zig");
const cache = @import("cache.zig");
const Engine = @import("Engine.zig");
const Dependency = @import("Dependency.zig");
const Project = @import("Project.zig");
const utils = @import("utils.zig");
const local = @import("local.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const name = "github";
pub const Resolution = []const u8;
pub const ResolutionEntry = struct {
    user: []const u8,
    repo: []const u8,
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

        try writer.print("github.com/{s}/{s}:{s}/{s} -> {}", .{
            entry.user,
            entry.repo,
            entry.commit,
            entry.root,
            entry.dep_idx,
        });
    }
};
pub const FetchError = error{Todo} ||
    @typeInfo(@typeInfo(@TypeOf(api.getHeadCommit)).Fn.return_type.?).ErrorUnion.error_set ||
    @typeInfo(@typeInfo(@TypeOf(fetch)).Fn.return_type.?).ErrorUnion.error_set;

const FetchQueue = Engine.MultiQueueImpl(Resolution, FetchError);
const ResolutionTable = std.ArrayListUnmanaged(ResolutionEntry);

pub fn deserializeLockfileEntry(
    allocator: *Allocator,
    it: *std.mem.TokenIterator(u8),
    resolutions: *ResolutionTable,
) !void {
    try resolutions.append(allocator, .{
        .user = it.next() orelse return error.NoUser,
        .repo = it.next() orelse return error.NoRepo,
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
            try writer.print("github {s} {s} {s} {s} {s}\n", .{
                entry.user,
                entry.repo,
                entry.ref,
                entry.root,
                entry.commit,
            });
    }
}

fn findResolution(dep: Dependency.Source, resolutions: []const ResolutionEntry) ?usize {
    const root = dep.github.root orelse utils.default_root;
    return for (resolutions) |entry, j| {
        if (std.mem.eql(u8, dep.github.user, entry.user) and
            std.mem.eql(u8, dep.github.repo, entry.repo) and
            std.mem.eql(u8, dep.github.ref, entry.ref) and
            std.mem.eql(u8, root, entry.root))
        {
            break j;
        }
    } else null;
}

fn findMatch(dep_table: []const Dependency.Source, dep_idx: usize, edges: []const Engine.Edge) ?usize {
    const dep = dep_table[dep_idx].github;
    const root = dep.root orelse utils.default_root;
    return for (edges) |edge| {
        const other = dep_table[edge.to].github;
        const other_root = other.root orelse utils.default_root;
        if (std.mem.eql(u8, dep.user, other.user) and
            std.mem.eql(u8, dep.repo, other.repo) and
            std.mem.eql(u8, dep.ref, other.ref) and
            std.mem.eql(u8, root, other_root))
        {
            break edge.to;
        }
    } else null;
}

fn fetch(
    arena: *std.heap.ArenaAllocator,
    dep: Dependency.Source,
    commit: Resolution,
    deps: *std.ArrayListUnmanaged(Dependency),
    path: *?[]const u8,
) !void {
    const allocator = arena.child_allocator;
    const entry_name = try std.fmt.allocPrint(allocator, "{s}-{s}-github-{s}", .{
        dep.github.repo,
        dep.github.user,
        commit,
    });
    defer allocator.free(entry_name);

    var entry = try cache.getEntry(entry_name);
    defer entry.deinit();

    if (!try entry.isDone()) {
        var content_dir = try entry.contentDir();
        defer content_dir.close();

        try api.getGithubTarGz(
            allocator,
            dep.github.user,
            dep.github.repo,
            commit,
            content_dir,
        );

        try entry.done();
    }

    const base_path = try std.fs.path.join(arena.child_allocator, &.{
        ".gyro",
        entry_name,
        "pkg",
    });
    defer arena.child_allocator.free(base_path);

    const root = dep.github.root orelse utils.default_root;
    path.* = try std.fs.path.join(&arena.allocator, &.{ base_path, root });

    var base_dir = try std.fs.cwd().openDir(base_path, .{});
    defer base_dir.close();

    const project_file = try base_dir.createFile("gyro.zzz", .{
        .read = true,
        .truncate = false,
        .exclusive = false,
    });
    defer project_file.close();

    const text = try project_file.reader().readAllAlloc(&arena.allocator, std.math.maxInt(usize));
    const project = try Project.fromUnownedText(arena.child_allocator, text);
    defer project.destroy();

    try deps.appendSlice(arena.child_allocator, project.deps.items);
    try local.updateBasePaths(arena, base_path, deps);
}

pub fn dedupeResolveAndFetch(
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) FetchError!void {
    const arena = &fetch_queue.items(.arena)[i];
    const dep_idx = fetch_queue.items(.edge)[i].to;
    if (findResolution(dep_table[dep_idx], resolutions)) |res_idx| {
        if (resolutions[res_idx].dep_idx) |idx| {
            fetch_queue.items(.result)[i] = .{
                .replace_me = idx,
            };

            return;
        } else if (findMatch(dep_table, dep_idx, fetch_queue.items(.edge)[0..i])) |idx| {
            fetch_queue.items(.result)[i] = .{
                .replace_me = idx,
            };

            return;
        } else {
            fetch_queue.items(.result)[i] = .{
                .fill_resolution = res_idx,
            };
        }
    } else if (findMatch(dep_table, dep_idx, fetch_queue.items(.edge)[0..i])) |idx| {
        fetch_queue.items(.result)[i] = .{
            .replace_me = idx,
        };

        return;
    } else {
        fetch_queue.items(.result)[i] = .{
            .new_entry = try api.getHeadCommit(
                &arena.allocator,
                dep_table[dep_idx].github.user,
                dep_table[dep_idx].github.repo,
                dep_table[dep_idx].github.ref,
            ),
        };
    }

    // TODO: detect partial matches where the commit resolves to the same
    const resolution = switch (fetch_queue.items(.result)[i]) {
        .fill_resolution => |res_idx| resolutions[res_idx].commit,
        .new_entry => |commit| commit,
        else => unreachable,
    };

    try fetch(
        arena,
        dep_table[dep_idx],
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
            const gh = &dep_table[dep_idx].github;
            const root = gh.root orelse utils.default_root;
            try resolutions.append(allocator, .{
                .user = gh.user,
                .repo = gh.repo,
                .ref = gh.ref,
                .root = root,
                .commit = commit,
                .dep_idx = dep_idx,
            });
        },
        .replace_me => |dep_idx| fetch_queue.items(.edge)[i].to = dep_idx,
        .err => |err| return err,
        .copy_deps => |queue_idx| try fetch_queue.items(.deps)[i].appendSlice(
            allocator,
            fetch_queue.items(.deps)[queue_idx].items,
        ),
    }
}
