const std = @import("std");

const testing = std.testing;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Semver = struct {
    major: u64,
    minor: u64,
    patch: u64,

    pub fn parse(str: []const u8) !Semver {
        var it = std.mem.tokenize(u8, str, ".");
        const semver = Semver{
            .major = try std.fmt.parseInt(usize, it.next() orelse return error.MajorNotFound, 10),
            .minor = try std.fmt.parseInt(usize, it.next() orelse return error.MinorNotFound, 10),
            .patch = try std.fmt.parseInt(usize, it.next() orelse return error.PatchNotFound, 10),
        };

        if (it.next() != null)
            return error.TooManyTokens;

        return semver;
    }

    pub fn format(
        self: Semver,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        try writer.print("{}.{}.{}", .{
            self.major,
            self.minor,
            self.patch,
        });
    }

    pub fn cmp(self: Semver, other: Semver) std.math.Order {
        return if (self.major != other.major)
            std.math.order(self.major, other.major)
        else if (self.minor != other.minor)
            std.math.order(self.minor, other.minor)
        else
            std.math.order(self.patch, other.patch);
    }

    pub fn inside(self: Semver, range: Range) bool {
        return self.cmp(range.min).compare(.gte) and self.cmp(range.lessThan()).compare(.lt);
    }
};

test "empty string" {
    try testing.expectError(error.MajorNotFound, Semver.parse(""));
}

test "bad strings" {
    try testing.expectError(error.MinorNotFound, Semver.parse("1"));
    try testing.expectError(error.MinorNotFound, Semver.parse("1."));
    try testing.expectError(error.PatchNotFound, Semver.parse("1.2"));
    try testing.expectError(error.PatchNotFound, Semver.parse("1.2."));
    try testing.expectError(error.Overflow, Semver.parse("1.-2.3"));
    try testing.expectError(error.InvalidCharacter, Semver.parse("^1.2.3-3.4.5"));
}

test "semver-suffix" {
    try testing.expectError(error.InvalidCharacter, Semver.parse("1.2.3-dev"));
}

test "regular semver" {
    const expected = Semver{ .major = 1, .minor = 2, .patch = 3 };
    try testing.expectEqual(expected, try Semver.parse("1.2.3"));
}

test "semver formatting" {
    var buf: [80]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const semver = Semver{ .major = 4, .minor = 2, .patch = 1 };
    try stream.writer().print("{}", .{semver});

    try testing.expectEqualStrings("4.2.1", stream.getWritten());
}

test "semver contains/inside range" {
    const range_pre = try Range.parse("^0.4.1");
    const range_post = try Range.parse("^1.4.1");

    try testing.expect(!range_pre.contains(try Semver.parse("0.2.0")));
    try testing.expect(!range_pre.contains(try Semver.parse("0.4.0")));
    try testing.expect(!range_pre.contains(try Semver.parse("0.5.0")));
    try testing.expect(range_pre.contains(try Semver.parse("0.4.2")));
    try testing.expect(range_pre.contains(try Semver.parse("0.4.128")));

    try testing.expect(!range_post.contains(try Semver.parse("1.2.0")));
    try testing.expect(!range_post.contains(try Semver.parse("1.4.0")));
    try testing.expect(!range_post.contains(try Semver.parse("2.0.0")));
    try testing.expect(range_post.contains(try Semver.parse("1.5.0")));
    try testing.expect(range_post.contains(try Semver.parse("1.4.2")));
    try testing.expect(range_post.contains(try Semver.parse("1.4.128")));
}

pub const Range = struct {
    min: Semver,
    kind: Kind,

    pub const Kind = enum {
        approx,
        caret,
        exact,
    };

    fn lessThan(self: Range) Semver {
        return switch (self.kind) {
            .exact => Semver{
                .major = self.min.major,
                .minor = self.min.minor,
                .patch = self.min.patch + 1,
            },
            .approx => Semver{
                .major = self.min.major,
                .minor = self.min.minor + 1,
                .patch = 0,
            },
            .caret => if (self.min.major == 0) Semver{
                .major = self.min.major,
                .minor = self.min.minor + 1,
                .patch = 0,
            } else Semver{
                .major = self.min.major + 1,
                .minor = 0,
                .patch = 0,
            },
        };
    }

    pub fn parse(str: []const u8) !Range {
        if (str.len == 0)
            return error.Empty;

        var semver_str: []const u8 = undefined;
        const kind: Kind = switch (str[0]) {
            '^' => blk: {
                semver_str = str[1..];
                break :blk .caret;
            },
            '~' => blk: {
                semver_str = str[1..];
                break :blk .approx;
            },
            else => blk: {
                if (!std.ascii.isDigit(str[0]))
                    return error.InvalidCharacter;

                semver_str = str;
                break :blk .exact;
            },
        };

        return Range{
            .kind = kind,
            .min = try Semver.parse(semver_str),
        };
    }

    pub fn format(
        self: Range,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) @TypeOf(writer).Error!void {
        _ = fmt;
        _ = options;
        switch (self.kind) {
            .exact => try writer.print("{}", .{self.min}),
            .approx => try writer.print("~{}", .{self.min}),
            .caret => if (fmt.len == 1 and fmt[0] == 'u')
                try writer.print("%5E{}", .{self.min})
            else
                try writer.print("^{}", .{self.min}),
        }
    }

    pub fn contains(self: Range, semver: Semver) bool {
        return semver.inside(self);
    }
};

test "empty string" {
    try testing.expectError(error.Empty, Range.parse(""));
}

test "approximate" {
    const expected = Range{
        .kind = .approx,
        .min = Semver{
            .major = 1,
            .minor = 2,
            .patch = 3,
        },
    };
    try testing.expectEqual(expected, try Range.parse("~1.2.3"));
}

test "caret" {
    const expected = Range{
        .kind = .caret,
        .min = Semver{
            .major = 1,
            .minor = 2,
            .patch = 3,
        },
    };
    try testing.expectEqual(expected, try Range.parse("^1.2.3"));
}

test "exact range" {
    const expected = Range{
        .kind = .exact,
        .min = Semver{
            .major = 1,
            .minor = 2,
            .patch = 3,
        },
    };
    try testing.expectEqual(expected, try Range.parse("1.2.3"));
}

test "range formatting: exact" {
    var buf: [80]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const range = Range{
        .kind = .exact,
        .min = Semver{
            .major = 1,
            .minor = 2,
            .patch = 3,
        },
    };
    try stream.writer().print("{}", .{range});

    try testing.expectEqualStrings("1.2.3", stream.getWritten());
}

test "range formatting: approx" {
    var buf: [80]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const range = Range{
        .kind = .approx,
        .min = Semver{
            .major = 1,
            .minor = 2,
            .patch = 3,
        },
    };
    try stream.writer().print("{}", .{range});

    try testing.expectEqualStrings("~1.2.3", stream.getWritten());
}

test "range formatting: caret" {
    var buf: [80]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const range = Range{
        .kind = .caret,
        .min = Semver{
            .major = 1,
            .minor = 2,
            .patch = 3,
        },
    };
    try stream.writer().print("{}", .{range});

    try testing.expectEqualStrings("^1.2.3", stream.getWritten());
}
