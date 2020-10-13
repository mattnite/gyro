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

fn fetch_submodule(submodule: ?*c.git_submodule, name: [*c]const u8, payload: ?*c_void) callconv(.C) c_int {
    const repo = @ptrCast(*c.git_repository, payload);
    var status = c.git_submodule_set_fetch_recurse_submodules(repo, name, @intToEnum(c.git_submodule_recurse_t, 1));
    if (status == -1) return status;

    var opts: c.git_submodule_update_options = undefined;
    status = c.git_submodule_update_options_init(&opts, c.GIT_SUBMODULE_UPDATE_OPTIONS_VERSION);
    if (status == -1) return status;

    return c.git_submodule_update(submodule, 1, &opts);
}

fn git_fetch(self: Import, allocator: *Allocator, deps_dir: []const u8) !void {
    var repo: ?*c.git_repository = undefined;
    var opts: c.git_clone_options = undefined;

    var status = c.git_clone_options_init(&opts, c.GIT_CLONE_OPTIONS_VERSION);
    if (status == -1) {
        return error.GitCloneOptionsInit;
    }

    opts.checkout_branch = self.version.?.ptr;

    const location = try self.path(self, allocator, deps_dir);
    defer allocator.free(location);

    const url = try std.cstr.addNullByte(allocator, self.url);
    defer allocator.free(url);

    debug.print("location: {}\n", .{location});
    status = c.git_clone(&repo, url, location.ptr, &opts);
    if (status < 0 and status != -4) {
        //const err = @ptrCast(*const c.git_error, c.git_error_last());
        //debug.print("clone issue: ({}) {}\n", .{ status, @ptrCast([*:0]const u8, err.message) });
        return error.GitClone;
    }

    // recursively checkout submodules
    status = c.git_submodule_foreach(repo, fetch_submodule, repo);
    if (status == -1) {
        return error.RecursiveSubmoduleCheckout;
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
