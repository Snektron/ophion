//! This filter normalizes the value in the image to a scale from 0-1.

const std = @import("std");
const ColorImage = @import("../image.zig").ColorImage;

pub fn apply(image: ColorImage) void {
    const pixels = image.pixels();

    var min: f32 = std.math.f32_max;
    var max: f32 = std.math.f32_min;

    for (pixels) |pixel| {
        if (pixel.r < min) min = pixel.r;
        if (pixel.r > max) max = pixel.r;
        if (pixel.g < min) min = pixel.g;
        if (pixel.g > max) max = pixel.g;
        if (pixel.b < min) min = pixel.b;
        if (pixel.b > max) max = pixel.b;
    }

    const inv_diff = 1 / (max - min);
    for (pixels) |*pixel| {
        pixel.r = (pixel.r - min) * inv_diff;
        pixel.g = (pixel.g - min) * inv_diff;
        pixel.b = (pixel.b - min) * inv_diff;
    }
}
