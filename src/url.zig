const std = @import("std");
const uri = @import("uri");
const curl = @import("curl");

const Engine = @import("Engine.zig");
const Dependency = @import("Dependency.zig");
const Project = @import("Project.zig");
const api = @import("api.zig");
const cache = @import("cache.zig");
const utils = @import("utils.zig");
const local = @import("local.zig");
const main = @import("root");
const ThreadSafeArenaAllocator = @import("ThreadSafeArenaAllocator.zig");

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
    allocator: Allocator,
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

pub fn findResolution(dep: Dependency.Source, resolutions: []const ResolutionEntry) ?usize {
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

fn fmtCachePath(allocator: Allocator, url: []const u8) ![]const u8 {
    const link = try uri.parse(url);
    return std.mem.replaceOwned(
        u8,
        allocator,
        url[link.scheme.?.len + 3 ..],
        "/",
        "-",
    );
}

pub fn resolutionToCachePath(
    allocator: Allocator,
    res: ResolutionEntry,
) ![]const u8 {
    return fmtCachePath(allocator, res.str);
}

fn progressCb(
    data: ?*anyopaque,
    dltotal: c_long,
    dlnow: c_long,
    ultotal: c_long,
    ulnow: c_long,
) callconv(.C) c_int {
    _ = ultotal;
    _ = ulnow;

    const handle = @ptrCast(*usize, @alignCast(@alignOf(*usize), data orelse return 0)).*;
    main.display.updateEntry(handle, .{
        .progress = .{
            .current = @intCast(usize, dlnow),
            .total = @intCast(usize, if (dltotal == 0) 1 else dltotal),
        },
    }) catch {};

    return 0;
}

fn fetch(
    arena: *ThreadSafeArenaAllocator,
    dep: Dependency.Source,
    deps: *std.ArrayListUnmanaged(Dependency),
    path: *?[]const u8,
) !void {
    const allocator = arena.child_allocator;
    const entry_name = try fmtCachePath(allocator, dep.url.str);
    defer allocator.free(entry_name);

    var entry = try cache.getEntry(entry_name);
    defer entry.deinit();

    if (!try entry.isDone()) {
        var content_dir = try entry.contentDir();
        defer content_dir.close();

        // TODO: allow user to strip directories from a tarball
        var handle = try main.display.createEntry(.{ .url = dep.url.str });
        errdefer main.display.updateEntry(handle, .{ .err = {} }) catch {};

        const url_z = try allocator.dupeZ(u8, dep.url.str);
        defer allocator.free(url_z);

        const xfer_ctx = api.XferCtx{
            .cb = progressCb,
            .data = &handle,
        };

        try api.getTarGz(allocator, url_z, content_dir, xfer_ctx);
        try entry.done();
    }

    const base_path = try std.fs.path.join(allocator, &.{
        ".gyro",
        entry_name,
        "pkg",
    });
    defer allocator.free(base_path);

    const root = dep.url.root orelse utils.default_root;
    path.* = try utils.joinPathConvertSep(arena, &.{ base_path, root });
    var base_dir = try std.fs.cwd().openDir(base_path, .{});
    defer base_dir.close();

    const project_file = try base_dir.createFile("gyro.zzz", .{
        .read = true,
        .truncate = false,
        .exclusive = false,
    });
    defer project_file.close();

    const text = try project_file.reader().readAllAlloc(arena.allocator(), std.math.maxInt(usize));
    const project = try Project.fromUnownedText(arena, base_path, text);
    defer project.destroy();

    try deps.appendSlice(allocator, project.deps.items);
}

pub fn dedupeResolveAndFetch(
    arena: *ThreadSafeArenaAllocator,
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) void {
    dedupeResolveAndFetchImpl(
        arena,
        dep_table,
        resolutions,
        fetch_queue,
        i,
    ) catch |err| {
        fetch_queue.items(.result)[i] = .{ .err = err };
    };
}

fn dedupeResolveAndFetchImpl(
    arena: *ThreadSafeArenaAllocator,
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) FetchError!void {
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
    allocator: Allocator,
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
        // TODO: update resolution table
        .copy_deps => |queue_idx| try fetch_queue.items(.deps)[i].appendSlice(
            allocator,
            fetch_queue.items(.deps)[queue_idx].items,
        ),
    }
}
