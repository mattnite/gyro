//! zzz format serializer and deserializer. public domain.
//!
//! StreamingParser inspired by Zig's JSON parser.
//!
//! SPARSE SPEC
//! (zzz text is escaped using Zig's multiline string: \\)
//!
//! zzz text describes a tree of strings. Special characters (and spaces) are used to go up and down
//! the tree. The tree has an implicit null root node.
//!
//! Descending the tree:
//! \\grandparent:parent:child:grandchild
//! Output:
//! null -> "grandparent" -> "parent" -> "child" -> "grandchild"
//!
//! Traversing the children of root (siblings):
//! \\sibling1,sibling2,sibling3
//! Output:
//! null -> "sibling1"
//!      -> "sibling2"
//!      -> "sibling3"
//!
//! Going up to the parent:
//! \\parent:child;anotherparent
//! Output:
//! null -> "parent" -> "child"
//!      -> "anotherparent"
//!
//! White space and newlines are significant. A newline will take you back to the root:
//! \\parent:child
//! \\anotherparent
//! Output:
//! null -> "parent" -> "child"
//!      -> "anotherparent"
//!
//! Exactly two spaces are used to to go down a level in the tree:
//! \\parent:child
//! \\  siblingtend
//! null -> "parent" -> "child"
//!                  -> "sibling"
//!
//! You can only go one level deeper than the previous line's depth. Anything more is an error:
//! \\parent:child
//! \\    sibling
//! Output: Error!
//!
//! Trailing commas, semicolons, and colons are optional. So the above (correct one) can be written
//! as:
//! \\parent
//! \\  child
//! \\  sibling
//! Output:
//! null -> "parent" -> "child"
//!                  -> "sibling"
//!
//! zzz can contain strings, integers (i32), floats (f32), boolean, and nulls:
//! \\string:42:42.0:true::
//! Output:
//! null -> "string" -> 42 -> 42.0 -> true -> null
//!
//! strings are trimmed, they may still contain spaces:
//! \\parent:     child:      grand child      ;
//! Output:
//! null -> "parent" -> "child" -> "grand child"
//!
//! strings can be quoted with double quotes or Lua strings:
//! \\"parent":[[ child ]]:[==[grand child]=]]==];
//! Output:
//! null -> "parent" -> " child " -> "grand child]=]"
//!
//! Lua strings will skip the first empty newline:
//! \\[[
//! \\some text]]
//! Output:
//! null -> "some text"
//!
//! Strings are not escaped and taken "as-is".
//! \\"\n\t\r"
//! Output:
//! null -> "\n\t\r"
//!
//! Comments begin with # and run up to the end of the line. Their indentation follows the same
//! rules as nodes.
//! \\# A comment
//! \\a node
//! \\  # Another comment
//! \\  a sibling
//! Output:
//! null -> "a node" -> "a sibling"

const std = @import("std");

/// The only output of the tokenizer.
pub const ZNodeToken = struct {
    const Self = @This();
    /// 0 is root, 1 is top level children.
    depth: usize,
    /// The extent of the slice.
    start: usize,
    end: usize,
};

