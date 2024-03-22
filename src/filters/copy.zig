const std = @import("std");
const Image = @import("../Image.zig");

pub fn apply(dst: *Image.Managed, src: Image) !void {
    try dst.realloc(src.descriptor);
    @memcpy(dst.data(), src.data());
}
