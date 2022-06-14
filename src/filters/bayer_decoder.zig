const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");

pub const BayerMatrix = enum {
    rg_gb,
};

pub fn apply(dst: *Image.Managed, src: Image, matrix: BayerMatrix) !void {
    assert(matrix == .rg_gb); // TODO: others?
    assert(src.descriptor.components == 1);

    try dst.realloc(.{
        .width = @divExact(src.descriptor.width, 2),
        .height = @divExact(src.descriptor.height, 2),
        .components = 3,
    });

    var y: usize = 0;
    while (y < dst.descriptor.height) : (y += 1) {
        var x: usize = 0;
        while (x < dst.descriptor.width) : (x += 1) {
            const r = src.pixel(x * 2, y * 2)[0];
            const g0 = src.pixel(x * 2, y * 2 + 1)[0];
            const g1 = src.pixel(x * 2 + 1, y * 2)[0];
            const b = src.pixel(x * 2 + 1, y * 2 + 1)[0];
            const pixel = dst.pixel(x, y);
            pixel[0] = r;
            pixel[1] = (g0 + g1) / 2;
            pixel[2] = b;
        }
    }
}