/// Parses text outputting ZNodeTokens. Does not convert strings to numbers, and all strings are
/// "as is", no escaping is performed.
pub const StreamingParser = struct {
    const Self = @This();
    state: State,
    start_index: usize,
    current_index: usize,
    // The maximum node depth.
    max_depth: usize,
    // The current line's depth.
    line_depth: usize,
    // The current node depth.
    node_depth: usize,
    /// Level of multiline string.
    open_string_level: usize,
    /// Current level of multiline string close.
    close_string_level: usize,
    /// Account for any extra spaces trailing at the end of a word.
    trailing_spaces: usize,

    pub const Error = error{
        TooMuchIndentation,
        InvalidWhitespace,
        OddIndentationValue,
        InvalidQuotation,
        InvalidMultilineOpen,
        InvalidMultilineClose,
        InvalidNewLineInString,
        InvalidCharacterAfterString,
        SemicolonWentPastRoot,
        UnexpectedEof,
    };

    pub const State = enum {
        /// Whether we're starting on an openline.
        OpenLine,
        ExpectZNode,
        Indent,
        OpenCharacter,
        Quotation,
        SingleLineCharacter,
        MultilineOpen0,
        MultilineOpen1,
        MultilineLevelOpen,
        MultilineLevelClose,
        MultilineClose0,
        MultilineCharacter,
        EndString,
        OpenComment,
        Comment,
    };

    /// Returns a blank parser.
    pub fn init() Self {
        var self: StreamingParser = undefined;
        self.reset();
        return self;
    }

    /// Resets the parser back to the beginning state.
    pub fn reset(self: *Self) void {
        self.state = .OpenLine;
        self.start_index = 0;
        self.current_index = 0;
        self.max_depth = 0;
        self.line_depth = 0;
        self.node_depth = 0;
        self.open_string_level = 0;
        self.close_string_level = 0;
        self.trailing_spaces = 0;
    }

    pub fn completeOrError(self: *const Self) !void {
        switch (self.state) {
            .ExpectZNode, .OpenLine, .EndString, .Comment, .OpenComment, .Indent => {},
            else => return Error.UnexpectedEof,
        }
    }

    /// Feeds a character to the parser. May output a ZNode. Check "hasCompleted" to see if there
    /// are any unfinished strings.
    pub fn feed(self: *Self, c: u8) Error!?ZNodeToken {
        defer self.current_index += 1;
        //std.debug.print("FEED<{}> {} {} ({c})\n", .{self.state, self.current_index, c, c});
        switch (self.state) {
            .OpenComment, .Comment => switch (c) {
                '\n' => {
                    self.start_index = self.current_index + 1;
                    // We're ending a line with nodes.
                    if (self.state == .Comment) {
                        self.max_depth = self.line_depth + 1;
                    }
                    self.node_depth = 0;
                    self.line_depth = 0;
                    self.state = .OpenLine;
                },
                else => {
                    // Skip.
                },
            },
            // All basically act the same except for a few minor differences.
            .ExpectZNode, .OpenLine, .EndString, .OpenCharacter => switch (c) {
                '#' => {
                    if (self.state == .OpenLine) {
                        self.state = .OpenComment;
                    } else {
                        defer self.state = .Comment;
                        if (self.state == .OpenCharacter) {
                            return ZNodeToken{
                                .depth = self.line_depth + self.node_depth + 1,
                                .start = self.start_index,
                                .end = self.current_index - self.trailing_spaces,
                            };
                        }
                    }
                },
                // The tricky character (and other whitespace).
                ' ' => {
                    if (self.state == .OpenLine) {
                        if (self.line_depth >= self.max_depth) {
                            return Error.TooMuchIndentation;
                        }
                        self.state = .Indent;
                    } else if (self.state == .OpenCharacter) {
                        self.trailing_spaces += 1;
                    } else {

                        // Skip spaces when expecting a node on a closed line,
                        // including this one.
                        self.start_index = self.current_index + 1;
                    }
                },
                ':' => {
                    defer self.state = .ExpectZNode;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth + 1,
                        .start = self.start_index,
                        .end = self.current_index - self.trailing_spaces,
                    };
                    self.start_index = self.current_index + 1;
                    self.node_depth += 1;
                    // Only return when we're not at end of a string.
                    if (self.state != .EndString) {
                        return node;
                    }
                },
                ',' => {
                    defer self.state = .ExpectZNode;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth + 1,
                        .start = self.start_index,
                        .end = self.current_index - self.trailing_spaces,
                    };
                    self.start_index = self.current_index + 1;
                    // Only return when we're not at end of a string.
                    if (self.state != .EndString) {
                        return node;
                    }
                },
                ';' => {
                    if (self.node_depth == 0) {
                        return Error.SemicolonWentPastRoot;
                    }
                    defer self.state = .ExpectZNode;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth + 1,
                        .start = self.start_index,
                        .end = self.current_index - self.trailing_spaces,
                    };
                    self.start_index = self.current_index + 1;
                    self.node_depth -= 1;
                    // Only return when we're not at end of a string, or in semicolons
                    // special case, when we don't have an empty string.
                    if (self.state != .EndString and node.start < node.end) {
                        return node;
                    }
                },
                '"' => {
                    if (self.state == .EndString) {
                        return Error.InvalidCharacterAfterString;
                    }
                    // Don't start another string.
                    if (self.state == .OpenCharacter) {
                        return null;
                    }
                    // We start here to account for the possibility of a string being ""
                    self.start_index = self.current_index + 1;
                    self.state = .Quotation;
                },
                '[' => {
                    if (self.state == .EndString) {
                        return Error.InvalidCharacterAfterString;
                    }
                    // Don't start another string.
                    if (self.state == .OpenCharacter) {
                        return null;
                    }
                    self.open_string_level = 0;
                    self.state = .MultilineOpen0;
                },
                '\n' => {
                    defer self.state = .OpenLine;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth + 1,
                        .start = self.start_index,
                        .end = self.current_index - self.trailing_spaces,
                    };
                    self.start_index = self.current_index + 1;
                    // Only reset on a non open line.
                    if (self.state != .OpenLine) {
                        self.max_depth = self.line_depth + 1;
                        self.line_depth = 0;
                    }
                    self.node_depth = 0;
                    // Only return something if there is something. Quoted strings are good.
                    if (self.state == .OpenCharacter) {
                        return node;
                    }
                },
                '\t', '\r' => {
                    return Error.InvalidWhitespace;
                },
                else => {
                    // We already have a string.
                    if (self.state == .EndString) {
                        return Error.InvalidCharacterAfterString;
                    }
                    // Don't reset if we're in a string.
                    if (self.state != .OpenCharacter) {
                        self.start_index = self.current_index;
                    }
                    self.trailing_spaces = 0;
                    self.state = .OpenCharacter;
                },
            },
            .Indent => switch (c) {
                ' ' => {
                    self.start_index = self.current_index + 1;
                    self.line_depth += 1;
                    self.state = .OpenLine;
                },
                else => {
                    return Error.OddIndentationValue;
                },
            },
            .Quotation => switch (c) {
                '"' => {
                    self.state = .EndString;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth + 1,
                        .start = self.start_index,
                        .end = self.current_index,
                    };
                    // Reset because we're going to expecting nodes.
                    self.start_index = self.current_index + 1;
                    return node;
                },
                else => {
                    self.state = .SingleLineCharacter;
                },
            },
            .SingleLineCharacter => switch (c) {
                '"' => {
                    self.state = .EndString;
                    const node = ZNodeToken{
                        .depth = self.line_depth + self.node_depth + 1,
                        .start = self.start_index,
                        .end = self.current_index,
                    };
                    // Reset because we're going to expecting nodes.
                    self.start_index = self.current_index + 1;
                    return node;
                },
                '\n' => {
                    return Error.InvalidNewLineInString;
                },
                else => {
                    // Consume.
                },
            },
            .MultilineOpen0, .MultilineLevelOpen => switch (c) {
                '=' => {
                    self.open_string_level += 1;
                    self.state = .MultilineLevelOpen;
                },
                '[' => {
                    self.start_index = self.current_index + 1;
                    self.state = .MultilineOpen1;
                },
                else => {
                    return Error.InvalidMultilineOpen;
                },
            },
            .MultilineOpen1 => switch (c) {
                ']' => {
                    self.state = .MultilineClose0;
                },
                '\n' => {
                    // Skip first newline.
                    self.start_index = self.current_index + 1;
                },
                else => {
                    self.state = .MultilineCharacter;
                },
            },
            .MultilineCharacter => switch (c) {
                ']' => {
                    self.close_string_level = 0;
                    self.state = .MultilineClose0;
                },
                else => {
                    // Capture EVERYTHING.
                },
            },
            .MultilineClose0, .MultilineLevelClose => switch (c) {
                '=' => {
                    self.close_string_level += 1;
                    self.state = .MultilineLevelClose;
                },
                ']' => {
                    if (self.close_string_level == self.open_string_level) {
                        self.state = .EndString;
                        return ZNodeToken{
                            .depth = self.line_depth + self.node_depth + 1,
                            .start = self.start_index,
                            .end = self.current_index - self.open_string_level - 1,
                        };
                    }
                    self.state = .MultilineCharacter;
                },
                else => {
                    return Error.InvalidMultilineClose;
                },
            },
        }
        return null;
    }
};

fn testNextTextOrError(stream: *StreamingParser, idx: *usize, text: []const u8) ![]const u8 {
    while (idx.* < text.len) {
        const node = try stream.feed(text[idx.*]);
        idx.* += 1;
        if (node) |n| {
            //std.debug.print("TOKEN {}\n", .{text[n.start..n.end]});
            return text[n.start..n.end];
        }
    }
    return error.ExhaustedLoop;
}
test "parsing slice output" {
    const testing = std.testing;

    const text =
        \\# woo comment
        \\mp:10
        \\[[sy]]
        \\  # another
        \\  : n : "en"  ,  [[m]]
        \\    "sc"   :  [[10]]   ,    g #inline
        \\  [[]]:[==[
        \\hi]==]
    ;
    var idx: usize = 0;
    var stream = StreamingParser.init();
    try testing.expectEqualSlices(u8, "mp", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "10", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "sy", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "n", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "en", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "m", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "sc", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "10", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "g", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "", try testNextTextOrError(&stream, &idx, text));
    try testing.expectEqualSlices(u8, "hi", try testNextTextOrError(&stream, &idx, text));
}

