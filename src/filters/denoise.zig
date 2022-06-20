//! This filter normalizes the value in the image to a scale from 0-1.
//! Filter operates in place.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");

pub const Denoiser = struct {
    a: Allocator,
    sorted_pixels: std.ArrayListUnmanaged(f32) = .{},

    pub fn init(a: Allocator) Denoiser {
        return .{
            .a = a,
        };
    }

    pub fn deinit(self: *Denoiser) void {
        self.sorted_pixels.deinit(self.a);
    }

    pub fn apply(self: *Denoiser, image: Image) !void {
        self.sorted_pixels.items.len = 0;
        try self.sorted_pixels.appendSlice(self.a, image.data());
        std.sort.sort(f32, self.sorted_pixels.items, {}, comptime std.sort.asc(f32));

        const median = if (self.sorted_pixels.items.len % 2 == 0) blk: {
            const a = self.sorted_pixels.items[self.sorted_pixels.items.len / 2];
            const b = self.sorted_pixels.items[self.sorted_pixels.items.len / 2 + 1];
            break :blk (a + b) / 2;
        } else self.sorted_pixels.items[self.sorted_pixels.items.len / 2];

        for (image.data()) |*channel| {
            channel.* = channel.* - median;
        }
    }
};

pub fn reduceInstrumentNoise(image: Image, maybe_dark: ?Image, maybe_bias: ?Image) void {
    // TODO: Read from fits or pass as arguments
    const t_light = 5.0;
    const t_dark = 2.0;

    for (image.data()) |*channel, i| {
        var val = channel.*;
        if (maybe_dark) |dark| {
            val -= dark.data()[i] * t_light / t_dark;
        }
        if (maybe_bias) |bias| {
            val -= bias.data()[i];
        }
        channel.* = val;
    }
}
