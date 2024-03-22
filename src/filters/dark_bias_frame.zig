const std = @import("std");
const Image = @import("../Image.zig");

pub const Options = struct {
    dark_frame_multiplier: f32 = 1,
};

pub fn apply(image: Image, maybe_dark: ?Image, maybe_bias: ?Image, opts: Options) void {
    if (maybe_dark) |dark| {
        const dark_data = dark.data();
        if (maybe_bias) |bias| {
            const bias_data = bias.data();
            for (image.data(), 0..) |*channel, i| {
                channel.* = channel.* - dark_data[i] * opts.dark_frame_multiplier - bias_data[i];
            }
        } else {
            for (image.data(), 0..) |*channel, i| {
                channel.* = channel.* - dark_data[i] * opts.dark_frame_multiplier;
            }
        }
    } else if (maybe_bias) |bias| {
        const bias_data = bias.data();
        for (image.data(), 0..) |*channel, i| {
            channel.* = channel.* - bias_data[i];
        }
    }
}
