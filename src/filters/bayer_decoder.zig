const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");

pub const BayerMatrix = enum {
    rg_gb,
};

pub fn apply(a: Allocator, matrix: BayerMatrix, image: Image) !Image {
    assert(matrix == .rg_gb); // TODO: others?
    assert(image.descriptor.components == 1);

    const result = try Image.alloc(a, .{
        .width = @divExact(image.descriptor.width, 2),
        .height = @divExact(image.descriptor.height, 2),
        .components = 3,
    });
    errdefer result.free(a);

    var y: usize = 0;
    while (y < result.descriptor.height) : (y += 1) {
        var x: usize = 0;
        while (x < result.descriptor.width) : (x += 1) {
            const r = image.pixel(x * 2, y * 2)[0];
            const g0 = image.pixel(x * 2, y * 2 + 1)[0];
            const g1 = image.pixel(x * 2 + 1, y * 2)[0];
            const b = image.pixel(x * 2 + 1, y * 2 + 1)[0];
            const pixel = result.pixel(x, y);
            pixel[0] = r;
            pixel[1] = (g0 + g1) / 2;
            pixel[2] = b;
        }
    }

    return result;
}
