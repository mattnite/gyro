const std = @import("std");
const version = @import("version");
const uri = @import("uri");

const c = @cImport({
    @cInclude("sys/ioctl.h");
});

const assert = std.debug.assert;

pub const Size = struct {
    rows: usize,
    cols: usize,
};

pub const Source = union(enum) {
    const Git = struct {
        url: []const u8,
        commit: []const u8,
    };

    git: Git,
    sub: Git,
    pkg: struct {
        repository: []const u8,
        user: []const u8,
        name: []const u8,
        semver: version.Semver,
    },
    url: []const u8,
};

const EntryUpdate = union(enum) {
    progress: Progress,
    err: void,
};

const Progress = struct {
    current: usize,
    total: usize,
};

const Entry = struct {
    tag: []const u8,
    label: []const u8,
    version: []const u8,
    progress: Progress,
    err: bool,
};

const UpdateState = struct {
    current_len: usize,
    entries: std.ArrayList(Entry),
    updates: std.AutoHashMap(usize, EntryUpdate),
    new_size: ?Size,

    fn init(allocator: *std.mem.Allocator) UpdateState {
        return UpdateState{
            .current_len = 0,
            .entries = std.ArrayList(Entry).init(allocator),
            .updates = std.AutoHashMap(usize, EntryUpdate).init(allocator),
            .new_size = null,
        };
    }

    fn deinit(self: *UpdateState) void {
        self.entries.deinit();
        self.updates.deinit();
    }

    fn hasChanges(self: UpdateState) bool {
        return self.new_size != null or
            self.entries.items.len > 0 or
            self.updates.count() > 0;
    }

    fn clear(self: *UpdateState) void {
        self.entries.clearRetainingCapacity();
        self.updates.clearRetainingCapacity();
        self.new_size = null;
    }
};

const Self = @This();

allocator: *std.mem.Allocator,
arena: std.heap.ArenaAllocator,
entries: std.ArrayList(Entry),
depth: usize,
size: Size,

running: std.atomic.Atomic(bool),
mtx: std.Thread.Mutex,
render_thread: std.Thread,

// state maps that get swapped
collector: *UpdateState,
scratchpad: *UpdateState,

fifo: std.fifo.LinearFifo(u8, .{ .Dynamic = {} }),

pub fn init(location: *Self, allocator: *std.mem.Allocator) !void {
    var winsize: c.winsize = undefined;
    const rc = c.ioctl(0, c.TIOCGWINSZ, &winsize);
    if (rc != 0) {
        winsize.ws_row = 24;
        winsize.ws_col = 80;
    }

    const collector = try allocator.create(UpdateState);
    errdefer allocator.destroy(collector);

    const scratchpad = try allocator.create(UpdateState);
    errdefer allocator.destroy(scratchpad);

    collector.* = UpdateState.init(allocator);
    scratchpad.* = UpdateState.init(allocator);

    // TODO: signal handler for terminal size change

    location.* = Self{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .running = std.atomic.Atomic(bool).init(true),
        .mtx = std.Thread.Mutex{},
        .render_thread = try std.Thread.spawn(.{}, renderTask, .{location}),
        .entries = std.ArrayList(Entry).init(allocator),
        .size = Size{
            .rows = winsize.ws_row,
            .cols = winsize.ws_col,
        },
        .depth = 0,
        .collector = collector,
        .scratchpad = scratchpad,
        .fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} }).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.running.store(false, .SeqCst);
    self.render_thread.join();
    self.entries.deinit();
    self.collector.deinit();
    self.scratchpad.deinit();
    self.allocator.destroy(self.collector);
    self.allocator.destroy(self.scratchpad);
    self.fifo.deinit();
    self.arena.deinit();
}

fn entryFromGit(
    self: *Self,
    tag: []const u8,
    url: []const u8,
    commit: []const u8,
) !Entry {
    const link = try uri.parse(url);
    const begin = if (link.scheme) |scheme| scheme.len + 3 else 0;
    const end_offset: usize = if (std.mem.endsWith(u8, url, ".git")) 4 else 0;

    return Entry{
        .tag = tag,
        .label = try self.arena.allocator.dupe(u8, url[begin .. url.len - end_offset]),
        .version = try self.arena.allocator.dupe(u8, commit[0..std.math.min(commit.len, 8)]),
        .progress = .{
            .current = 0,
            .total = 1,
        },
        .err = false,
    };
}

pub fn createEntry(self: *Self, source: Source) !usize {
    const allocator = &self.arena.allocator;
    const new_entry = switch (source) {
        .git => |git| try self.entryFromGit("git", git.url, git.commit),
        .sub => |sub| try self.entryFromGit("sub", sub.url, sub.commit),
        .pkg => |pkg| Entry{
            .tag = "pkg",
            .label = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{
                pkg.repository,
                pkg.user,
                pkg.name,
            }),
            .version = try std.fmt.allocPrint(allocator, "{}", .{pkg.semver}),
            .progress = .{
                .current = 0,
                .total = 1,
            },
            .err = false,
        },
        .url => |url| Entry{
            .tag = "url",
            .label = try self.allocator.dupe(u8, url),
            .version = "",
            .progress = .{
                .current = 0,
                .total = 1,
            },
            .err = false,
        },
    };

    var lock = self.mtx.acquire();
    defer lock.release();

    try self.collector.entries.append(new_entry);
    return self.collector.current_len +
        self.collector.entries.items.len - 1;
}

