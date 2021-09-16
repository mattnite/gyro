const std = @import("std");

pub fn getEntry(name: []const u8) !Entry {
    var cache_dir = try std.fs.cwd().makeOpenPath(".gyro", .{});
    defer cache_dir.close();

    return Entry{
        .dir = try cache_dir.makeOpenPath(name, .{}),
    };
}

pub const Entry = struct {
    dir: std.fs.Dir,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.dir.close();
    }

    pub fn done(self: *Self) !void {
        const file = try self.dir.createFile("ok", .{});
        defer file.close();
    }

    pub fn isDone(self: *Self) !bool {
        return if (self.dir.access("ok", .{}))
            true
        else |err| switch (err) {
            error.FileNotFound => false,
            else => |e| e,
        };
    }

    pub fn contentDir(self: *Self) !std.fs.Dir {
        return try self.dir.makeOpenPath("pkg", .{});
    }
};
