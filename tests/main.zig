const std = @import("std");
const testing = std.testing;
const ChildProcess = std.ChildProcess;

const zkg_fetch = &[_][]const u8{ "zkg", "fetch" };

fn zkgFetch(cwd: []const u8) !ChildProcess.ExecResult {
    const result = ChildProcess.exec(.{
        .allocator = &testing.allocator_instance,
        .argv = zkg_fetch,
        .cwd = cwd,
    });
}

test "normal example" {
    const result = try zkgFetch("example");
    testing.expectEqual(ChildProcess.Term{ .Exited = 0 }, result);
}
