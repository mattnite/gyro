# Zig Known Folders Project

## Design Goals

- Minimal API surface
- Provide the user with an option to either obtain a directory handle or a path name
- Keep to folders that are available on all operating systems

## API
```zig
pub const KnownFolder = enum {
    home,
    documents,
    pictures,
    music,
    videos,
    desktop,
    downloads,
    public,
    fonts,
    app_menu,
    cache,
    roaming_configuration,
    local_configuration,
    data,
    runtime,
    executable_dir,
};

pub const Error = error{ ParseError, OutOfMemory };

pub const KnownFolderConfig = struct {
    xdg_on_mac: bool = false,
};

/// Returns a directory handle, or, if the folder does not exist, `null`.
pub fn open(allocator: *std.mem.Allocator, folder: KnownFolder, args: std.fs.Dir.OpenDirOptions) (std.fs.Dir.OpenError || Error)!?std.fs.Dir;

/// Returns the path to the folder or, if the folder does not exist, `null`.
pub fn getPath(allocator: *std.mem.Allocator, folder: KnownFolder) Error!?[]const u8;
```

## Configuration
In your root file, add something like this to configure known-folders:

```zig
pub const known_folders_config = .{
    .xdg_on_mac = true,
}
```
