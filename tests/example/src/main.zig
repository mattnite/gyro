const std = @import("std");
const clap = @import("clap");
const regex = @import("regex");

const debug = std.debug;

pub fn main() anyerror!void {
    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-a <A>, checks if matches to 'fast'") catch unreachable,
    };

    var args = try clap.parse(clap.Help, &params, std.heap.page_allocator);
    defer args.deinit();

    @setEvalBranchQuota(1250);
    if (args.option("-a")) |string| {
        if (try regex.match("fast", .{ .encoding = .utf8 }, string)) |res| {
            debug.print("match!!!\n", .{});
        } else {
            return error.GottaGoFast;
        }
    } else {
        return error.MissingArgument;
    }
}
