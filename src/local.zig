const std = @import("std");
const Engine = @import("Engine.zig");
const Dependency = @import("Dependency.zig");
const Project = @import("Project.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;

pub const name = "local";
pub const Resolution = []const u8;
pub const ResolutionEntry = struct {
    path: []const u8,
    root: []const u8,
    dep_idx: ?usize = null,
};

pub const FetchError = error{Todo} ||
    @typeInfo(@typeInfo(@TypeOf(std.fs.Dir.openDir)).Fn.return_type.?).ErrorUnion.error_set ||
    @typeInfo(@typeInfo(@TypeOf(std.fs.path.join)).Fn.return_type.?).ErrorUnion.error_set ||
    @typeInfo(@typeInfo(@TypeOf(Project.fromDir)).Fn.return_type.?).ErrorUnion.error_set;

const FetchQueue = Engine.MultiQueueImpl(Resolution, FetchError);
const ResolutionTable = std.ArrayListUnmanaged(ResolutionEntry);

/// local source types should never be in the lockfile
pub fn deserializeLockfileEntry(
    allocator: *Allocator,
    it: *std.mem.TokenIterator(u8),
    resolutions: *ResolutionTable,
) !void {
    // TODO: warn but continue processing lockfile
    _ = allocator;
    _ = it;
    _ = resolutions;
    return error.ShouldNotHappen;
}

/// does nothing because we don't lock local source types
pub fn serializeResolutions(
    resolutions: []const ResolutionEntry,
    writer: anytype,
) !void {
    _ = resolutions;
    _ = writer;
}

pub fn dedupeResolveAndFetch(
    arena: *std.heap.ArenaAllocator,
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) FetchError!void {
    _ = resolutions;

    const dep = &dep_table[fetch_queue.items(.edge)[i].to].local;

    var dir = try std.fs.cwd().openDir(dep.path, .{});
    defer dir.close();

    var project = try Project.fromDir(&arena.allocator, dir, .{});
    defer project.destroy();

    const root = dep.root orelse utils.default_root;
    fetch_queue.items(.path)[i] = try std.fs.path.join(&arena.allocator, &.{ dep.path, root });
    try fetch_queue.items(.deps)[i].appendSlice(arena.child_allocator, project.deps.items);
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
}
