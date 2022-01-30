const std = @import("std");
const version = @import("version");
const tar = @import("tar");
const zzz = @import("zzz");
const Dependency = @import("Dependency.zig");
const Package = @import("Package.zig");
const utils = @import("utils.zig");
const curl = @import("curl");

const Allocator = std.mem.Allocator;
const Fifo = std.fifo.LinearFifo(u8, .{ .Dynamic = {} });

pub fn getLatest(
    allocator: Allocator,
    repository: []const u8,
    user: []const u8,
    package: []const u8,
    range: ?version.Range,
) !version.Semver {
    const url = if (range) |r|
        try std.fmt.allocPrintZ(allocator, "https://{s}/pkgs/{s}/{s}/latest?v={}", .{
            repository,
            user,
            package,
            r,
        })
    else
        try std.fmt.allocPrintZ(allocator, "https://{s}/pkgs/{s}/{s}/latest", .{
            repository,
            user,
            package,
        });
    defer allocator.free(url);

    var fifo = Fifo.init(allocator);
    defer fifo.deinit();

    const easy = try curl.Easy.init();
    defer easy.cleanup();

    try easy.setUrl(url);
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.perform();

    const status_code = try easy.getResponseCode();
    switch (status_code) {
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
        else => {
            const stderr = std.io.getStdErr().writer();
            try stderr.print("got http status code for {s}: {}", .{ url, status_code });
            try stderr.print("{s}\n", .{fifo.readableSlice(0)});
            return error.Explained;
        },
    }

    return version.Semver.parse(allocator, fifo.readableSlice(0));
}

pub const XferCtx = struct {
    cb: curl.XferInfoFn,
    data: ?*anyopaque,
};

pub fn getPkg(
    allocator: Allocator,
    repository: []const u8,
    user: []const u8,
    package: []const u8,
    semver: version.Semver,
    dir: std.fs.Dir,
    xfer_ctx: ?XferCtx,
) !void {
    const url = try std.fmt.allocPrintZ(
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

    try getTarGz(allocator, url, dir, xfer_ctx);
}

// not a super huge fan of allocating the entire response over streaming, but
// it'll do for now, at least it's compressed lol
fn getTarGzImpl(
    allocator: Allocator,
    url: [:0]const u8,
    dir: std.fs.Dir,
    skip_depth: usize,
    xfer: ?XferCtx,
) !void {
    var fifo = Fifo.init(allocator);
    defer fifo.deinit();

    var headers = curl.HeaderList.init();
    defer headers.freeAll();

    try headers.append("Accept: */*");
    const easy = try curl.Easy.init();
    defer easy.cleanup();

    try easy.setUrl(url);
    try easy.setHeaders(headers);
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    if (xfer) |x| {
        try easy.setXferInfoFn(x.cb);
        if (x.data) |data|
            try easy.setXferInfoData(data);

        try easy.setNoProgress(false);
    }

    try easy.perform();

    var gzip = try std.compress.gzip.gzipStream(allocator, fifo.reader());
    defer gzip.deinit();

    try tar.instantiate(allocator, dir, gzip.reader(), skip_depth);
}

pub fn getTarGz(
    allocator: Allocator,
    url: [:0]const u8,
    dir: std.fs.Dir,
    xfer_ctx: ?XferCtx,
) !void {
    try getTarGzImpl(allocator, url, dir, 0, xfer_ctx);
}

pub fn getGithubRepo(
    allocator: Allocator,
    user: []const u8,
    repo: []const u8,
) !std.json.ValueTree {
    const url = try std.fmt.allocPrintZ(
        allocator,
        "https://api.github.com/repos/{s}/{s}",
        .{ user, repo },
    );
    defer allocator.free(url);

    var fifo = Fifo.init(allocator);
    defer fifo.deinit();

    var headers = curl.HeaderList.init();
    defer headers.freeAll();

    try headers.append("Accept: application/vnd.github.v3+json");
    const easy = try curl.Easy.init();
    defer easy.cleanup();

    try easy.setUrl(url);
    try easy.setHeaders(headers);
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.perform();

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    return try parser.parse(fifo.readableSlice(0));
}

pub fn getGithubTopics(
    allocator: Allocator,
    user: []const u8,
    repo: []const u8,
) !std.json.ValueTree {
    const url = try std.fmt.allocPrintZ(allocator, "https://api.github.com/repos/{s}/{s}/topics", .{ user, repo });
    defer allocator.free(url);

    var fifo = Fifo.init(allocator);
    defer fifo.deinit();

    var headers = curl.HeaderList.init();
    defer headers.freeAll();

    try headers.append("Accept: application/vnd.github.mercy-preview+json");

    const easy = try curl.Easy.init();
    defer easy.cleanup();

    try easy.setUrl(url);
    try easy.setHeaders(headers);
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.perform();

    var parser = std.json.Parser.init(allocator, true);
    defer parser.deinit();

    return try parser.parse(fifo.readableSlice(0));
}

pub const DeviceCodeResponse = struct {
    device_code: []const u8,
    user_code: []const u8,
    verification_uri: []const u8,
    expires_in: u64,
    interval: u64,
};

pub fn postDeviceCode(
    allocator: Allocator,
    client_id: []const u8,
    scope: []const u8,
) !DeviceCodeResponse {
    const url = "https://github.com/login/device/code";
    const payload = try std.fmt.allocPrint(allocator, "client_id={s}&scope={s}", .{ client_id, scope });
    defer allocator.free(payload);

    var fbs = std.io.fixedBufferStream(payload);
    fbs.pos = payload.len;

    var fifo = Fifo.init(allocator);
    defer fifo.deinit();

    var headers = curl.HeaderList.init();
    defer headers.freeAll();

    try headers.append("Accept: application/json");

    const easy = try curl.Easy.init();
    defer easy.cleanup();

    try easy.setPost();
    try easy.setUrl(url);
    try easy.setHeaders(headers);
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.setReadFn(curl.readFromFbs(@TypeOf(fbs)));
    try easy.setReadData(&fbs);
    try easy.perform();

    var token_stream = std.json.TokenStream.init(fifo.readableSlice(0));
    return std.json.parse(DeviceCodeResponse, &token_stream, .{ .allocator = allocator });
}

const PollDeviceCodeResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    scope: []const u8,
};