fn testNextLevelOrError(stream: *StreamingParser, idx: *usize, text: []const u8) !usize {
    while (idx.* < text.len) {
        const node = try stream.feed(text[idx.*]);
        idx.* += 1;
        if (node) |n| {
            return n.depth;
        }
    }
    return error.ExhaustedLoop;
}

test "parsing depths" {
    const testing = std.testing;

    const text =
        \\# woo comment
        \\mp:10
        \\[[sy]]
        \\  # another
        \\  : n : "en"  ,  [[m]]
        \\    # more
        \\
        \\    # even more
        \\
        \\    "sc"   :  [[10]]   ,    g #inline
        \\  [[]]:[==[
        \\hi]==]
    ;
    var idx: usize = 0;
    var stream = StreamingParser.init();

    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 1);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 2);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 1);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 2);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 3);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 4);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 4);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 3);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 4);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 4);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 2);
    try testing.expectEqual(try testNextLevelOrError(&stream, &idx, text), 3);
}

/// Parses the stream, outputting ZNodeTokens which reference the text.
pub fn parseStream(stream: *StreamingParser, idx: *usize, text: []const u8) !?ZNodeToken {
    while (idx.* <= text.len) {
        // Insert an extra newline at the end of the stream.
        const node = if (idx.* == text.len) try stream.feed('\n') else try stream.feed(text[idx.*]);
        idx.* += 1;
        if (node) |n| {
            return n;
        }
    }
    return null;
}

/// A `ZNode`'s value.
pub const ZValue = union(enum) {
    const Self = @This();
    Null,
    String: []const u8,
    Int: i32,
    Float: f32,
    Bool: bool,

    /// Checks a ZValues equality.
    pub fn equals(self: Self, other: Self) bool {
        if (self == .Null and other == .Null) {
            return true;
        }
        if (self == .String and other == .String) {
            return std.mem.eql(u8, self.String, other.String);
        }
        if (self == .Int and other == .Int) {
            return self.Int == other.Int;
        }
        if (self == .Float and other == .Float) {
            return std.math.approxEq(f32, self.Float, other.Float, std.math.f32_epsilon);
        }
        if (self == .Bool and other == .Bool) {
            return self.Bool == other.Bool;
        }
        return false;
    }

    /// Outputs a value to the `out_stream`. This output is parsable.
    pub fn stringify(self: Self, out_stream: anytype) @TypeOf(out_stream).Error!void {
        switch (self) {
            .Null => {
                // Skip.
            },
            .String => {
                const find = std.mem.indexOfScalar;
                const chars = "\"\n\t\r,:;";
                const chars_count = @sizeOf(@TypeOf(chars));
                var need_escape = false;
                var found = [_]bool{false} ** chars_count;
                for ("\"\n\t\r,:;") |ch, i| {
                    const f = find(u8, self.String, ch);
                    if (f != null) {
                        found[i] = true;
                        need_escape = true;
                    }
                }
                // TODO: Escaping ]] in string.
                if (need_escape) {
                    // 0=" 1=\n
                    if (found[0] or found[1]) {
                        // Escape with Lua.
                        try out_stream.writeAll("[[");
                        const ret = try out_stream.writeAll(self.String);
                        try out_stream.writeAll("]]");
                        return ret;
                    } else {
                        // Escape with basic quotes.
                        try out_stream.writeAll("\"");
                        const ret = try out_stream.writeAll(self.String);
                        try out_stream.writeAll("\"");
                        return ret;
                    }
                }
                return try out_stream.writeAll(self.String);
            },
            .Int => {
                return std.fmt.formatIntValue(self.Int, "", std.fmt.FormatOptions{}, out_stream);
            },
            .Float => {
                return std.fmt.formatFloatScientific(self.Float, std.fmt.FormatOptions{}, out_stream);
            },
            .Bool => {
                return out_stream.writeAll(if (self.Bool) "true" else "false");
            },
        }
    }

    ///
    pub fn format(self: Self, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .Null => try std.fmt.format(writer, ".Null", .{}),
            .String => try std.fmt.format(writer, ".String({s})", .{self.String}),
            .Int => try std.fmt.format(writer, ".Int({})", .{self.Int}),
            .Float => try std.fmt.format(writer, ".Float({})", .{self.Float}),
            .Bool => try std.fmt.format(writer, ".Bool({})", .{self.Bool}),
        }
    }
};

/// Result of imprinting
pub fn Imprint(comptime T: type) type {
    return struct {
        result: T,
        arena: std.heap.ArenaAllocator,
    };
}

pub const ImprintError = error{
    ExpectedBoolNode,
    ExpectedFloatNode,
    ExpectedUnsignedIntNode,
    ExpectedIntNode,
    ExpectedIntOrStringNode,
    ExpectedStringNode,

    FailedToConvertStringToEnum,
    FailedToConvertIntToEnum,

    FieldNodeDoesNotExist,
    ValueNodeDoesNotExist,
    ArrayElemDoesNotExist,

    OutOfMemory,

    InvalidPointerType,
    InvalidType,
};

