usingnamespace std.os;
const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const c = @cImport({
    @cInclude("git2.h");
});

const default_root = "exports.zig";
const Allocator = std.mem.Allocator;

name: []const u8,
type: Type,
src: []const u8,
version: ?[]const u8,
root: ?[]const u8,

const Self = @This();

pub const Type = enum {
    git,

    pub fn toString(self: Type) []const u8 {
        inline for (std.meta.fields(Type)) |field| {
            if (@field(Type, field.name) == self) {
                return field.name;
            }
        }
    }

    pub fn fromString(str: []const u8) !Type {
        return inline for (std.meta.fields(Type)) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                break @field(Type, field.name);
            }
        } else error.InvalidTypeName;
    }
};

pub fn fetch(self: Self, allocator: *Allocator, deps_dir: []const u8) !void {
    return switch (self.type) {
        .git => self.gitFetch(allocator, deps_dir),
    };
}

pub fn path(self: Self, allocator: *Allocator, deps_dir: []const u8) ![]const u8 {
    return switch (self.type) {
        .git => self.gitPath(allocator, deps_dir),
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

fn fetchSubmodule(submodule: ?*c.git_submodule, name: [*c]const u8, payload: ?*c_void) callconv(.C) c_int {
    const repo = @ptrCast(*c.git_repository, payload);
    var status = c.git_submodule_set_fetch_recurse_submodules(repo, name, @intToEnum(c.git_submodule_recurse_t, 1));
    if (status == -1) return status;

    var opts: c.git_submodule_update_options = undefined;
    status = c.git_submodule_update_options_init(&opts, c.GIT_SUBMODULE_UPDATE_OPTIONS_VERSION);
    if (status == -1) return status;

    return c.git_submodule_update(submodule, 1, &opts);
}

fn gitFetch(self: Self, allocator: *Allocator, deps_dir: []const u8) !void {
    var repo: ?*c.git_repository = undefined;
    var opts: c.git_clone_options = undefined;

    var status = c.git_clone_options_init(&opts, c.GIT_CLONE_OPTIONS_VERSION);
    if (status == -1) {
        return error.GitCloneOptionsInit;
    }

    opts.checkout_branch = self.version.?.ptr;

    const location = try self.path(allocator, deps_dir);
    defer allocator.free(location);

    const url = try std.cstr.addNullByte(allocator, self.src);
    defer allocator.free(url);

    debug.print("location: {}\n", .{location});
    status = c.git_clone(&repo, url, location.ptr, &opts);
    if (status < 0 and status != -4) {
        //const err = @ptrCast(*const c.git_error, c.git_error_last());
        //debug.print("clone issue: ({}) {}\n", .{ status, @ptrCast([*:0]const u8, err.message) });
        return error.GitClone;
    }

    // recursively checkout submodules
    status = c.git_submodule_foreach(repo, fetchSubmodule, repo);
    if (status == -1) {
        return error.RecursiveSubmoduleCheckout;
    }
}

fn gitPath(self: Self, allocator: *Allocator, deps_dir: []const u8) ![]const u8 {
    return try std.cstr.addNullByte(
        allocator,
        try std.mem.join(allocator, std.fs.path.sep_str, &[_][]const u8{
            deps_dir,
            try gitUrlToName(self.src),
            self.version.?,
        }),
    );
}

fn gitUrlToName(url: []const u8) ![]const u8 {
    const https = "https://";
    const dot_git = ".git";

    // TODO: validate ssh url
    if (mem.startsWith(u8, url, https)) {
        const end = if (mem.endsWith(u8, url, dot_git)) url.len - dot_git.len else url.len;
        return url[https.len..end];
    }

    return error.UnsupportedUrl;
}
