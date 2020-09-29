const std = @import("std");
const imports = @import("imports");
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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;

    const deps_dir = try std.fs.path.join(allocator, &[_][]const u8{
        "zig-cache",
        "deps",
    });
    defer allocator.free(deps_dir);

    inline for (std.meta.declarations(imports)) |decl| {
        if (decl.is_pub) {
            const import: Import = @field(imports, decl.name);
            try import.fetch(import, allocator, deps_dir);

            try stdout.print("{} {} {}\n", .{
                decl.name,
                import.path(import, std.heap.page_allocator, deps_dir),
                import.root,
            });
        }
    }
}