/// Represents a node in a static tree. Nodes have a parent, child, and sibling pointer
/// to a spot in the array.
pub const ZNode = struct {
    const Self = @This();
    value: ZValue = .Null,
    parent: ?*ZNode = null,
    sibling: ?*ZNode = null,
    child: ?*ZNode = null,

    /// Returns the next Node in the tree. Will return Null after reaching root. For nodes further
    /// down the tree, they will bubble up, resulting in a negative depth. Self is considered to be
    /// at depth 0.
    pub fn next(self: *const Self, depth: *isize) ?*ZNode {
        if (self.child) |c| {
            depth.* += 1;
            return c;
        } else if (self.sibling) |c| {
            return c;
        } else {
            // Go up and forward.
            var iter: ?*const ZNode = self;
            while (iter != null) {
                iter = iter.?.parent;
                if (iter != null) {
                    depth.* -= 1;
                    if (iter.?.sibling) |c| {
                        return c;
                    }
                }
            }
            return null;
        }
    }

    /// Returns the next node in the tree until reaching root or the stopper node.
    pub fn nextUntil(self: *const Self, stopper: *const ZNode, depth: *isize) ?*ZNode {
        if (self.child) |c| {
            if (c == stopper) {
                return null;
            }
            depth.* += 1;
            return c;
        } else if (self.sibling) |c| {
            if (c == stopper) {
                return null;
            }
            return c;
        } else {
            // Go up and forward.
            var iter: ?*const ZNode = self;
            while (iter != null) {
                iter = iter.?.parent;
                // All these checks. :/
                if (iter == stopper) {
                    return null;
                }
                if (iter != null) {
                    depth.* -= 1;
                    if (iter.?.sibling) |c| {
                        if (c == stopper) {
                            return null;
                        }
                        return c;
                    }
                }
            }
            return null;
        }
    }

    /// Iterates this node's children. Pass null to start. `iter = node.nextChild(iter);`
    pub fn nextChild(self: *const Self, iter: ?*const ZNode) ?*ZNode {
        if (iter) |it| {
            return it.sibling;
        } else {
            return self.child;
        }
    }

    /// Returns the nth child's value. Or null if neither the node or child exist.
    pub fn getChildValue(self: *const Self, nth: usize) ?ZValue {
        var count: usize = 0;
        var iter: ?*ZNode = self.child;
        while (iter) |n| {
            if (count == nth) {
                if (n.child) |c| {
                    return c.value;
                } else {
                    return null;
                }
            }
            count += 1;
            iter = n.sibling;
        }
        return null;
    }

    /// Returns the nth child. O(n)
    pub fn getChild(self: *const Self, nth: usize) ?*ZNode {
        var count: usize = 0;
        var iter: ?*ZNode = self.child;
        while (iter) |n| {
            if (count == nth) {
                return n;
            }
            count += 1;
            iter = n.sibling;
        }
        return null;
    }

    /// Returns the number of children. O(n)
    pub fn getChildCount(self: *const Self) usize {
        var count: usize = 0;
        var iter: ?*ZNode = self.child;
        while (iter) |n| {
            count += 1;
            iter = n.sibling;
        }
        return count;
    }

    /// Finds the next child after the given iterator. This is good for when you can guess the order
    /// of the nodes, which can cut down on starting from the beginning. Passing null starts over
    /// from the beginning. Returns the found node or null (it will loop back around).
    pub fn findNextChild(self: *const Self, start: ?*const ZNode, value: ZValue) ?*ZNode {
        var iter: ?*ZNode = self.child;
        if (start) |si| {
            iter = si.sibling;
        }
        while (iter != start) {
            if (iter) |it| {
                if (it.value.equals(value)) {
                    return it;
                }
                iter = it.sibling;
            } else {
                // Loop back.
                iter = self.child;
            }
        }
        return null;
    }

    /// Finds the nth child node with a specific tag.
    pub fn findNthAny(self: *const Self, nth: usize, tag: std.meta.Tag(ZValue)) ?*ZNode {
        var count: usize = 0;
        var iter: ?*ZNode = self.child;
        while (iter) |n| {
            if (n.value == tag) {
                if (count == nth) {
                    return n;
                }
                count += 1;
            }
            iter = n.sibling;
        }
        return null;
    }

    /// Finds the nth child node with a specific value.
    pub fn findNth(self: *const Self, nth: usize, value: ZValue) ?*ZNode {
        var count: usize = 0;
        var iter: ?*ZNode = self.child orelse return null;
        while (iter) |n| {
            if (n.value.equals(value)) {
                if (count == nth) {
                    return n;
                }
                count += 1;
            }
            iter = n.sibling;
        }
        return null;
    }

    /// Traverses descendants until a node with the tag is found.
    pub fn findNthAnyDescendant(self: *const Self, nth: usize, tag: std.meta.Tag(ZValue)) ?*ZNode {
        var depth: isize = 0;
        var count: usize = 0;
        var iter: *const ZNode = self;
        while (iter.nextUntil(self, &depth)) |n| : (iter = n) {
            if (n.value == tag) {
                if (count == nth) {
                    return n;
                }
                count += 1;
            }
        }
        return null;
    }

    /// Traverses descendants until a node with the specific value is found.
    pub fn findNthDescendant(self: *const Self, nth: usize, value: ZValue) ?*ZNode {
        var depth: isize = 0;
        var count: usize = 0;
        var iter: *const ZNode = self;
        while (iter.nextUntil(self, &depth)) |n| : (iter = n) {
            if (n.value.equals(value)) {
                if (count == nth) {
                    return n;
                }
                count += 1;
            }
        }
        return null;
    }

    /// Converts strings to specific types. This just tries converting the string to an int, then
    /// float, then bool. Booleans are only the string values "true" or "false".
    pub fn convertStrings(self: *const Self) void {
        var depth: isize = 0;
        var iter: *const ZNode = self;
        while (iter.nextUntil(self, &depth)) |c| : (iter = c) {
            if (c.value != .String) {
                continue;
            }
            // Try to cast to numbers, then true/false checks, then string.
            const slice = c.value.String;
            const integer = std.fmt.parseInt(i32, slice, 10) catch {
                const float = std.fmt.parseFloat(f32, slice) catch {
                    if (std.mem.eql(u8, "true", slice)) {
                        c.value = ZValue{ .Bool = true };
                    } else if (std.mem.eql(u8, "false", slice)) {
                        c.value = ZValue{ .Bool = false };
                    } else {
                        // Keep the value.
                    }
                    continue;
                };
                c.value = ZValue{ .Float = float };
                continue;
            };
            c.value = ZValue{ .Int = integer };
        }
    }

    fn imprint_(self: *const Self, comptime T: type, allocator: ?*std.mem.Allocator) ImprintError!T {
        const TI = @typeInfo(T);

        switch (TI) {
            .Void => {},
            .Bool => {
                return switch (self.value) {
                    .Bool => |b| b,
                    else => ImprintError.ExpectedBoolNode,
                };
            },
            .Float, .ComptimeFloat => {
                return switch (self.value) {
                    .Float => |n| @floatCast(T, n),
                    .Int => |n| @intToFloat(T, n),
                    else => ImprintError.ExpectedFloatNode,
                };
            },
            .Int, .ComptimeInt => {
                const is_signed = (TI == .Int and TI.Int.signedness == .signed) or (TI == .ComptimeInt and TI.CompTimeInt.is_signed);
                switch (self.value) {
                    .Int => |n| {
                        if (is_signed) {
                            return @intCast(T, n);
                        } else {
                            if (n < 0) {
                                return ImprintError.ExpectedUnsignedIntNode;
                            }
                            return @intCast(T, n);
                        }
                    },
                    else => return ImprintError.ExpectedIntNode,
                }
            },
            .Enum => {
                switch (self.value) {
                    .Int => |int| {
                        return std.meta.intToEnum(T, int) catch {
                            return ImprintError.FailedToConvertIntToEnum;
                        };
                    },
                    .String => {
                        if (std.meta.stringToEnum(T, self.value.String)) |e| {
                            return e;
                        } else {
                            return ImprintError.FailedToConvertStringToEnum;
                        }
                    },
                    else => return ImprintError.ExpectedIntOrStringNode,
                }
            },
            .Optional => |opt_info| {
                const CI = @typeInfo(opt_info.child);
                // Aggregate types have a null root, so could still exist.
                if (self.value != .Null or CI == .Array or CI == .Struct or (CI == .Pointer and CI.Pointer.size == .Slice)) {
                    return try self.imprint_(opt_info.child, allocator);
                } else {
                    return null;
                }
            },
            .Struct => |struct_info| {
                var iter: ?*const ZNode = null;
                var result: T = .{};

                inline for (struct_info.fields) |field| {
                    // Skip underscores.
                    if (field.name[0] == '_') {
                        continue;
                    }

                    const found = self.findNextChild(iter, .{ .String = field.name });
                    if (found) |child_node| {
                        if (@typeInfo(field.field_type) == .Struct) {
                            @field(result, field.name) = try child_node.imprint_(field.field_type, allocator);
                        } else {
                            if (child_node.child) |value_node| {
                                @field(result, field.name) = try value_node.imprint_(field.field_type, allocator);
                            }
                        }

                        // Found, set the iterator here.
                        iter = found;
                    }
                }
                return result;
            },
            // Only handle [N]?T, where T is any other valid type.
            .Array => |array_info| {
                // Arrays are weird. They work on siblings.
                // TODO: For some types this causes a crash like [N]fn() void types.
                var r: T = std.mem.zeroes(T);
                var iter: ?*const ZNode = self;
                comptime var i: usize = 0;
                inline while (i < array_info.len) : (i += 1) {
                    if (iter) |it| {
                        r[i] = try it.imprint_(array_info.child, allocator);
                    }
                    if (iter) |it| {
                        iter = it.sibling;
                    }
                }
                return r;
            },
            .Pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .One => {
                        if (ptr_info.child == ZNode) {
                            // This is an odd case because we usually pass the child of a node
                            // for the value, but here since we explicitely asked for the node,
                            // it likely means the top. By taking the parent we force ZNodes
                            // only working when part of a large struct and not stand alone.
                            //
                            // Something like this wouldn't work: ```
                            // root.imprint(*ZNode);
                            // ```
                            return self.parent.?;
                        } else if (allocator) |alloc| {
                            var ptr = try alloc.create(ptr_info.child);
                            ptr.* = try self.imprint_(ptr_info.child, allocator);
                            return ptr;
                        } else {
                            return ImprintError.InvalidPointerType;
                        }
                    },
                    .Slice => {
                        if (ptr_info.child == u8) {
                            switch (self.value) {
                                .String => {
                                    if (allocator) |alloc| {
                                        return try std.mem.dupe(alloc, u8, self.value.String);
                                    } else {
                                        return self.value.String;
                                    }
                                },
                                else => return ImprintError.ExpectedStringNode,
                            }
                        } else if (allocator) |alloc| {
                            // Same as pointer above. We take parent.
                            var ret = try alloc.alloc(ptr_info.child, self.parent.?.getChildCount());
                            var iter: ?*const ZNode = self;
                            var i: usize = 0;
                            while (i < ret.len) : (i += 1) {
                                if (iter) |it| {
                                    ret[i] = try it.imprint_(ptr_info.child, allocator);
                                } else {
                                    if (@typeInfo(ptr_info.child) == .Optional) {
                                        ret[i] = null;
                                    } else {
                                        return ImprintError.ArrayElemDoesNotExist;
                                    }
                                }
                                if (iter) |it| {
                                    iter = it.sibling;
                                }
                            }
                            return ret;
                        } else {
                            return ImprintError.InvalidType;
                        }
                    },
                    else => return ImprintError.InvalidType,
                }
            },
            else => return ImprintError.InvalidType,
        }
    }

    pub fn imprint(self: *const Self, comptime T: type) ImprintError!T {
        return try self.imprint_(T, null);
    }

    pub fn imprintAlloc(self: *const Self, comptime T: type, allocator: *std.mem.Allocator) ImprintError!Imprint(T) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            // Free everything.
            arena.deinit();
        }
        return Imprint(T){
            .result = try self.imprint_(T, &arena.allocator),
            .arena = arena,
        };
    }

    /// Outputs a `ZNode` and its children on a single line. This can be parsed back.
    pub fn stringify(self: *const Self, out_stream: anytype) @TypeOf(out_stream).Error!void {
        // Likely not root.
        if (self.value != .Null) {
            try self.value.stringify(out_stream);
            try out_stream.writeAll(":");
        }
        var depth: isize = 0;
        var last_depth: isize = 1;
        var iter = self;
        while (iter.nextUntil(self, &depth)) |n| : (iter = n) {
            if (depth > last_depth) {
                last_depth = depth;
                try out_stream.writeAll(":");
            } else if (depth < last_depth) {
                while (depth < last_depth) {
                    try out_stream.writeAll(";");
                    last_depth -= 1;
                }
            } else if (depth > 1) {
                try out_stream.writeAll(",");
            }
            try n.value.stringify(out_stream);
        }
    }

    /// Returns true if node has more than one descendant (child, grandchild, etc).
    fn _moreThanOneDescendant(self: *const Self) bool {
        var depth: isize = 0;
        var count: usize = 0;
        var iter: *const ZNode = self;
        while (iter.nextUntil(self, &depth)) |n| : (iter = n) {
            count += 1;
            if (count > 1) {
                return true;
            }
        }
        return false;
    }

    fn _stringifyPretty(self: *const Self, out_stream: anytype) @TypeOf(out_stream).Error!void {
        try self.value.stringify(out_stream);
        try out_stream.writeAll(":");
        var depth: isize = 0;
        var last_depth: isize = 1;
        var iter = self;
        while (iter.nextUntil(self, &depth)) |n| : (iter = n) {
            if (depth > last_depth) {
                last_depth = depth;
                try out_stream.writeAll(":");
                // Likely an array.
                if (n.parent.?.value == .Null) {
                    try out_stream.writeAll(" ");
                } else if (n.parent.?._moreThanOneDescendant()) {
                    try out_stream.writeAll("\n");
                    try out_stream.writeByteNTimes(' ', 2 * @bitCast(usize, depth));
                } else {
                    try out_stream.writeAll(" ");
                }
            } else if (depth < last_depth) {
                while (depth < last_depth) {
                    last_depth -= 1;
                }
                try out_stream.writeAll("\n");
                try out_stream.writeByteNTimes(' ', 2 * @bitCast(usize, depth));
            } else {
                try out_stream.writeAll("\n");
                try out_stream.writeByteNTimes(' ', 2 * @bitCast(usize, depth));
            }
            try n.value.stringify(out_stream);
        }
    }

    /// Outputs a `ZNode`s children on multiple lines. Excludes this node as root.
    /// Arrays with children that have:
    /// - null elements, separate lines
    /// - non-null, same line
    pub fn stringifyPretty(self: *const Self, out_stream: anytype) @TypeOf(out_stream).Error!void {
        // Assume root, so don't print this node.
        var iter: ?*const ZNode = self.child;
        while (iter) |n| {
            try n._stringifyPretty(out_stream);
            try out_stream.writeAll("\n");
            iter = n.sibling;
        }
    }

    /// Debug print the node.
    pub fn show(self: *const Self) void {
        std.debug.print("{}\n", .{self.value});
        var depth: isize = 0;
        var iter: *const ZNode = self;
        while (iter.nextUntil(self, &depth)) |c| : (iter = c) {
            var i: isize = 0;
            while (i < depth) : (i += 1) {
                std.debug.print("  ", .{});
            }
            std.debug.print("{}\n", .{c.value});
        }
    }
};

