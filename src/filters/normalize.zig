//! This filter normalizes the value in the image to a scale from 0-1.
//! Filter operates in place.
const std = @import("std");
const Image = @import("../Image.zig");

pub fn apply(image: Image) void {
    const pixels = image.data();

    var min: f32 = std.math.floatMax(f32);
    var max: f32 = std.math.floatMin(f32);

    for (pixels) |channel| {
        if (channel < min) min = channel;
        if (channel > max) max = channel;
    }

    const inv_diff = 1 / (max - min);
    for (pixels) |*channel| {
        channel.* = (channel.* - min) * inv_diff;
    }
}
