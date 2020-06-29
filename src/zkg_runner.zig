const std = @import("std");
const imports = @import("imports.zig");
const process = std.process;
const mem = std.mem;
const c = @cImport({
    @cInclude("git2.h");
});

const Import = @import("zkg").import.Import;

pub fn main() !void {
    const stdout = std.io.getStdOut().outStream();
    if (c.git_libgit2_init() == 0) {
        defer _ = c.git_libgit2_shutdown();
    }

    inline for (std.meta.declarations(imports)) |decl| {
        if (decl.is_pub) {
            const import: *const Import = &@field(imports, decl.name);
            try import.fetch(import, std.heap.page_allocator);

            try stdout.print("{} {} {} {}\n", .{
                decl.name,
                import.version,
                import.url,
                import.root,
            });
        }
    }
}
