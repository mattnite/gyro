# Zkg: a Zig Package Manager

[![Linux](https://github.com/mattnite/zkg/workflows/Linux/badge.svg)](https://github.com/mattnite/zkg/actions) [![macOS](https://github.com/mattnite/zkg/workflows/macOS/badge.svg)](https://github.com/mattnite/zkg/actions) [![windows](https://github.com/mattnite/zkg/workflows/windows/badge.svg)](https://github.com/mattnite/zkg/actions)


This project is merely a prototype exploring a simple packaging use case for
zig, inspiration is taken from nix.

## Methodology

To quote Andrew:

```
In summary, Zig's package manager will be a glorified downloading tool, that
provides analysis and details to help the human perform the social process of
choosing what set of other people's code to rely on, but without any central
appeal to authority.
```
[reference](https://github.com/ziglang/zig/issues/943#issuecomment-586386891)

And zkg is exactly that. We parse an `imports.zzz` file that you place in the
root directory of your project, fetch the packages
then generate a `deps.zig` file in the project root that exports an array of
`std.build.Pkg`.  These `Pkgs` can then be used in `build.zig`.

## Dependencies

This is a static executable with no runtime dependencies

## Basics

This example can be found
[here](https://github.com/mattnite/zkg/tree/master/tests/example).
`zkg-example` is a program that uses
[zig-clap](https://github.com/Hejsil/zig-clap) and
[ctregex](https://github.com/alexnask/ctregex). Shout out to Hejsil for
`zig-clap` and alexnask for `ctregex`!

The manifest file format that zkg uses is
[zzz](https://github.com/gruebite/zzz), it's a pared down yaml-like format.

```yaml
clap:
  root: /clap.zig
  src:
    github:
      user: Hejsil
      repo: zig-clap
      ref: master

regex:
  root: /ctregex.zig
  src:
    github:
      user: alexnask
      repo: ctregex.zig
      ref: master
```

The string used as the key for an import is important because it will be the
string that you use in your application code to `@import` the package. Eg:

```zig
const regex = @import("regex");
```

Run `zkg fetch` in your project root to generate the `deps.zig` file (too
simple to have arguments right now), the contents will look like this:

```zig
pub const pkgs = .{
    .clap = .{
        .name = "clap",
        .path = "zig-deps/c4b83c48d69c7c056164009b9c8b459a/clap.zig",
    },
    .regex = .{
        .name = "regex",
        .path = "zig-deps/3601c1a709d175ba663ba72ca5a463a4/ctregex.zig",
    },
};
```

And here is `build.zig` where we add the packages to our project:

```zig
const std = @import("std");
const Builder = std.build.Builder;
const pkgs = @import("deps.zig").pkgs;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zag-example", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    inline for (std.meta.fields(@TypeOf(pkgs))) |field| {
        exe.addPackage(@field(pkgs, field.name));
    }
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

## ziglibs Integration

`zkg` has integrations with the [zpm\_server](https://github.com/zigtools/zpm-server),
this allows anyone to run their own simple package index. `zkg` by default
queries the [zpm index](https://zpm.random-projects.net), but can point to
different servers using the `--remote` argument. The following subsections
demonstrate the different subcommands.

### add

To add a package from the `zpm` index all we need to do is `zkg add <name>`.
Let's say we need ssl, in that case we could grab the Zig bindings for
[bearssl](https://github.com/MasterQ32/zig-bearssl) by running `zkg add
bearssl`, and we'd see `imports.zig` would have the following contents:

```yaml
bearssl:
  root: /bearssl.zig
  src:
    github:
      user: MasterQ32
      repo: zig-bearssl
      ref: master
```

It should also be noted that `zig-bearssl` contains a git submodule, git
submodules are recursively checked out. `zkg` uses the key string as the string
literal used when importing the package (Eg: `const my_lib =
@import("bearssl")`. If you want to change what that string shows, you can
easily edit `imports.zzz` or you can invoke like so: `zkg add bearssl --alias
ssl`. Now we can:

```zig
const my_lib = @import("ssl");
```

Now if you have a personal or corporate `zpm-server`, you can add packages from
those remotes like so: `zkg add somelib --remote http://localhost:8080`. Mixing
from different remotes is trivial.

### search

`zkg search` will print a table of all the packages in an index, and can filter
on `--author`, `--name`, or `--tag`. An example of looking at the networking
tag:

```
$ zkg search --tag networking

NAME       AUTHOR      DESCRIPTION
bpf        mattnite    A BPF Library for Zig
uri        xq          A small URI parser that parses URIs after RFC3986
apple_pie  Luukdegram  Basic HTTP server implementation in Zig
bearssl    xq          A BearSSL binding for Zig
network    xq          A smallest-common-subset of socket functions for crossplatform networking, TCP & UDP
```

`search` works predictably with the `--remote` argument.

### fetch

`zkg fetch` takes no additional arguments, it's invoked once you've declared
your dependencies in `imports.zzz` and it will fetch them into `zig-deps/` with
an index file `deps.zig`. The index file can be directly imported into
`build.zig` and then packages can be `addPackage()`'d to your executables and
libraries. (or packages can be imported in the build script)

Note that `zkg` recursively fetches dependencies if they also contain
`imports.zzz` in the package root.

### tags

`zkg tags` lists all the tags on an index, at the time of writing, here's what's
shown for the `zpm` index:

```
$ zkg tags

TAG                   DESCRIPTION
hardware              Packages that deal with hardware abstraction.
networking            Packages that are related to networking applications.
game                  Package that are related to game development.
binding               Packages that are bindings to foreign libraries.
meta                  A package that provides new features to the language.
os                    Packages that are related to interfacing the operating system.
string                Packages that provide advanced string/text manipulation.
programming-language  Embedded programming languages usable from Zig
crypto                Any package that is related to cryptographic algorithms.
serialization         Packages that are related to file formats, either providing saving/loading or both.
math                  Packages that provide advanced math functionality.
terminal              Packages that assist in dealing with terminal input, output, and user interfaces.
```

`tags` works predictably with the `--remote` argument.

### remove

To remove an entry from `imports.zzz` just `zkg remove <key>`.
