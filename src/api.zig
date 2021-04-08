const std = @import("std");
const version = @import("version");
const zfetch = @import("zfetch");
const tar = @import("tar");
const zzz = @import("zzz");
const uri = @import("uri");
const Dependency = @import("Dependency.zig");
const Package = @import("Package.zig");
usingnamespace @import("common.zig");

const Allocator = std.mem.Allocator;

pub fn getLatest(
    allocator: *Allocator,
    repository: []const u8,
    user: []const u8,
    package: []const u8,
    range: ?version.Range,
) !version.Semver {
    const url = if (range) |r|
        try std.fmt.allocPrint(allocator, "https://{s}/pkgs/{s}/{s}/latest?v={}", .{
            repository,
            user,
            package,
            r,
        })
    else
        try std.fmt.allocPrint(allocator, "https://{s}/pkgs/{s}/{s}/latest", .{
            repository,
            user,
            package,
        });
    defer allocator.free(url);

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();

    const link = try uri.parse(url);
    var ip_buf: [80]u8 = undefined;
    var stream = std.io.fixedBufferStream(&ip_buf);

    try headers.set("Accept", "*/*");
    try headers.set("User-Agent", "gyro");
    try headers.set("Host", link.host orelse return error.NoHost);

    var req = try zfetch.Request.init(allocator, url, null);
    defer req.deinit();

    try req.do(.GET, headers, null);
    switch (req.status.code) {
        200 => {},
        404 => {
            if (range) |r| {
                std.log.err("failed to find {} for {s}/{s} on {s}", .{
                    r,
                    user,
                    package,
                    repository,
                });
            } else {
                std.log.err("failed to find latest for {s}/{s} on {s}", .{
                    user,
                    package,
                    repository,
                });
            }

            return error.Explained;
        },
        else => |code| {
            const body = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(body);

            const stderr = std.io.getStdErr().writer();
            try stderr.print("got http status code for {s}: {}", .{ url, req.status.code });
            try stderr.print("{s}\n", .{body});
            return error.Explained;
        },
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
        "https://api.github.com/repos/{s}/{s}/tarball/{s}",
        .{ user, repo, ref },
    );
    defer allocator.free(url);

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Accept", "*/*");
    var req = try request(allocator, .GET, url, &headers, null);
    defer req.deinit();

    var gzip = try std.compress.gzip.gzipStream(allocator, req.reader());
    defer gzip.deinit();

    var pax_header = try tar.PaxHeaderMap.init(allocator, gzip.reader());
    defer pax_header.deinit();

    return allocator.dupe(u8, pax_header.get("comment") orelse return error.MissingCommitKey);
}

pub fn getPkg(
    allocator: *Allocator,
    repository: []const u8,
    user: []const u8,
    package: []const u8,
    semver: version.Semver,
    dir: std.fs.Dir,
) !void {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://{s}/archive/{s}/{s}/{}",
        .{
            repository,
            user,
            package,
            semver,
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
    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();

    std.log.info("fetching tarball: {s}", .{url});

    try headers.set("Accept", "*/*");
    var req = try request(allocator, .GET, url, &headers, null);
    defer req.deinit();

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
        "https://api.github.com/repos/{s}/{s}/tarball/{s}",
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
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}",
        .{ user, repo },
    );
    defer allocator.free(url);

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Accept", "application/vnd.github.v3+json");
    var req = try request(allocator, .GET, url, &headers, null);
    defer req.deinit();

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

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Accept", "application/vnd.github.mercy-preview+json");
    var req = try request(allocator, .GET, url, &headers, null);
    defer req.deinit();

    var body = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(body);

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    return try parser.parse(body);
}

pub fn getGithubGyroFile(
    allocator: *Allocator,
    user: []const u8,
    repo: []const u8,
    commit: []const u8,
) !?[]const u8 {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/{s}/tarball/{s}",
        .{ user, repo, commit },
    );
    defer allocator.free(url);

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();

    std.log.info("fetching tarball: {s}", .{url});
    try headers.set("Accept", "*/*");
    var req = try request(allocator, .GET, url, &headers, null);
    defer req.deinit();

    const subpath = try std.fmt.allocPrint(allocator, "{s}-{s}-{s}/gyro.zzz", .{ user, repo, commit[0..7] });
    defer allocator.free(subpath);

    var gzip = try std.compress.gzip.gzipStream(allocator, req.reader());
    defer gzip.deinit();

    var extractor = tar.fileExtractor(subpath, gzip.reader());
    return extractor.reader().readAllAlloc(allocator, std.math.maxInt(usize)) catch |err|
        return if (err == error.FileNotFound) null else err;
}

