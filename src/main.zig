usingnamespace std.zig;
const std = @import("std");
const zag = @import("zag.zig");
const os = std.os;
const c = @cImport({
    @cInclude("git2.h");
});

const Allocator = std.mem.Allocator;
const Pkg = std.build.Pkg;

pub fn main() anyerror!void {
    if (c.git_libgit2_init() == 0) {
        defer _ = c.git_libgit2_shutdown();
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = &arena.allocator;
    const root_dir = std.fs.Dir{ .fd = try os.open(".", 0, 0) };
    defer os.close(root_dir.fd);

    const buf = try root_dir.readFileAlloc(allocator, "imports.zig", 1000);
    defer allocator.free(buf);

    const tree = try parse(allocator, buf);
    defer tree.deinit();

    // we care about public vardecls that are const and have an init_node
    // TODO: will have to remove requirement of init_node to be a call
    var decls = std.ArrayList(*const ast.Node.VarDecl).init(allocator);
    for (tree.root_node.declsConst()) |decl| {
        if (decl.id != .VarDecl)
            continue;

        const vardecl = @fieldParentPtr(ast.Node.VarDecl, "base", decl);
        if (vardecl.init_node) |init| {
            if (init.id != .Call)
                continue;

            if (vardecl.visib_token) |idx| {
                if (tree.token_ids[idx] == .Keyword_pub) {
                    try decls.append(vardecl);
                }
            }
        }
    }

    // check variable decl initializations to check if they are zag function
    // calls
    // TODO: Later this would check if the type returned is Import, and allow
    // users to fill in the Import interface for customization. Requires zig
    // interpreter.
    var imports = std.ArrayList(zag.import.Import).init(allocator);
    defer imports.deinit();

    for (decls.span()) |decl| {
        const call = @fieldParentPtr(ast.Node.Call, "base", decl.init_node.?);
        const params = call.paramsConst();
        if (params.len != 3) {
            return error.InvalidParams;
        }

        const alias = tree.tokenSlice(decl.name_token);
        const repo = try literal_to_string(allocator, tree, params[0]);
        const branch = try literal_to_string(allocator, tree, params[1]);
        var root = if (params[2].id == .NullLiteral)
            null
        else
            try literal_to_string(allocator, tree, params[2]);

        try imports.append(zag.import.git_alias(alias, repo, branch, root));
    }

    // generate package file
    var cache_dir = std.fs.Dir{ .fd = try os.open("zig-cache", os.O_DIRECTORY, 0) };
    defer cache_dir.close();

    const gen_file = try cache_dir.createFile("packages.zig", std.fs.File.CreateFlags{
        .truncate = true,
    });
    defer gen_file.close();
    // TODO: errdefer delete file

    const file_stream = gen_file.outStream();
    try file_stream.writeAll(
        \\const std = @import("std");
        \\const Pkg = std.build.Pkg;
        \\
        \\pub const list = [_]Pkg{
        \\
    );

    for (imports.span()) |import| {
        const import_path = try import.path(&import, allocator);
        defer allocator.free(import_path);

        const root_path = try std.mem.join(allocator, std.fs.path.sep_str, &[_][]const u8{ import_path, import.root });
        defer allocator.free(root_path);

        try import.fetch(&import, allocator);
        try file_stream.print(
            \\    Pkg{{
            \\        .name = "{}",
            \\        .path = "{}",
            \\        .dependencies = null,
            \\    }},
            \\
        , .{ import.alias, root_path });
    }

    try file_stream.writeAll("};\n");
}

fn literal_to_string(allocator: *Allocator, tree: *ast.Tree, param: *ast.Node) ![]const u8 {
    const literal = tree.tokenSlice(@fieldParentPtr(ast.Node.StringLiteral, "base", param).token);
    const str = try remove_quotes(literal);
    return str;
}

fn remove_quotes(str: []const u8) ![]const u8 {
    if (str.len < 2)
        return error.TooShort;

    if (str[0] != '"' or str[str.len - 1] != '"')
        return error.MissingQuotes;

    return str[1 .. str.len - 1];
}