pub const ZTreeError = error{
    TreeFull,
    TooManyRoots,
};

/// ZTree errors.
pub const ZError = StreamingParser.Error || ZTreeError;

/// Represents a static fixed-size zzz tree. Values are slices over the text passed.
pub fn ZTree(comptime R: usize, comptime S: usize) type {
    return struct {
        const Self = @This();
        roots: [R]*ZNode = undefined,
        root_count: usize = 0,
        nodes: [S]ZNode = [_]ZNode{.{}} ** S,
        node_count: usize = 0,

        /// Appends correct zzz text to the tree, creating a new root.
        pub fn appendText(self: *Self, text: []const u8) ZError!*ZNode {
            const current_node_count = self.node_count;
            var root = try self.addNode(null, .Null);
            // Undo everything we did if we encounter an error.
            errdefer {
                // Undo adding root above.
                self.root_count -= 1;
                // Reset to node count before adding root.
                self.node_count = current_node_count;
            }
            // If we error, undo adding any of this.
            var current = root;
            var current_depth: usize = 0;

            var stream = StreamingParser.init();
            var idx: usize = 0;
            while (try parseStream(&stream, &idx, text)) |token| {
                const slice = text[token.start..token.end];
                const value: ZValue = if (slice.len == 0) .Null else .{ .String = slice };
                const new_depth = token.depth;
                if (new_depth <= current_depth) {
                    // Ascend.
                    while (current_depth > new_depth) {
                        current = current.parent orelse unreachable;
                        current_depth -= 1;
                    }
                    // Sibling.
                    const new = try self.addNode(current.parent, value);
                    current.sibling = new;
                    current = new;
                } else if (new_depth == current_depth + 1) {
                    // Descend.
                    current_depth += 1;
                    const new = try self.addNode(current, value);
                    current.child = new;
                    current = new;
                } else {
                    // Levels shouldn't increase by more than one.
                    unreachable;
                }
            }

            try stream.completeOrError();

            return root;
        }

        /// Clears the entire tree.
        pub fn clear(self: *Self) void {
            self.root_count = 0;
            self.node_count = 0;
        }

        /// Returns a slice of active roots.
        pub fn rootSlice(self: *const Self) []const *ZNode {
            return self.roots[0..self.root_count];
        }

        /// Adds a node given a parent. Null parent starts a new root. When adding nodes manually
        /// care must be taken to ensure tree is left in known state after erroring from being full.
        /// Either reset to root_count/node_count when an error occurs, or leave as is (unfinished).
        pub fn addNode(self: *Self, parent: ?*ZNode, value: ZValue) ZError!*ZNode {
            if (self.node_count >= S) {
                return ZError.TreeFull;
            }
            var node = &self.nodes[self.node_count];
            if (parent == null) {
                if (self.root_count >= R) {
                    return ZError.TooManyRoots;
                }
                self.roots[self.root_count] = node;
                self.root_count += 1;
            }
            self.node_count += 1;
            node.value = value;
            node.parent = parent;
            node.sibling = null;
            node.child = null;
            // Add to end.
            if (parent) |p| {
                if (p.child) |child| {
                    var iter = child;
                    while (iter.sibling) |sib| : (iter = sib) {}
                    iter.sibling = node;
                } else {
                    p.child = node;
                }
            }
            return node;
        }

        /// Recursively copies a node from another part of the tree onto a new parent. Strings will
        /// be by reference.
        pub fn copyNode(self: *Self, parent: ?*ZNode, node: *const ZNode) ZError!*ZNode {
            const current_root_count = self.root_count;
            const current_node_count = self.node_count;
            // Likely because tree was full.
            errdefer {
                self.root_count = current_root_count;
                self.node_count = current_node_count;
            }
            var last_depth: isize = 1;
            var depth: isize = 0;
            var iter = node;
            var piter: ?*ZNode = parent;
            var plast: ?*ZNode = null;
            var pfirst: ?*ZNode = null;
            while (iter.next(&depth)) |child| : (iter = child) {
                if (depth > last_depth) {
                    piter = plast;
                    last_depth = depth;
                } else if (depth < last_depth) {
                    plast = piter;
                    while (last_depth != depth) {
                        piter = piter.?.parent;
                        last_depth -= 1;
                    }
                }
                plast = try self.addNode(piter, child.value);
                if (pfirst == null) {
                    pfirst = plast;
                }
            }
            return pfirst.?;
        }

        /// Debug print the tree and all of its roots.
        pub fn show(self: *const Self) void {
            for (self.rootSlice()) |rt| {
                rt.show();
            }
        }

        /// Extract a struct's values onto a tree with a new root. Performs no allocations so any strings
        /// are by reference.
        pub fn extract(self: *Self, root: ?*ZNode, from_ptr: anytype) anyerror!void {
            if (root == null) {
                return self.extract(try self.addNode(null, .Null), from_ptr);
            }
            if (@typeInfo(@TypeOf(from_ptr)) != .Pointer) {
                @compileError("Passed struct must be a pointer.");
            }
            const T = @typeInfo(@TypeOf(from_ptr)).Pointer.child;
            const TI = @typeInfo(T);
            switch (TI) {
                .Void => {
                    // No need.
                },
                .Bool => {
                    _ = try self.addNode(root, .{ .Bool = from_ptr.* });
                },
                .Float, .ComptimeFloat => {
                    _ = try self.addNode(root, .{ .Float = @floatCast(f32, from_ptr.*) });
                },
                .Int, .ComptimeInt => {
                    _ = try self.addNode(root, .{ .Int = @intCast(i32, from_ptr.*) });
                },
                .Enum => {
                    _ = try self.addNode(root, .{ .String = std.meta.tagName(from_ptr.*) });
                },
                .Optional => {
                    if (from_ptr.* != null) {
                        return self.extract(root, &from_ptr.*.?);
                    }
                },
                .Struct => |struct_info| {
                    inline for (struct_info.fields) |field| {
                        if (field.name[field.name.len - 1] == '_') {
                            continue;
                        }
                        var field_node = try self.addNode(root, .{ .String = field.name });
                        try self.extract(field_node, &@field(from_ptr.*, field.name));
                    }
                },
                .Array => |array_info| {
                    comptime var i: usize = 0;
                    inline while (i < array_info.len) : (i += 1) {
                        var null_node = try self.addNode(root, .Null);
                        try self.extract(null_node, &from_ptr.*[i]);
                    }
                },
                .Pointer => |ptr_info| {
                    switch (ptr_info.size) {
                        .One => {
                            if (ptr_info.child == ZNode) {
                                _ = try self.copyNode(root, from_ptr.*);
                            } else {
                                try self.extract(root, &from_ptr.*.*);
                            }
                        },
                        .Slice => {
                            if (ptr_info.child != u8) {
                                for (from_ptr.*) |_, i| {
                                    var null_node = try self.addNode(root, .Null);
                                    try self.extract(null_node, &from_ptr.*[i]);
                                }
                            } else {
                                _ = try self.addNode(root, .{ .String = from_ptr.* });
                            }
                            return;
                        },
                        else => return error.InvalidType,
                    }
                },
                else => return error.InvalidType,
            }
        }
    };
}