pub fn updateEntry(self: *Self, handle: usize, update: EntryUpdate) !void {
    var lock = self.mtx.acquire();
    defer lock.release();

    try self.collector.updates.put(handle, update);
}

pub fn updateSize(self: *Self, new_size: Size) void {
    var lock = self.mtx.acquire();
    defer lock.release();

    self.collector.new_size = new_size;
}

fn updateState(self: *Self) !void {
    try self.entries.appendSlice(self.scratchpad.entries.items);
    if (self.scratchpad.new_size) |new_size|
        self.size = new_size;

    var it = self.scratchpad.updates.iterator();
    while (it.next()) |entry| {
        const idx = entry.key_ptr.*;
        assert(idx <= self.entries.items.len);
        switch (entry.value_ptr.*) {
            .progress => |progress| self.entries.items[idx].progress = progress,
            .err => self.entries.items[idx].err = true,
        }
    }
}

fn renderTask(self: *Self) !void {
    const stdout = std.io.getStdOut().writer();
    var done = false;
    while (!done) : (std.time.sleep(std.time.ns_per_s * 0.1)) {
        if (!self.running.load(.SeqCst))
            done = true;

        {
            var lock = self.mtx.acquire();
            defer lock.release();

            self.scratchpad.current_len = self.collector.current_len +
                self.collector.entries.items.len;
            std.mem.swap(UpdateState, self.collector, self.scratchpad);
        }

        try self.updateState();
        if (self.entries.items.len > 0 and
            (self.scratchpad.hasChanges() or
            self.depth != self.entries.items.len))
        {
            try self.render(stdout);
        }

        self.scratchpad.clear();
    }
}

fn drawBar(writer: anytype, width: usize, percent: usize) !void {
    if (width < 3) {
        try writer.writeByteNTimes(' ', width);
        return;
    }

    const bar_width = width - 2;
    const cells = std.math.min(percent * bar_width / 100, bar_width);
    try writer.writeByte('[');
    try writer.writeByteNTimes('#', cells);
    try writer.writeByteNTimes(' ', bar_width - cells);
    try writer.writeByte(']');
}

fn render(self: *Self, stdout: anytype) !void {
    var winsize: c.winsize = undefined;
    const rc = c.ioctl(0, c.TIOCGWINSZ, &winsize);
    if (rc != 0)
        return error.Ioctl;

    const cols: usize = winsize.ws_col;

    const writer = self.fifo.writer();
    defer {
        self.fifo.count = 0;
        self.fifo.head = 0;
    }

    const spacing = 20;
    const short_mode = cols < 50;

    // calculations
    const version_width = 8;
    const variable = cols -| 26;
    const label_width = if (variable < spacing)
        variable
    else
        spacing + ((variable - spacing) / 2);

    const bar_width = if (variable < spacing)
        0
    else
        ((variable - spacing) / 2) + if (variable % 2 == 1) @as(usize, 1) else 0;

    if (self.depth < self.entries.items.len) {
        try writer.writeByteNTimes('\n', self.entries.items.len - self.depth);
        self.depth = self.entries.items.len;
    }

    // up n lines at beginning
    try writer.print("\x1b[{}F", .{self.depth});

    for (self.entries.items) |entry| {
        if (short_mode) {
            if (entry.err)
                try writer.writeAll("\x1b[31m");

            try writer.writeAll(entry.label[0..std.math.min(entry.label.len, cols)]);

            if (entry.err) {
                try writer.writeAll("\x1b[0m");
            }

            try writer.writeAll("\x1b[1B\x0d");

            continue;
        }

        const percent = std.math.min(entry.progress.current * 100 /
            entry.progress.total, 100);

        if (entry.err)
            try writer.writeAll("\x1b[31m");

        try writer.print("{s} ", .{entry.tag});
        if (entry.label.len > label_width) {
            try writer.writeAll(entry.label[0 .. label_width - 3]);
            try writer.writeAll("...");
        } else {
            try writer.writeAll(entry.label);
            try writer.writeByteNTimes(' ', label_width - entry.label.len);
        }

        try writer.writeByte(' ');
        try writer.writeAll(entry.version[0..std.math.min(version_width, entry.version.len)]);
        if (entry.version.len < label_width)
            try writer.writeByteNTimes(' ', version_width - entry.version.len);

        try writer.writeByte(' ');
        try drawBar(writer, bar_width, percent);
        try writer.print(" {: >3}%", .{percent});
        if (entry.err) {
            try writer.writeAll(" ERROR \x1b[0m");
        } else {
            try writer.writeByteNTimes(' ', 7);
        }

        try writer.writeAll("\x1b[1E");
    }

    try stdout.writeAll(self.fifo.readableSlice(0));
}