pub const DeviceCodeResponse = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    expires_in: u64,
    interval: u64,
};

pub fn postDeviceCode(
    allocator: *Allocator,
    client_id: []const u8,
    scope: []const u8,
) !DeviceCodeResponse {
    const url = "https://github.com/login/device/code";
    const payload = try std.fmt.allocPrint(allocator, "client_id={s}&scope={s}", .{ client_id, scope });
    defer allocator.free(payload);

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Accept", "application/json");
    var req = try request(allocator, .POST, url, &headers, payload);
    defer req.deinit();

    const body = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(body);

    var token_stream = std.json.TokenStream.init(body);
    return std.json.parse(DeviceCodeResponse, &token_stream, .{ .allocator = allocator });
}

const PollDeviceCodeResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    scope: []const u8,
};

pub fn pollDeviceCode(
    allocator: *Allocator,
    client_id: []const u8,
    device_code: []const u8,
) !?[]const u8 {
    const url = "https://github.com/login/oauth/access_token";
    const payload = try std.fmt.allocPrint(
        allocator,
        "client_id={s}&device_code={s}&grant_type=urn:ietf:params:oauth:grant-type:device_code",
        .{ client_id, device_code },
    );
    defer allocator.free(payload);

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Accept", "application/json");
    var req = try request(allocator, .POST, url, &headers, payload);
    defer req.deinit();

    const body = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(body);

    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    var value_tree = try parser.parse(body);
    defer value_tree.deinit();

    // TODO: error handling based on the json error codes
    return if (value_tree.root.Object.get("access_token")) |value| switch (value) {
        .String => |str| try allocator.dupe(u8, str),
        else => null,
    } else null;
}

pub fn postPublish(
    allocator: *Allocator,
    access_token: []const u8,
    pkg: *Package,
) !void {
    try pkg.bundle(std.fs.cwd(), std.fs.cwd());

    const filename = try pkg.filename(allocator);
    defer allocator.free(filename);

    const file = try std.fs.cwd().openFile(filename, .{});
    defer {
        file.close();
        std.fs.cwd().deleteFile(filename) catch {};
    }

    const authorization = try std.fmt.allocPrint(allocator, "Bearer github {s}", .{access_token});
    defer allocator.free(authorization);

    const url = "https://" ++ @import("build_options").default_repo ++ "/publish";
    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();

    try headers.set("Content-Type", "application/octet-stream");
    try headers.set("Accept", "*/*");
    try headers.set("Authorization", authorization);

    const payload = try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(payload);

    var req = try request(allocator, .POST, url, &headers, payload);
    defer req.deinit();

    const body = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(body);

    const stderr = std.io.getStdErr().writer();
    defer stderr.print("{s}\n", .{body}) catch {};
}

// HTTP request with redirect
fn request(
    allocator: *std.mem.Allocator,
    method: zfetch.Method,
    url: []const u8,
    headers: *zfetch.Headers,
    payload: ?[]const u8,
) !*zfetch.Request {
    try headers.set("User-Agent", "gyro");

    var real_url = try allocator.dupe(u8, url);
    defer allocator.free(real_url);

    var redirects: usize = 0;
    return while (redirects < 128) {
        var ret = try zfetch.Request.init(allocator, real_url, null);
        const link = try uri.parse(real_url);
        try headers.set("Host", link.host orelse return error.NoHost);
        try ret.do(method, headers.*, payload);
        switch (ret.status.code) {
            200 => break ret,
            302 => {
                // tmp needed for memory safety
                const tmp = real_url;
                const location = ret.headers.get("location") orelse return error.NoLocation;
                real_url = try allocator.dupe(u8, location);
                allocator.free(tmp);

                ret.deinit();
            },
            else => {
                const body = try ret.reader().readAllAlloc(allocator, std.math.maxInt(usize));
                defer allocator.free(body);

                const stderr = std.io.getStdErr().writer();
                try stderr.print("got http status code for {s}: {}", .{ url, ret.status.code });
                try stderr.print("{s}\n", .{body});
                return error.Explained;
            },
        }
    } else return error.TooManyRedirects;
}