pub fn pollDeviceCode(
    allocator: Allocator,
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

    var fbs = std.io.fixedBufferStream(payload);
    fbs.pos = payload.len;

    var fifo = Fifo.init(allocator);
    defer fifo.deinit();

    var headers = curl.HeaderList.init();
    defer headers.freeAll();

    try headers.append("Accept: application/json");

    const easy = try curl.Easy.init();
    defer easy.cleanup();

    try easy.setPost();
    try easy.setUrl(url);
    try easy.setHeaders(headers);
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.setReadFn(curl.readFromFbs(@TypeOf(fbs)));
    try easy.setReadData(&fbs);
    try easy.perform();

    var parser = std.json.Parser.init(allocator, false);
    defer parser.deinit();

    var value_tree = try parser.parse(fifo.readableSlice(0));
    defer value_tree.deinit();

    // TODO: error handling based on the json error codes
    return if (value_tree.root.Object.get("access_token")) |value| switch (value) {
        .String => |str| try allocator.dupe(u8, str),
        else => null,
    } else null;
}

pub fn postPublish(
    allocator: Allocator,
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

    const url = "https://" ++ utils.default_repo ++ "/publish";
    const payload = try file.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(payload);

    var fbs = std.io.fixedBufferStream(payload);
    fbs.pos = payload.len;

    var fifo = Fifo.init(allocator);
    defer fifo.deinit();

    const authorization_header = try std.fmt.allocPrintZ(allocator, "Authorization: Bearer github {s}", .{access_token});
    defer allocator.free(authorization_header);

    var headers = curl.HeaderList.init();
    defer headers.freeAll();

    try headers.append("Content-Type: application/octet-stream");
    try headers.append("Accept: */*");
    try headers.append(authorization_header);

    const easy = try curl.Easy.init();
    defer easy.cleanup();

    try easy.setPost();
    try easy.setUrl(url);
    try easy.setHeaders(headers);
    try easy.setSslVerifyPeer(false);
    try easy.setWriteFn(curl.writeToFifo(Fifo));
    try easy.setWriteData(&fifo);
    try easy.setReadFn(curl.readFromFbs(@TypeOf(fbs)));
    try easy.setReadData(&fbs);
    try easy.perform();

    const stderr = std.io.getStdErr().writer();
    defer stderr.print("{s}\n", .{fifo.readableSlice(0)}) catch {};
}
