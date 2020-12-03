const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ChildProcess = std.ChildProcess;
const Term = ChildProcess.Term;

fn zkgFetch(components: []const []const u8) !ChildProcess.ExecResult {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const cwd = try std.fs.path.join(&gpa.allocator, components);
    defer gpa.allocator.free(cwd);

    return ChildProcess.exec(.{
        .allocator = &gpa.allocator,
        .argv = &[_][]const u8{ if (builtin.os.tag == .windows) "zkg.exe" else "zkg", "fetch" },
        .cwd = cwd,
    });
}

fn zigBuild(components: []const []const u8) !ChildProcess.ExecResult {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const cwd = try std.fs.path.join(&gpa.allocator, components);
    defer gpa.allocator.free(cwd);

    return ChildProcess.exec(.{
        .allocator = &gpa.allocator,
        .argv = &[_][]const u8{ "zig", "build" },
        .cwd = cwd,
    });
}

test "example" {
    const dir = [_][]const u8{ "tests", "example" };
    var result = try zkgFetch(&dir);
    testing.expectEqual(Term{ .Exited = 0 }, result.term);

    result = try zigBuild(&dir);
    testing.expectEqual(Term{ .Exited = 0 }, result.term);
}

test "diamond" {
    const result = try zkgFetch(&[_][]const u8{ "tests", "diamond" });
    testing.expectEqual(Term{ .Exited = 0 }, result.term);
}

test "circular" {
    const result = try zkgFetch(&[_][]const u8{ "tests", "circular" });
    testing.expectEqual(Term{ .Exited = 1 }, result.term);
}

test "self-centered" {
    const result = try zkgFetch(&[_][]const u8{ "tests", "self-centered" });
    testing.expectEqual(Term{ .Exited = 1 }, result.term);
}

test "integrity" {
    const result = try zkgFetch(&[_][]const u8{ "tests", "integrity" });
    testing.expectEqual(Term{ .Exited = 0 }, result.term);
}
