const std = @import("std");
const assert = std.debug.assert;
const Image = @import("../Image.zig");

pub const Options = struct {
    min_stddev: f32 = 4,
};

fn imageMean(image: Image) f32 {
    var total: f32 = 0;
    for (image.data()) |channel| {
        total += channel;
    }
    return total / @intToFloat(f32, image.descriptor.size());
}

fn imageVariance(image: Image, mean: f32) f32 {
    var variance: f32 = 0;
    for (image.data()) |channel| {
        const diff = channel - mean;
        variance += diff * diff;
    }
    return variance / @intToFloat(f32, image.descriptor.size());
}

pub fn apply(dst: *Image.Managed, src: Image, opts: Options) !void {
    assert(src.descriptor.components == 1);
    try dst.realloc(src.descriptor);

    const mean = imageMean(src);
    const variance = imageVariance(src, mean);
    const stddev = @sqrt(variance);

    const result_data = dst.data();
    for (src.data()) |channel, i| {
        if (channel > opts.min_stddev * stddev + mean) {
            result_data[i] = 1;
        } else {
            result_data[i] = 0;
        }
    }
}
