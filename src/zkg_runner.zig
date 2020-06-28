const std = @import("std");
const imports = @import("imports.zig");
const process = std.process;
const mem = std.mem;
const c = @cImport({
    @cInclude("git2.h");
});

pub fn main() !void {
    const stderr = std.io.getStdErr().outStream();
    if (c.git_libgit2_init() == 0) {
        defer _ = c.git_libgit2_shutdown();
    }

    inline for (std.meta.declarations(imports)) |val| {
        if (val.is_pub) {
            std.debug.warn("{}\n", .{val});
            std.debug.warn("    {}\n", .{@field(imports, val.name)});
            std.debug.warn("    {}\n", .{@typeName(@TypeOf(@field(imports, val.name)))});
        }
    }
}
