usingnamespace std.os;
const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const c = @cImport({
    @cInclude("git2.h");
});

const default_root = "exports.zig";
const Allocator = std.mem.Allocator;

fn get_cache() ![]const u8 {
    if (getenv("ZKG_CACHE")) |cache| {
        return cache;
    } else {
        return error.NotFound;
    }
}

pub const Import = struct {
    alias: ?[]const u8,
    version: ?[]const u8,
    root: []const u8,
    url: []const u8,
    fetch: fn (self: Import, allocator: *Allocator, deps_dir: []const u8) anyerror!void,
    path: fn (self: Import, allocator: *Allocator, deps_dir: []const u8) anyerror![]const u8,
};

pub fn git(repo: []const u8, branch: []const u8, root: ?[]const u8) Import {
    return Import{
        .alias = null,
        .version = branch,
        .root = if (root) |r| r else default_root,
        .url = repo,
        .fetch = git_fetch,
        .path = git_path,
    };
}

pub fn git_alias(alias: []const u8, repo: []const u8, branch: []const u8, root: ?[]const u8) Import {
    return Import{
        .alias = alias,
        .version = branch,
        .root = if (root) |r| r else default_root,
        .url = repo,
        .fetch = git_fetch,
        .path = git_path,
    };
}

pub const GitError = error{
    Ok,
    Error,
    NotFound,
    Exists,
    Ambiguous,
    Buf,
    User,
    BareRepo,
    UnbornBranch,
    Unmerged,
    NonFastForward,
    InvalidSpec,
    Conflict,
    Locked,
    Modified,
    Auth,
    Certificate,
    Applied,
    Peel,
    Eof,
    Invalid,
    Uncommitted,
    Directory,
    MergeConflict,
    Passthrough,
    IteratorOver,
    Retry,
    Mismatch,
    DirtyIndex,
    ApplyFail,
};

fn git_fetch(self: Import, allocator: *Allocator, deps_dir: []const u8) !void {
    var repo: ?*c.git_repository = undefined;
    const location = try self.path(self, allocator, deps_dir);
    defer allocator.free(location);

    const url = try std.cstr.addNullByte(allocator, self.url);
    defer allocator.free(url);

    debug.print("location: {}\n", .{location});
    const status = c.git_clone(&repo, url, location.ptr, null);
    if (status < 0 and status != -4) {
        const err = @ptrCast(*const c.git_error, c.git_error_last());
        debug.print("clone issue: ({}) {}\n", .{ status, @ptrCast([*:0]const u8, err.message) });
        return error.GitClone;
    }
}

fn git_path(self: Import, allocator: *Allocator, deps_dir: []const u8) ![]const u8 {
    return try std.cstr.addNullByte(
        allocator,
        try std.mem.join(allocator, std.fs.path.sep_str, &[_][]const u8{
            deps_dir,
            try git_url_to_name(self.url),
            self.version.?,
        }),
    );
}

fn git_url_to_name(url: []const u8) ![]const u8 {
    const https = "https://";
    const dot_git = ".git";

    // TODO: validate ssh url
    if (mem.startsWith(u8, url, https)) {
        const end = if (mem.endsWith(u8, url, dot_git)) url.len - dot_git.len else url.len;
        return url[https.len..end];
    }

    return error.UnsupportedUrl;
}
