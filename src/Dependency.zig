const version = @import("version");
const zzz = @import("zzz");

const Self = @This();

name: []const u8,
src: Source,

const Source = union(enum) {
    ziglet: struct {
        repository: []const u8,
        version: version.Range,
    },

    github: struct {
        user: []const u8,
        repo: []const u8,
        ref: []const u8,
        root: []const u8,
    },

    raw: struct {
        url: []const u8,
        root: []const u8,
        //integrity: ?Integrity,
    },
};

pub fn fromZNode(node: *const zzz.ZNode) !Self {
    return error.Todo;
}

pub fn addToZNode(self: Self, tree: *zzz.ZTree(1, 100), parent: *zzz.ZNode) !void {
    return error.Todo;
}
