# Zkg: a Zig Package Manager

![Linux](https://github.com/mattnite/zkg/workflows/Linux/badge.svg) ![macOS](https://github.com/mattnite/zkg/workflows/macOS/badge.svg)

This project is merely a prototype exploring a simple packaging use case for
zig, and that's including source from zig-only projects in git repositories.
Right now it will only fetch using https.

## Methodology

To quote Andrew:

```
In summary, Zig's package manager will be a glorified downloading tool, that
provides analysis and details to help the human perform the social process of
choosing what set of other people's code to rely on, but without any central
appeal to authority.
```
[reference](https://github.com/ziglang/zig/issues/943#issuecomment-586386891)

And zkg is exactly that. We parse an `imports.zig` file that you place in the
root directory of your project, fetch the packages described using `libgit2`,
then generate a `packages.zig` file in `zig-cache` that exports an array of
`std.build.Pkg`.  These `Pkgs` can then be used in `build.zig`.

Originally I was parsing `imports.zig` at runtime which greatly limited the
things you could do in that file, but now zkg builds runner executables which
include the imports file at comptime so you can now leverage zig properly!

## Dependencies

- `libgit2` as a system library

## Basics

This example can be found [here](https://github.com/mattnite/zkg-example). To
get started you need to set one environment variable: `ZKG\_LIB`. This is the
directory some files required by zkg can be found, after building they will be
found in `zig-cache/lib/zig/zkg`.

`zkg-example` is a program that uses
[zig-clap](https://github.com/Hejsil/zig-clap) and
[ctregex](https://github.com/alexnask/ctregex). Shout out to Hejsil for
`zig-clap` and alexnask for `ctregex`!

Here is the `imports.zig`:

```zig
const zkg = @import("zkg");

pub const clap = zkg.import.git(
    "https://github.com/Hejsil/zig-clap.git",
    "master",
    "clap.zig",
);

pub const regex = zkg.import.git(
    "https://github.com/alexnask/ctregex.zig.git",
    "master",
    "ctregex.zig",
);
```

The arguments for `zig.import.git()` are the url of the repo, the branch, and
optionally you may tell zkg what the root file you want to include as the base
of the package. If null is given zkg will look for a file called `exports.zig`
in the root of the dependency.

The name of the exported variable is important because it will be the string
that you use in your application code to `@import` the package. Eg:

```zig
const regex = @import("regex");
```

Run `zkg fetch` in your project root to generate the `packages.zig` file (too
simple to have arguments right now), the contents will look like this:

```zig
const std = @import("std");
const Pkg = std.build.Pkg;

pub const list = [_]Pkg{
    Pkg{
        .name = "clap",
        .path = "/home/mknight/.cache/zkg/github.com/Hejsil/zig-clap/master/clap.zig",
        .dependencies = null,
    },
    Pkg{
        .name = "regex",
        .path = "/home/mknight/.cache/zkg/github.com/alexnast/ctregex.zig/master/exports.zig",
        .dependencies = null,
    },
};
```

And here is `build.zig` where we add the `Pkg`s to our project:

```zig
const Builder = @import("std").build.Builder;
const packages = @import("zig-cache/packages.zig").list;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zkg-example", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    for (packages) |pkg| {
        exe.addPackage(pkg);
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

### init

`imports.zig` needs to be initialized correctly before `zkg` can do its magic
and to do that we just need to run `zkg init`. It creates the file in the
current directory with the following contents:

```zig
const zkg = @import("zkg");
```

Now we can start adding our packages.

### add

To add a package from the `zpm` index all we need to do is `zkg add <name>`.
Let's say we need ssl, in that case we could grab the Zig bindings for
[bearssl](https://github.com/MasterQ32/zig-bearssl) by running `zkg add
bearssl`, and we'd see `imports.zig` would have the following contents:

```zig
const zkg = @import("zkg");

pub const bearssl = zkg.import.git(
    "https://github.com/MasterQ32/zig-bearssl",
    "master",
    "/bearssl.zig",
);
```

It should also be noted that `zig-bearssl` contains a git submodule, git
submodules are recursively checked out. `zkg` uses the declaration name (where
it says `pub const bearssl`) as the string literal used when importing the
package (Eg: `const my_lib = @import("bearssl")`. If you want to change what that
string shows, you can easily edit `imports.zig` or you can invoke like so: `zkg
add bearssl --alias ssl`. Now we can:

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
your dependencies in `import.zig` and it will fetch/clone them into
`zig-cache/deps` with an index file `zig-cache/packages.zig`. The index file can
be directly imported into `build.zig` and then packages can be `addPackage()`'d
to your executables and libraries.

Note that `zkg` recursively fetches dependencies if they also contain
`imports.zig` in the package root.

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

This subcommand isn't implemented yet, you're going to have to remove packages
from `imports.zig` manually for now.
