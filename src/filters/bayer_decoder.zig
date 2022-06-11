const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const GrayscaleImage = @import("../image.zig").GrayscaleImage;
const ColorImage = @import("../image.zig").ColorImage;

pub const BayerMatrix = enum {
    rg_gb,
};

pub fn apply(a: Allocator, matrix: BayerMatrix, image: GrayscaleImage) !ColorImage {
    assert(matrix == .rg_gb); // TODO: others?
    const result = try ColorImage.alloc(a, @divExact(image.width, 2), @divExact(image.height, 2));
    errdefer result.free(a);

    var y: usize = 0;
    while (y < result.height) : (y += 1) {
        var x: usize = 0;
        while (x < result.width) : (x += 1) {
            const r = image.get(x * 2,      y * 2)[0];
            const g0 = image.get(x * 2 + 1, y * 2)[0];
            const g1 = image.get(x * 2,     y * 2 + 1)[0];
            const b = image.get(x * 2 + 1,  y * 2 + 1)[0];
            result.set(x, y, .{
                r,
                (g0 + g1) / 2,
                b,
            });
        }
    }

    return result;
}
