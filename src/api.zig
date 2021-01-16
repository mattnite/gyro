const std = @import("std");
const version = @import("version");
const zfetch = @import("zfetch");
const http = @import("hzzp");
const tar = @import("tar");
const zzz = @import("zzz");
const zuri = @import("uri");
const Dependency = @import("Dependency.zig");
usingnamespace @import("common.zig");

const Allocator = std.mem.Allocator;
pub const default_repo = "astrolabe.pm";

// TODO: clean up duplicated code in this file

pub fn getLatest(
    allocator: *Allocator,
    repository: []const u8,
    package: []const u8,
    range: version.Range,
) !version.Semver {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://{s}/pkgs/{s}/latest?v={}",
        .{
            repository,
            package,
            range,
        },
    );
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    const uri = try zuri.Uri.parse(url, true);
    var ip_buf: [80]u8 = undefined;
    var stream = std.io.fixedBufferStream(&ip_buf);

    try headers.set("Host", switch (uri.host) {
        .name => |name| name,
        .ip => |ip| blk: {
            try stream.writer().print("{}", .{ip});
            break :blk stream.getWritten();
        },
    });
    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    try req.commit(.GET, headers, null);
    try req.fulfill();

    if (req.status.code != 200) {
        std.log.err("got http status code: {}", .{req.status.code});
        return error.FailedRequest;
    }

    var buf: [10]u8 = undefined;
    return version.Semver.parse(buf[0..try req.reader().readAll(&buf)]);
}

pub fn getHeadCommit(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
    ref: []const u8,
) ![]const u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        // TODO: fix api call once Http redirects are handled
        //"https://api.github.com/repos/{s}/{s}/tarball/{s}",
        "https://codeload.github.com/{s}/{s}/legacy.tar.gz/{s}",
        .{
            user,
            repo,
            ref,
        },
    );
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    try headers.set("Host", "codeload.github.com");
    try headers.set("Accept", "*/*");
    try headers.set("User-Agent", "gyro");

    try req.commit(.GET, headers, null);
    try req.fulfill();

    if (req.status.code != 200) {
        std.log.err("got http status code: {}", .{req.status.code});
        return error.FailedRequest;
    }

    var gzip = try std.compress.gzip.gzipStream(allocator, req.reader());
    defer gzip.deinit();

    var pax_header = try tar.PaxHeaderMap.init(allocator, gzip.reader());
    defer pax_header.deinit();

    return allocator.dupe(u8, pax_header.get("comment") orelse return error.MissingCommitKey);
}

fn getManifest(
    allocator: *Allocator,
    repository: []const u8,
    package: []const u8,
    semver: version.Semver,
) ![]const u8 {
    const url = try std.fmt.allocPrint(allocator, "https://{s}/pkgs/{s}/{}/manifest", .{
        repository,
        package,
        semver,
    });
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    if (req.status.code != 200) {
        std.log.err("got http status code: {}", .{req.status.code});
        return error.FailedRequest;
    }

    try req.commit(.GET, headers, null);
    try req.fulfill();

    return req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
}

pub const DependencyResult = struct {
    deps: []Dependency,
    text: []const u8,
};

pub fn getDependencies(
    allocator: *Allocator,
    repository: []const u8,
    package: []const u8,
    semver: version.Semver,
) !DependencyResult {
    var text = try getManifest(allocator, repository, package, semver);
    errdefer allocator.free(text);

    var deps = std.ArrayListUnmanaged(Dependency){};

    var tree = zzz.ZTree(1, 100){};
    var root = try tree.appendText(text);
    if (zFindChild(root, "deps")) |deps_node| {
        var it = ZChildIterator.init(deps_node);
        while (it.next()) |node| try deps.append(allocator, try Dependency.fromZNode(node));
    }

    return DependencyResult{
        .deps = deps.items,
        .text = text,
    };
}

pub fn getRoot(
    allocator: *Allocator,
    repository: []const u8,
    package: []const u8,
    semver: version.Semver,
) ![]const u8 {
    var text = try getManifest(allocator, repository, package, semver);
    defer allocator.free(text);

    var tree = zzz.ZTree(1, 100){};
    var root = try tree.appendText(text);
    const root_path = (try zFindString(root, "root")) orelse return error.NoRoot;
    return try allocator.dupe(u8, root_path);
}

pub fn getPkg(
    allocator: *Allocator,
    repository: []const u8,
    package: []const u8,
    semver: version.Semver,
    dir: std.fs.Dir,
) !void {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://{s}/archive/{s}/{}",
        .{
            repository,
            package,
            version,
        },
    );
    defer allocator.free(url);

    try getTarGz(allocator, url, dir);
}

fn getTarGzImpl(
    allocator: *Allocator,
    url: []const u8,
    dir: std.fs.Dir,
    skip_depth: usize,
) !void {
    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    const uri = try zuri.Uri.parse(url, true);
    if (@as(zuri.Uri.Host, uri.host) == .ip) return error.NotSupportedYet;

    try headers.set("Host", uri.host.name);
    try headers.set("Accept", "*/*");
    try headers.set("User-Agent", "gyro");

    try req.commit(.GET, headers, null);
    try req.fulfill();

    if (req.status.code != 200) {
        std.log.err("got http status code: {}", .{req.status.code});
        return error.FailedRequest;
    }

    var gzip = try std.compress.gzip.gzipStream(allocator, req.reader());
    defer gzip.deinit();

    try tar.instantiate(allocator, dir, gzip.reader(), skip_depth);
}

pub fn getTarGz(
    allocator: *Allocator,
    url: []const u8,
    dir: std.fs.Dir,
) !void {
    try getTarGzImpl(allocator, url, dir, 0);
}

pub fn getGithubTarGz(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
    commit: []const u8,
    dir: std.fs.Dir,
) !void {
    const url = try std.fmt.allocPrint(
        allocator,
        // TODO: fix api call once Http redirects are handled
        //"https://api.github.com/repos/{s}/{s}/tarball/{s}",
        "https://codeload.github.com/{s}/{s}/legacy.tar.gz/{s}",
        .{
            user,
            repo,
            commit,
        },
    );
    defer allocator.free(url);

    try getTarGzImpl(allocator, url, dir, 1);
}

pub fn getGithubRepo(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
) !std.json.ValueTree {
    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}", .{ user, repo });
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    try headers.set("Host", "api.github.com");
    try headers.set("Accept", "application/vnd.github.v3+json");
    try headers.set("User-Agent", "gyro");

    try req.commit(.GET, headers, null);
    try req.fulfill();

    if (req.status.code != 200) {
        std.log.err("got http status code: {}", .{req.status.code});
        return error.Explained;
    }

    var text = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(text);

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    return try parser.parse(text);
}

pub fn getGithubTopics(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
) !std.json.ValueTree {
    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/topics", .{ user, repo });
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    try headers.set("Host", "api.github.com");
    try headers.set("Accept", "application/vnd.github.mercy-preview+json");
    try headers.set("User-Agent", "gyro");

    try req.commit(.GET, headers, null);
    try req.fulfill();

    if (req.status.code != 200) {
        std.log.err("got http status code: {}", .{req.status.code});
        return error.Explained;
    }

    var text = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(text);

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    return try parser.parse(text);
}
