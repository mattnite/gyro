const std = @import("std");

const Allocator = std.mem.Allocator;

pub const name = "url";
pub const Resolution = []const u8;
pub const ResolutionTable = std.StringArrayHashMapUnmanaged(?usize);
pub const FetchError = error{};

pub fn deserializeLockfileEntry(
    allocator: *Allocator,
    it: std.mem.TokenIterator,
    resolutions: *ResolutionTable,
) !void {
    _ = allocator;
    _ = it;
    _ = resolutions;
}

pub fn serializeResolutions(
    resolutions: ResolutionTable,
    writer: anytype,
) !void {
    _ = resolutions;
    _ = writer;
}
