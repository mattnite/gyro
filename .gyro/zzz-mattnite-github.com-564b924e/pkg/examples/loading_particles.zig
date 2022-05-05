pub const std = @import("std");
pub const zzz = @import("zzz");

const particles = @embedFile("../example-data/particles.zzz");

pub fn main() !void {
    var tree = zzz.ZTree(1, 1000){};
    const root = try tree.appendText(particles);

    try root.stringifyPretty(std.io.getStdOut().writer());
    std.debug.print("Node count: {}\n", .{tree.node_count});
}
