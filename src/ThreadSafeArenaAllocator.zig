// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;

// this is a modified version of zig's stdlib arena allocator but with mutexes

const Self = @This();

mtx: std.Thread.Mutex,
child_allocator: Allocator,
state: State,

/// Inner state of Self. Can be stored rather than the entire Self
/// as a memory-saving optimization.
pub const State = struct {
    buffer_list: std.SinglyLinkedList([]u8) = @as(std.SinglyLinkedList([]u8), .{}),
    end_index: usize = 0,

    pub fn promote(self: State, child_allocator: Allocator) Self {
        return .{
            .mtx = std.Thread.Mutex{},
            .child_allocator = child_allocator,
            .state = self,
        };
    }
};

pub fn allocator(self: *Self) Allocator {
    return Allocator.init(self, alloc, resize, free);
}

const BufNode = std.SinglyLinkedList([]u8).Node;

pub fn init(child_allocator: Allocator) Self {
    return (State{}).promote(child_allocator);
}

pub fn deinit(self: *Self) void {
    var it = self.state.buffer_list.first;
    while (it) |node| {
        // this has to occur before the free because the free frees node
        const next_it = node.next;
        self.child_allocator.free(node.data);
        it = next_it;
    }
}

fn createNode(self: *Self, prev_len: usize, minimum_size: usize) !*BufNode {
    const actual_min_size = minimum_size + (@sizeOf(BufNode) + 16);
    const big_enough_len = prev_len + actual_min_size;
    const len = big_enough_len + big_enough_len / 2;
    const buf = try self.child_allocator.rawAlloc(len, @alignOf(BufNode), 1, @returnAddress());
    const buf_node = @ptrCast(*BufNode, @alignCast(@alignOf(BufNode), buf.ptr));
    buf_node.* = BufNode{
        .data = buf,
        .next = null,
    };
    self.state.buffer_list.prepend(buf_node);
    self.state.end_index = 0;
    return buf_node;
}

fn alloc(self: *Self, n: usize, ptr_align: u29, len_align: u29, ra: usize) ![]u8 {
    _ = len_align;
    _ = ra;

    self.mtx.lock();
    defer self.mtx.unlock();

    var cur_node = if (self.state.buffer_list.first) |first_node| first_node else try self.createNode(0, n + ptr_align);
    while (true) {
        const cur_buf = cur_node.data[@sizeOf(BufNode)..];
        const addr = @ptrToInt(cur_buf.ptr) + self.state.end_index;
        const adjusted_addr = mem.alignForward(addr, ptr_align);
        const adjusted_index = self.state.end_index + (adjusted_addr - addr);
        const new_end_index = adjusted_index + n;

        if (new_end_index <= cur_buf.len) {
            const result = cur_buf[adjusted_index..new_end_index];
            self.state.end_index = new_end_index;
            return result;
        }

        const bigger_buf_size = @sizeOf(BufNode) + new_end_index;
        // Try to grow the buffer in-place
        cur_node.data = self.child_allocator.resize(cur_node.data, bigger_buf_size) orelse {
            // Allocate a new node if that's not possible
            cur_node = try self.createNode(cur_buf.len, n + ptr_align);
            continue;
        };
    }
}

fn resize(self: *Self, buf: []u8, buf_align: u29, new_len: usize, len_align: u29, ret_addr: usize) ?usize {
    _ = buf_align;
    _ = len_align;
    _ = ret_addr;

    self.mtx.lock();
    defer self.mtx.unlock();

    const cur_node = self.state.buffer_list.first orelse return null;
    const cur_buf = cur_node.data[@sizeOf(BufNode)..];
    if (@ptrToInt(cur_buf.ptr) + self.state.end_index != @ptrToInt(buf.ptr) + buf.len) {
        if (new_len > buf.len) return null;
        return new_len;
    }

    if (buf.len >= new_len) {
        self.state.end_index -= buf.len - new_len;
        return new_len;
    } else if (cur_buf.len - self.state.end_index >= new_len - buf.len) {
        self.state.end_index += new_len - buf.len;
        return new_len;
    } else {
        return null;
    }
}

fn free(self: *Self, buf: []u8, buf_align: u29, ret_addr: usize) void {
    _ = buf_align;
    _ = ret_addr;

    const cur_node = self.state.buffer_list.first orelse return;
    const cur_buf = cur_node.data[@sizeOf(BufNode)..];

    if (@ptrToInt(cur_buf.ptr) + self.state.end_index == @ptrToInt(buf.ptr) + buf.len) {
        self.state.end_index -= buf.len;
    }
}
