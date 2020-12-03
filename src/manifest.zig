const std = @import("std");
const zzz = @import("zzz");
const Import = @import("import.zig").Import;
const Allocator = std.mem.Allocator;

allocator: *Allocator,
file: std.fs.File,
deps: std.ArrayList(Import),
text: []const u8,

const Self = @This();
const ZTree = zzz.ZTree(1, 1000);

const ChildIterator = struct {
    val: ?*const zzz.ZNode,

    fn next(self: *ChildIterator) ?*const zzz.ZNode {
        return if (self.val) |node| blk: {
            self.val = node.sibling;
            break :blk node;
        } else null;
    }

    fn init(node: *const zzz.ZNode) ChildIterator {
        return ChildIterator{
            .val = node.child,
        };
    }
};

/// if path doesn't exist, create it else load contents
pub fn init(allocator: *Allocator, file: std.fs.File) !Self {
    var deps = std.ArrayList(Import).init(allocator);
    errdefer deps.deinit();

    const raw_text = try file.readToEndAlloc(allocator, 0x2000);
    defer allocator.free(raw_text);

    // handle windows line endings
    const text = try std.mem.replaceOwned(u8, allocator, raw_text, "\r\n", "\n");
    errdefer allocator.free(text);

    var tree = ZTree{};
    var root = try tree.appendText(text);

    // iterate and append to deps
    var import_it = ChildIterator.init(root);
    while (import_it.next()) |node| {
        std.log.debug("got an import from the manifest", .{});
        try deps.append(try Import.fromZNode(node));
    }

    return Self{
        .allocator = allocator,
        .file = file,
        .deps = deps,
        .text = text,
    };
}

/// on destruction serialize to file
pub fn deinit(self: *Self) void {
    self.deps.deinit();
    self.allocator.free(self.text);
}

pub fn commit(self: *Self) !void {
    var tree = ZTree{};
    var root = try tree.addNode(null, .Null);

    for (self.deps.items) |dep| {
        _ = try dep.addToZNode(root, &tree);
    }

    _ = try self.file.seekTo(0);
    _ = try self.file.setEndPos(0);
    try root.stringifyPretty(self.file.writer());
}

pub fn addImport(self: *Self, import: Import) !void {
    if (import.name.len == 0) {
        return error.EmptyName;
    }

    for (self.deps.items) |dep| {
        if (std.mem.eql(u8, dep.name, import.name)) {
            return error.NameExists;
        }
    }

    try self.deps.append(import);
}

pub fn removeImport(self: *Self, name: []const u8) !void {
    for (self.deps.items) |dep, i| {
        if (std.mem.eql(u8, dep.name, name)) {
            _ = self.deps.orderedRemove(i);
            break;
        }
    } else return error.NameNotFound;
}
