pub const pkgs = struct {
    const std = @import("std");

    pub fn addAllTo(artifact: *std.build.LibExeObjStep) void {
        inline for (std.meta.declarations(@This())) |decl| {
            if (decl.is_pub and decl.data == .Var) {
                artifact.addPackage(@field(@This(), decl.name));
            }
        }
    }
};
