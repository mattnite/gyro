# libssh2 build package

[![ci](https://github.com/mattnite/zig-libssh2/actions/workflows/ci.yml/badge.svg)](https://github.com/mattnite/zig-libssh2/actions/workflows/ci.yml)

## Like this project?

If you like this project or other works of mine, please consider [donating to or sponsoring me](https://github.com/sponsors/mattnite) on Github [:heart:](https://github.com/sponsors/mattnite)

## How to use

This repo contains code for your `build.zig` that can statically compile libssh2.

### Link to your application

In order to statically link libssh2 into your application:

```zig
const libssh2 = @import("path/to/libssh2.zig");

pub fn build(b: *std.build.Builder) void {
    // ...

    const lib = libssh2.create(b, target, mode);

    const exe = b.addExecutable("my-program", "src/main.zig");
    lib.link(exe);
}
```