test "stable after error" {
    const testing = std.testing;

    var tree = ZTree(2, 6){};
    // Using 1 root, 3 nodes (+1 for root).
    _ = try tree.appendText("foo:bar");
    try testing.expectEqual(@as(usize, 1), tree.root_count);
    try testing.expectEqual(@as(usize, 3), tree.node_count);
    try testing.expectError(ZError.TreeFull, tree.appendText("bar:foo:baz:ha:ha"));
    try testing.expectEqual(@as(usize, 1), tree.root_count);
    try testing.expectEqual(@as(usize, 3), tree.node_count);
    // Using +1 root, +2 node = 2 roots, 5 nodes.
    _ = try tree.appendText("bar");
    try testing.expectEqual(@as(usize, 2), tree.root_count);
    try testing.expectEqual(@as(usize, 5), tree.node_count);
    try testing.expectError(ZError.TooManyRoots, tree.appendText("foo"));
    try testing.expectEqual(@as(usize, 2), tree.root_count);
    try testing.expectEqual(@as(usize, 5), tree.node_count);
}

test "static tree" {
    const testing = std.testing;
    const text =
        \\max_particles: 100
        \\texture: circle
        \\en: Foo
        \\systems:
        \\  : name:Emitter
        \\    params:
        \\      some,stuff,hehe
        \\  : name:Fire
    ;

    var tree = ZTree(1, 100){};
    const node = try tree.appendText(text);
    node.convertStrings();

    var iter = node.findNextChild(null, .{ .String = "max_particles" });
    try testing.expect(iter != null);
    iter = node.findNextChild(iter, .{ .String = "texture" });
    try testing.expect(iter != null);
    iter = node.findNextChild(iter, .{ .String = "max_particles" });
    try testing.expect(iter != null);
    iter = node.findNextChild(iter, .{ .String = "systems" });
    try testing.expect(iter != null);
    iter = node.findNextChild(iter, .{ .Int = 42 });
    try testing.expect(iter == null);
}

