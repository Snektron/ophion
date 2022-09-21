//! This filter normalizes the value in the image to a scale from 0-1.
//! Filter operates in place.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");
const filters = @import("../filters.zig");

pub const Denoiser = struct {
    tmp: Image.Managed,

    pub fn init(a: Allocator) Denoiser {
        return .{
            .tmp = Image.Managed.empty(a),
        };
    }

    pub fn deinit(self: *Denoiser) void {
        self.tmp.deinit();
    }

    pub fn apply(self: *Denoiser, image: Image) !void {
        try filters.grayscale.apply(&self.tmp, image);
        const sorted = self.tmp.data();
        std.sort.sort(f32, sorted, {}, comptime std.sort.asc(f32));

        const median = if (sorted.len % 2 == 0) blk: {
            const a = sorted[sorted.len / 2];
            const b = sorted[sorted.len / 2 + 1];
            break :blk (a + b) / 2;
        } else sorted[sorted.len / 2];

        for (image.data()) |*channel| {
            channel.* = std.math.clamp(channel.* - median, 0, 1);
        }
    }
};
