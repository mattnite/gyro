const std = @import("std");
const uri = @import("uri");
const Engine = @import("Engine.zig");
const Dependency = @import("Dependency.zig");
const Project = @import("Project.zig");
const api = @import("api.zig");
const cache = @import("cache.zig");
const utils = @import("utils.zig");
const local = @import("local.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const name = "url";
pub const Resolution = void;
pub const ResolutionEntry = struct {
    root: []const u8,
    str: []const u8,
    dep_idx: ?usize = null,
};

pub const FetchError =
    @typeInfo(@typeInfo(@TypeOf(fetch)).Fn.return_type.?).ErrorUnion.error_set;
const FetchQueue = Engine.MultiQueueImpl(Resolution, FetchError);
const ResolutionTable = std.ArrayListUnmanaged(ResolutionEntry);

pub fn deserializeLockfileEntry(
    allocator: *Allocator,
    it: *std.mem.TokenIterator(u8),
    resolutions: *ResolutionTable,
) !void {
    const entry = ResolutionEntry{
        .root = it.next() orelse return error.NoRoot,
        .str = it.next() orelse return error.NoUrl,
    };

    if (std.mem.startsWith(u8, entry.str, "file://"))
        return error.OldLocalFormat;

    try resolutions.append(allocator, entry);
}

pub fn serializeResolutions(
    resolutions: []const ResolutionEntry,
    writer: anytype,
) !void {
    for (resolutions) |entry|
        if (entry.dep_idx != null)
            try writer.print("url {s} {s}\n", .{
                entry.root,
                entry.str,
            });
}

fn findResolution(dep: Dependency.Source, resolutions: []const ResolutionEntry) ?usize {
    const root = dep.url.root orelse utils.default_root;
    return for (resolutions) |entry, i| {
        if (std.mem.eql(u8, dep.url.str, entry.str) and
            std.mem.eql(u8, root, entry.root))
        {
            break i;
        }
    } else null;
}

fn findMatch(dep_table: []const Dependency.Source, dep_idx: usize, edges: []const Engine.Edge) ?usize {
    const dep = dep_table[dep_idx].url;
    const root = dep.root orelse utils.default_root;
    return for (edges) |edge| {
        const other = dep_table[edge.to].url;
        const other_root = other.root orelse utils.default_root;
        if (std.mem.eql(u8, dep.str, other.str) and
            std.mem.eql(u8, root, other_root))
        {
            break edge.to;
        }
    } else null;
}

fn findPartialMatch(dep_table: []const Dependency.Source, dep_idx: usize, edges: []const Engine.Edge) ?usize {
    const dep = dep_table[dep_idx].url;
    return for (edges) |edge| {
        const other = dep_table[edge.to].url;
        if (std.mem.eql(u8, dep.str, other.str)) {
            break edge.to;
        }
    } else null;
}

fn fetch(
    arena: *std.heap.ArenaAllocator,
    dep: Dependency.Source,
    deps: *std.ArrayListUnmanaged(Dependency),
    path: *?[]const u8,
) !void {
    const allocator = arena.child_allocator;
    const link = try uri.parse(dep.url.str);
    const entry_name = try std.mem.replaceOwned(u8, allocator, dep.url.str[link.scheme.?.len + 3 ..], "/", "-");
    defer allocator.free(entry_name);

    var entry = try cache.getEntry(entry_name);
    defer entry.deinit();

    if (!try entry.isDone()) {
        var content_dir = try entry.contentDir();
        defer content_dir.close();

        // TODO: allow user to strip directories from a tarball
        try api.getTarGz(allocator, dep.url.str, content_dir);
        try entry.done();
    }

    const base_path = try std.fs.path.join(arena.child_allocator, &.{
        ".gyro",
        entry_name,
        "pkg",
    });
    defer arena.child_allocator.free(base_path);

    const root = dep.url.root orelse utils.default_root;
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
    const project = try Project.fromUnownedText(arena.child_allocator, ".", text);
    defer project.destroy();

    try deps.appendSlice(arena.child_allocator, project.deps.items);
}

pub fn dedupeResolveAndFetch(
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) FetchError!void {
    const arena = &fetch_queue.items(.arena)[i];
    _ = arena;

    const dep_idx = fetch_queue.items(.edge)[i].to;
    // check lockfile for entry
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
    } else if (findPartialMatch(dep_table, dep_idx, fetch_queue.items(.edge)[0..i])) |idx| {
        fetch_queue.items(.result)[i] = .{
            .copy_deps = idx,
        };

        return;
    } else {
        fetch_queue.items(.result)[i] = .{
            .new_entry = {},
        };
    }

    try fetch(
        arena,
        dep_table[dep_idx],
        &fetch_queue.items(.deps)[i],
        &fetch_queue.items(.path)[i],
    );
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
        .new_entry => {
            const dep_idx = fetch_queue.items(.edge)[i].to;
            const url = &dep_table[dep_idx].url;
            const root = url.root orelse utils.default_root;
            try resolutions.append(allocator, .{
                .str = url.str,
                .root = root,
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
