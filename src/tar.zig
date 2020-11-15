const std = @import("std");

const testing = std.testing;
const Allocator = std.mem.Allocator;

// ustar tar implementation
pub const Header = extern struct {
    name: [100]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [11:0]u8,
    mtime: [12]u8,
    checksum: [8]u8,
    typeflag: FileType,
    linkname: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    prefix: [155]u8,
    pad: [12]u8 = [_]u8{0} ** 12,

    const Self = @This();

    const FileType = extern enum(u8) {
        regular = '0',
        hard_link = '1',
        symbolic_link = '2',
        character = '3',
        block = '4',
        directory = '5',
        fifo = '6',
        reserved = '7',
        pax_global = 'g',
        extended = 'x',
        _,
    };

    pub fn isBlank(self: *const Header) bool {
        const block = std.mem.asBytes(self);
        return for (block) |elem| {
            if (elem != 0) break false;
        } else true;
    }
};

test "Header size" {
    testing.expectEqual(512, @sizeOf(Header));
}

pub fn instantiate(allocator: *Allocator, dir: std.fs.Dir, reader: anytype, skip_depth: usize) !void {
    var count: usize = 0;
    while (true) {
        const header = reader.readStruct(Header) catch |err| {
            return if (err == error.EndOfStream) if (count < 2) error.AbrubtEnd else break else err;
        };

        const block = std.mem.asBytes(&header);
        if (header.isBlank()) {
            count += 1;
            continue;
        } else if (count > 0) {
            return error.Format;
        }

        var size = try std.fmt.parseUnsigned(usize, &header.size, 8);
        const block_size = ((size + 511) / 512) * 512;
        var components = std.ArrayList([]const u8).init(allocator);
        defer components.deinit();

        var path_it = std.mem.tokenize(&header.prefix, "/\x00");
        if (header.prefix[0] != 0) {
            while (path_it.next()) |component| {
                try components.append(component);
            }
        }

        path_it = std.mem.tokenize(&header.name, "/\x00");
        while (path_it.next()) |component| {
            try components.append(component);
        }

        const tmp_path = try std.fs.path.join(allocator, components.items);
        defer allocator.free(tmp_path);

        if (skip_depth >= components.items.len) {
            try reader.skipBytes(block_size, .{});
            continue;
        }

        var i: usize = 0;
        while (i < skip_depth) : (i += 1) {
            _ = components.orderedRemove(0);
        }

        const file_path = try std.fs.path.join(allocator, components.items);
        defer allocator.free(file_path);

        switch (header.typeflag) {
            .directory => try dir.makePath(file_path),
            .pax_global => try reader.skipBytes(512, .{}),
            .regular => {
                const file = try dir.createFile(file_path, .{ .read = true, .truncate = true });
                defer file.close();
                const skip_size = block_size - size;

                var buf: [std.mem.page_size]u8 = undefined;
                while (size > 0) {
                    const buffered = try reader.read(buf[0..std.math.min(size, 512)]);
                    try file.writeAll(buf[0..buffered]);
                    size -= buffered;
                }

                try reader.skipBytes(skip_size, .{});
            },
            else => {},
        }
    }
}