test "node appending and searching" {
    const testing = std.testing;

    var tree = ZTree(1, 100){};
    var root = try tree.addNode(null, .Null);

    _ = try tree.addNode(root, .Null);
    _ = try tree.addNode(root, .{ .String = "Hello" });
    _ = try tree.addNode(root, .{ .String = "foo" });
    _ = try tree.addNode(root, .{ .Int = 42 });
    _ = try tree.addNode(root, .{ .Float = 3.14 });
    _ = try tree.addNode(root, .{ .Bool = true });

    try testing.expectEqual(@as(usize, 6), root.getChildCount());
    try testing.expect(root.findNth(0, .Null) != null);

    try testing.expect(root.findNth(0, .{ .String = "Hello" }) != null);
    try testing.expect(root.findNth(0, .{ .String = "foo" }) != null);
    try testing.expect(root.findNth(1, .{ .String = "Hello" }) == null);
    try testing.expect(root.findNth(1, .{ .String = "foo" }) == null);
    try testing.expect(root.findNthAny(0, .String) != null);
    try testing.expect(root.findNthAny(1, .String) != null);
    try testing.expect(root.findNthAny(2, .String) == null);

    try testing.expect(root.findNth(0, .{ .Int = 42 }) != null);
    try testing.expect(root.findNth(0, .{ .Int = 41 }) == null);
    try testing.expect(root.findNth(1, .{ .Int = 42 }) == null);
    try testing.expect(root.findNthAny(0, .Int) != null);
    try testing.expect(root.findNthAny(1, .Int) == null);

    try testing.expect(root.findNth(0, .{ .Float = 3.14 }) != null);
    try testing.expect(root.findNth(0, .{ .Float = 3.13 }) == null);
    try testing.expect(root.findNth(1, .{ .Float = 3.14 }) == null);
    try testing.expect(root.findNthAny(0, .Float) != null);
    try testing.expect(root.findNthAny(1, .Float) == null);

    try testing.expect(root.findNthAny(0, .Bool) != null);
    try testing.expect(root.findNth(0, .{ .Bool = true }) != null);
    try testing.expect(root.findNthAny(1, .Bool) == null);
    try testing.expect(root.findNth(1, .{ .Bool = true }) == null);
}

test "node conforming imprint" {
    const testing = std.testing;

    const ConformingEnum = enum {
        Foo,
    };

    const ConformingSubStruct = struct {
        name: []const u8 = "default",
        params: ?*const ZNode = null,
    };

    const ConformingStruct = struct {
        max_particles: ?i32 = null,
        texture: []const u8 = "default",
        systems: [20]?ConformingSubStruct = [_]?ConformingSubStruct{null} ** 20,
        en: ?ConformingEnum = null,
        exists: ?void = null,
    };

    const text =
        \\max_particles: 100
        \\texture: circle
        \\en: Foo
        \\systems:
        \\  : name:Emitter
        \\    params:
        \\      some,stuff,hehe
        \\  : name:Fire
        \\    params
        \\exists: anything here
    ;
    var tree = ZTree(1, 100){};
    var node = try tree.appendText(text);
    node.convertStrings();

    const example = try node.imprint(ConformingStruct);
    try testing.expectEqual(@as(i32, 100), example.max_particles.?);
    try testing.expectEqualSlices(u8, "circle", example.texture);
    try testing.expect(null != example.systems[0]);
    try testing.expect(null != example.systems[1]);
    try testing.expectEqual(@as(?ConformingSubStruct, null), example.systems[2]);
    try testing.expectEqual(ConformingEnum.Foo, example.en.?);
    try testing.expectEqualSlices(u8, "params", example.systems[0].?.params.?.value.String);
}

