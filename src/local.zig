const std = @import("std");
const Engine = @import("Engine.zig");
const Dependency = @import("Dependency.zig");
const Project = @import("Project.zig");
const utils = @import("utils.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

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
    @typeInfo(@typeInfo(@TypeOf(Project.fromDirPath)).Fn.return_type.?).ErrorUnion.error_set;

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
    return error.LocalsDontLock;
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
    dep_table: []const Dependency.Source,
    resolutions: []const ResolutionEntry,
    fetch_queue: *FetchQueue,
    i: usize,
) FetchError!void {
    _ = resolutions;

    const arena = &fetch_queue.items(.arena)[i];
    const dep = &dep_table[fetch_queue.items(.edge)[i].to].local;

    var base_dir = try std.fs.cwd().openDir(dep.path, .{});
    defer base_dir.close();

    const project_file = try base_dir.createFile("gyro.zzz", .{
        .read = true,
        .truncate = false,
        .exclusive = false,
    });
    defer project_file.close();

    const text = try project_file.reader().readAllAlloc(&arena.allocator, std.math.maxInt(usize));
    const project = try Project.fromUnownedText(arena.child_allocator, dep.path, text);
    defer project.destroy();

    // TODO: resolve path when default root
    const root = dep.root orelse utils.default_root;
    fetch_queue.items(.path)[i] = try utils.joinPathConvertSep(arena, &.{ dep.path, root });
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
