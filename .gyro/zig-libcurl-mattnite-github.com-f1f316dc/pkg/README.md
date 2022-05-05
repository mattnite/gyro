# libcurl build package

[![ci](https://github.com/mattnite/zig-libcurl/actions/workflows/ci.yml/badge.svg)](https://github.com/mattnite/zig-libcurl/actions/workflows/ci.yml)

## Like this project?

If you like this project or other works of mine, please consider [donating to or sponsoring me](https://github.com/sponsors/mattnite) on Github [:heart:](https://github.com/sponsors/mattnite)

## How to use

This repo contains code for your `build.zig` that can statically compile libcurl, as well as some idiomatic Zig bindings for libcurl that you can use in your application. In either case below you will be able to include libcurls header with:

```zig
const c = @cImport({
    @cInclude("curl/curl.h");
});
```

### Link and add bindings to your application

In order to statically link libcurl into your application and access the bindings with a configurable import string:

```zig
const libcurl = @import("path/to/libcurl.zig");

pub fn build(b: *std.build.Builder) void {
    // ...

    const lib = libcurl.create(b, target, mode);

    const exe = b.addExecutable("my-program", "src/main.zig");
    lib.link(exe, .{ .import_name = "curl" });
}
```

Now code that is part of the `my-program` executable can import the libcurl bindings with `@import("curl")`.

### Only link to your application

In order to just link to the application, all you need to do is omit the `.import_name = "curl"` argument to libcurl's link options:

```zig
    lib.link(exe, .{});
```
