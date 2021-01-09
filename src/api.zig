const std = @import("std");
const version = @import("version");
const zfetch = @import("zfetch");
const http = @import("hzzp");

pub const default_repo = "astrolabe.pm";

pub fn getLatest(
    allocator: *std.mem.Allocator,
    repository: []const u8,
    package: []const u8,
    range: version.Range,
) !version.Semver {
    const url = try std.fmt.allocPrint(allocator, "https://{s}/packages/{s}/latest?min={}.{}.{}&less_than={}.{}.{}", .{
        repository,
        package,
        range.min.major,
        range.min.minor,
        range.min.patch,
        range.less_than.major,
        range.less_than.minor,
        range.less_than.patch,
    });
    defer allocator.free(url);

    var headers = http.Headers.init(allocator);
    defer headers.deinit();

    // TODO: parse repository as a url and handle situations where the
    // repository includes a uri path
    try headers.set("Host", repository);

    var req = try zfetch.Request.init(allocator, url);
    defer req.deinit();

    try req.commit(.GET, headers, null);
    try req.fulfill();

    var buf: [10]u8 = undefined;
    // TODO: uncomment when api is up
    //return version.Semver.parse(buf[0..try req.reader().readAll(&buf)]);
    return version.Semver{ .major = 0, .minor = 1, .patch = 0 };
}

pub fn getHeadCommit(
    allocator: *std.mem.Allocator,
    user: []const u8,
    repo: []const u8,
    ref: []const u8,
) ![]const u8 {
    return error.Todo;
}

pub fn getDependencies(
    allocator: *std.mem.Allocator,
    repository: []const u8,
    package: []const u8,
    semver: version.Semver,
) ![]const u8 {
    return error.Todo;
}
