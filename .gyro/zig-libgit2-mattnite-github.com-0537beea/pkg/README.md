# libgit2 build package

[![ci](https://github.com/mattnite/zig-libgit2/actions/workflows/ci.yml/badge.svg)](https://github.com/mattnite/zig-libgit2/actions/workflows/ci.yml)

## Like this project?

If you like this project or other works of mine, please consider [donating to or sponsoring me](https://github.com/sponsors/mattnite) on Github [:heart:](https://github.com/sponsors/mattnite)

## How to use

This repo contains code for your `build.zig` that can statically compile libgit2, you will be able to include libgit2's header with:

```zig
const c = @cImport({
    @cInclude("git2.h");
});
```

### Link to your application

In order to statically link libgit2 into your application:

```zig
const libgit2 = @import("path/to/libgit2.zig");

pub fn build(b: *std.build.Builder) void {
    // ...

    const lib = libgit2.create(b, target, mode);

    const exe = b.addExecutable("my-program", "src/main.zig");
    lib.link(exe);
}
```
