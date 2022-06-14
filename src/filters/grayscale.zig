const std = @import("std");
const Image = @import("../Image.zig");

pub fn apply(dst: *Image.Managed, src: Image) !void {
    try dst.realloc(.{
        .width = src.descriptor.width,
        .height = src.descriptor.height,
        .components = 1,
    });

    var i: usize = 0;
    while (i < dst.descriptor.pixels()) : (i += 1) {
        var total: f32 = 0;
        for (src.flatPixel(i)) |channel| {
            total += channel;
        }
        dst.flatPixel(i)[0] = total / @intToFloat(f32, src.descriptor.components);
    }
}
