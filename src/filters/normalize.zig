//! This filter normalizes the value in the image to a scale from 0-1.

const std = @import("std");
const ColorImage = @import("../image.zig").ColorImage;

pub fn apply(image: ColorImage) void {
    const pixels = image.pixels();

    var min: f32 = std.math.f32_max;
    var max: f32 = std.math.f32_min;

    for (pixels) |pixel| {
        for (pixel) |channel| {
            if (channel < min) min = channel;
            if (channel > max) max = channel;
        }
    }

    const inv_diff = 1 / (max - min);
    for (pixels) |*pixel| {
        for (pixel.*) |*channel| {
            channel.* = (channel.* - min) * inv_diff;
        }
    }
}
