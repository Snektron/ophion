const std = @import("std");
const assert = std.debug.assert;
const Image = @import("../Image.zig");

pub fn mean(image: Image) f32 {
    assert(image.descriptor.components == 1);
    var total: f32 = 0;
    for (image.data()) |channel| {
        total += channel;
    }
    return total / @intToFloat(f32, image.descriptor.size());
}

pub fn variance(image: Image, image_mean: f32) f32 {
    assert(image.descriptor.components == 1);
    var sqe: f32 = 0;
    for (image.data()) |channel| {
        const diff = channel - image_mean;
        sqe += diff * diff;
    }
    return sqe / @intToFloat(f32, image.descriptor.size());
}

pub fn stddev(image: Image, image_mean: f32) f32 {
    return @sqrt(variance(image, image_mean));
}