test "node nonconforming imprint" {
    const testing = std.testing;

    const NonConformingStruct = struct {
        max_particles: bool = false,
    };

    const text =
        \\max_particles: 100
        \\texture: circle
        \\en: Foo
        \\systems:
        \\  : name:Emitter
        \\    params:
        \\      some,stuff,hehe
        \\  : name:Fire
    ;
    var tree = ZTree(1, 100){};
    var node = try tree.appendText(text);
    node.convertStrings();

    try testing.expectError(ImprintError.ExpectedBoolNode, node.imprint(NonConformingStruct));
}

test "imprint allocations" {
    const testing = std.testing;

    const Embedded = struct {
        name: []const u8 = "",
        count: u32 = 0,
    };
    const SysAlloc = struct {
        name: []const u8 = "",
        params: ?*const ZNode = null,
    };
    const FooAlloc = struct {
        max_particles: ?*i32 = null,
        texture: []const u8 = "",
        systems: []SysAlloc = undefined,
        embedded: Embedded = .{},
    };
    const text =
        \\max_particles: 100
        \\texture: circle
        \\en: Foo
        \\systems:
        \\  : name:Emitter
        \\    params:
        \\      some,stuff,hehe
        \\  : name:Fire
        \\    params
        \\embedded:
        \\  name: creator
        \\  count: 12345
        \\
    ;
    var tree = ZTree(1, 100){};
    var node = try tree.appendText(text);
    node.convertStrings();
    var imprint = try node.imprintAlloc(FooAlloc, testing.allocator);
    try testing.expectEqual(@as(i32, 100), imprint.result.max_particles.?.*);
    for (imprint.result.systems) |sys, i| {
        try testing.expectEqualSlices(u8, ([_][]const u8{ "Emitter", "Fire" })[i], sys.name);
    }
    imprint.arena.deinit();
}

test "extract" {
    var text_tree = ZTree(1, 100){};
    var text_root = try text_tree.appendText("foo:bar:baz;;42");

    const FooNested = struct {
        a_bool: bool = true,
        a_int: i32 = 42,
        a_float: f32 = 3.14,
    };
    const foo_struct = struct {
        foo: ?i32 = null,
        hi: []const u8 = "lol",
        arr: [2]FooNested = [_]FooNested{.{}} ** 2,
        slice: []const FooNested = &[_]FooNested{ .{}, .{}, .{} },
        ptr: *const FooNested = &FooNested{},
        a_node: *ZNode = undefined,
    }{
        .a_node = text_root,
    };

    var tree = ZTree(1, 100){};
    try tree.extract(null, &foo_struct);
}

/// A minimal factory for creating structs. The type passed should be an interface. Register structs
/// with special declarations and instantiate them with ZNodes. Required declarations:
/// - ZNAME: []const u8 // name of the struct referenced in zzz
/// - zinit: fn(allocator: *std.mem.Allocator, argz: *const ZNode) anyerror!*T // constructor called
pub fn ZFactory(comptime T: type) type {
    return struct {
        const Self = @This();

        const Ctor = struct {
            func: fn (allocator: *std.mem.Allocator, argz: *const ZNode) anyerror!*T,
        };

        registered: std.StringHashMap(Ctor),

        /// Create the factory. The allocator is for the internal HashMap. Instantiated objects
        /// can have their own allocator.
        pub fn init(allocator: *std.mem.Allocator) Self {
            return Self{
                .registered = std.StringHashMap(Ctor).init(allocator),
            };
        }

        ///
        pub fn deinit(self: *Self) void {
            self.registered.deinit();
        }

        /// Registers an implementor of the interface. Requires ZNAME and a zinit
        /// method.
        pub fn register(self: *Self, comptime S: anytype) !void {
            const SI = @typeInfo(S);
            if (SI != .Struct) {
                @compileError("Expected struct got: " ++ @typeName(S));
            }
            if (!@hasDecl(S, "zinit")) {
                @compileError("Missing `zinit` on registered struct, it could be private: " ++ @typeName(S));
            }
            if (!@hasDecl(S, "ZNAME")) {
                @compileError("Missing `ZNAME` on registered struct, it could be private: " ++ @typeName(S));
            }
            const ctor = Ctor{
                .func = S.zinit,
            };
            try self.registered.put(S.ZNAME, ctor);
        }

        /// Instantiates an object with ZNode. The ZNode's first child must have a string value of
        /// "name" with the child node's value being the name of the registered struct. The node is
        /// then passed to zinit.
        ///
        /// The caller is responsible for the memory.
        pub fn instantiate(self: *Self, allocator: *std.mem.Allocator, node: *const ZNode) !*T {
            const name = node.findNth(0, .{ .String = "name" }) orelse return error.ZNodeMissingName;
            const value_node = name.getChild(0) orelse return error.ZNodeMissingValueUnderName;
            if (value_node.value != .String) {
                return error.ZNodeNameValueNotString;
            }
            const ctor = self.registered.get(value_node.value.String) orelse return error.StructNotFound;
            return try ctor.func(allocator, node);
        }
    };
}

const FooInterface = struct {
    const Self = @This();

    allocator: ?*std.mem.Allocator = null,
    default: i32 = 100,
    fooFn: ?fn (*Self) void = null,

    deinitFn: ?fn (*const Self) void = null,

    pub fn foo(self: *Self) void {
        return self.fooFn.?(self);
    }
    pub fn deinit(self: *const Self) void {
        self.deinitFn.?(self);
    }
};

const FooBar = struct {
    const Self = @This();
    const ZNAME = "Foo";
    interface: FooInterface = .{},
    bar: i32 = 0,

    pub fn zinit(allocator: *std.mem.Allocator, _: *const ZNode) !*FooInterface {
        var self = try allocator.create(Self);
        self.* = .{
            .interface = .{
                .allocator = allocator,
                .fooFn = foo,
                .deinitFn = deinit,
            },
        };
        //const imprint = try argz.imprint(FooBar);
        //self.bar = imprint.bar;
        return &self.interface;
    }

    pub fn deinit(interface: *const FooInterface) void {
        const self = @fieldParentPtr(Self, "interface", interface);
        interface.allocator.?.destroy(self);
    }

    pub fn foo(interface: *FooInterface) void {
        _ = @fieldParentPtr(FooBar, "interface", interface);
    }
};

test "factory" {
    const testing = std.testing;

    const text =
        \\name:Foo
        \\bar:42
    ;

    var tree = ZTree(1, 100){};
    var root = try tree.appendText(text);
    root.convertStrings();

    var factory = ZFactory(FooInterface).init(testing.allocator);
    defer factory.deinit();

    try factory.register(FooBar);

    const foobar = try factory.instantiate(testing.allocator, root);
    foobar.foo();
    defer foobar.deinit();
}
