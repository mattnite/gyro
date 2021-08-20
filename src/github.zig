const std = @import("std");

const Allocator = std.mem.Allocator;

pub const name = "github";
pub const Resolution = []const u8;
pub const ResolutionTable = std.ArrayListUnmanaged(struct {
    user: []const u8,
    repo: []const u8,
    ref: []const u8,
    commit: []const u8,
});
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
