const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");
const filters = @import("../filters.zig");

pub fn apply(dst: *Image.Managed, srcs: []const Image, dxs: []const f32, dys: []const f32) !void {
    assert(srcs.len > 0);
    assert(srcs.len == dxs.len);
    assert(srcs.len == dys.len);

    var min_x: f32 = 0;
    var min_y: f32 = 0;
    var max_x: f32 = 0;
    var max_y: f32 = 0;

    for (srcs, 0..) |src, i| {
        const dx = dxs[i];
        const dy = dys[i];
        min_x = @min(min_x, dx);
        min_y = @min(min_y, dy);
        max_x = @max(max_x, dx + @as(f32, @floatFromInt(src.descriptor.width)));
        max_y = @max(max_y, dy + @as(f32, @floatFromInt(src.descriptor.height)));
    }

    const w = @as(usize, @intFromFloat(@ceil(max_x - min_x)));
    const h = @as(usize, @intFromFloat(@ceil(max_y - min_y)));

    try dst.realloc(.{
        .width = w,
        .height = h,
        .components = srcs[0].descriptor.components,
    });

    for (dst.data()) |*channel| channel.* = 0;

    for (srcs, 0..) |src, i| {
        const dx = @as(usize, @intFromFloat(dxs[i] - min_x));
        const dy = @as(usize, @intFromFloat(dys[i] - min_y));

        var y: usize = 0;
        while (y < src.descriptor.height) : (y += 1) {
            var x: usize = 0;
            while (x < src.descriptor.width) : (x += 1) {
                const pixel = src.pixel(x, y);
                // TODO: better sampling.
                const target_pixel = dst.pixel(x + dx, y + dy);
                for (target_pixel, 0..) |*channel, j| {
                    channel.* += pixel[j];
                }
            }
        }
    }

    // filters.normalize.apply(dst.unmanaged());
}
