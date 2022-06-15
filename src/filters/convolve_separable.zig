const std = @import("std");
const assert = std.debug.assert;
const Image = @import("../Image.zig");

fn pixelOr(image: Image, x: isize, y: isize, out_of_bounds: f32) f32 {
    return if (x < 0 or y < 0 or x >= image.descriptor.width or y >= image.descriptor.height)
        out_of_bounds
    else
        image.pixel(@intCast(usize, x), @intCast(usize, y))[0];
}

fn convolveVertical(
    result: []f32,
    image: Image,
    cx: usize,
    cy: usize,
    kernel: anytype,
) void {
    const radius = @intCast(isize, kernel.verticalRadius());
    const icx = @intCast(isize, cx);
    const icy = @intCast(isize, cy);
    var y: isize = -radius;
    var pixel: f32 = 0;
    while (y <= radius) : (y += 1) {
        pixel += pixelOr(image, icx, icy + y, 0) * kernel.getVertical(y);
    }
    result[0] = pixel;
}

fn convolveHorizontal(
    result: []f32,
    image: Image,
    cx: usize,
    cy: usize,
    kernel: anytype,
) void {
    const radius = @intCast(isize, kernel.horizontalRadius());
    const icx = @intCast(isize, cx);
    const icy = @intCast(isize, cy);
    var x: isize = -radius;
    var pixel: f32 = 0;
    while (x <= radius) : (x += 1) {
        pixel += pixelOr(image, icx + x, icy, 0) * kernel.getHorizontal(x);
    }
    result[0] = pixel;
}

pub fn apply(dst: *Image.Managed, tmp: *Image.Managed, src: Image, kernel: anytype) !void {
    assert(src.descriptor.components == 1);
    try tmp.realloc(src.descriptor);

    {
        var y: usize = 0;
        while (y < src.descriptor.height) : (y += 1) {
            var x: usize = 0;
            while (x < src.descriptor.width) : (x += 1) {
                convolveVertical(tmp.pixel(x, y), src, x, y, kernel);
            }
        }
    }

    try dst.realloc(src.descriptor);
    const tmp_view = tmp.unmanaged();

    {
        var y: usize = 0;
        while (y < src.descriptor.height) : (y += 1) {
            var x: usize = 0;
            while (x < src.descriptor.width) : (x += 1) {
                convolveHorizontal(dst.pixel(x, y), tmp_view, x, y, kernel);
            }
        }
    }
}

pub const Box = struct {
    radius: usize,
    inv_diam: f32,

    pub fn init(radius: usize) Box {
        return .{
            .radius = radius,
            .inv_diam = 1 / @intToFloat(f32, radius * 2 + 1),
        };
    }

    pub fn horizontalRadius(self: Box) usize {
        return self.radius;
    }

    pub fn verticalRadius(self: Box) usize {
        return self.radius;
    }

    pub fn getHorizontal(self: Box, x: isize) f32 {
        _ = x;
        return self.inv_diam;
    }

    pub fn getVertical(self: Box, y: isize) f32 {
        _ = y;
        return self.inv_diam;
    }
};
