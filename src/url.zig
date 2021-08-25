const std = @import("std");
const Engine = @import("Engine.zig");
const Dependency = @import("Dependency.zig");

const Allocator = std.mem.Allocator;

pub const name = "url";
pub const Resolution = []const u8;
pub const ResolutionEntry = struct {
    root: []const u8,
    str: []const u8,
    dep_idx: ?usize = null,
};

pub const FetchError = error{Todo};
const FetchQueue = Engine.MultiQueueImpl(Resolution, FetchError);
const ResolutionTable = std.ArrayListUnmanaged(ResolutionEntry);

pub fn deserializeLockfileEntry(
    allocator: *Allocator,
    it: *std.mem.TokenIterator(u8),
    resolutions: *ResolutionTable,
) !void {
    try resolutions.append(allocator, .{
        .root = it.next() orelse return error.NoRoot,
        .str = it.next() orelse return error.NoUrl,
    });
}

pub fn serializeResolutions(
    resolutions: []const ResolutionEntry,
    writer: anytype,
) !void {
    for (resolutions) |entry| {
        try writer.print("url {s} {s}\n", .{
            entry.root,
            entry.str,
        });
    }
}

pub fn dedupeResolveAndFetch(
    arena: *std.heap.ArenaAllocator,
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) FetchError!void {
    _ = arena;
    _ = dep_table;
    _ = resolutions;
    _ = fetch_queue;
    _ = i;

    return error.Todo;
}

pub fn updateResolution(
    allocator: *Allocator,
    resolutions: *ResolutionTable,
    dep_table: []const Dependency.Source,
    fetch_queue: *FetchQueue,
    i: usize,
) !void {
    _ = allocator;
    _ = resolutions;
    _ = dep_table;
    _ = fetch_queue;
    _ = i;
    return error.Todo;
}
