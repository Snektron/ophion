const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");

const radius = 16;

pub const FineStar = struct {
    x: f32,
    y: f32,
    stddev: f32,
};

pub const FineStarList = std.MultiArrayList(FineStar);

pub fn extract(a: Allocator, fine: *FineStarList, image: Image, xs: []f32, ys: []f32) !void {
    assert(xs.len == ys.len);

    var i: usize = 0;
    while (i < xs.len) : (i += 1) {
        const star = extractStar(image, xs[i], ys[i]) orelse continue;
        try fine.append(a, star);
    }
}

fn extractStar(
    image: Image,
    coarse_x: f32,
    coarse_y: f32,
) ?FineStar {
    const x = @as(usize, @intFromFloat(coarse_x));
    const y = @as(usize, @intFromFloat(coarse_y));
    // If too close to the edge, we won't get a good extraction.
    if (x < radius or y < radius or x + radius >= image.descriptor.width or y + radius >= image.descriptor.height)
        return null;

    var total_x: f32 = 0;
    var total_y: f32 = 0;
    var total: f32 = 0;

    {
        var ix = x - radius;
        while (ix < x + radius) : (ix += 1) {
            var iy = y - radius;
            while (iy < y + radius) : (iy += 1) {
                const pixel = image.pixel(ix, iy)[0];
                total_x += @as(f32, @floatFromInt(ix)) * pixel;
                total_y += @as(f32, @floatFromInt(iy)) * pixel;
                total += pixel;
            }
        }
    }

    const cx = total_x / total;
    const cy = total_y / total;

    var variance: f32 = 0;

    {
        var ix = x - radius;
        while (ix < x + radius) : (ix += 1) {
            var iy = y - radius;
            while (iy < y + radius) : (iy += 1) {
                const pixel = image.pixel(x, iy)[0];
                const dx = (@as(f32, @floatFromInt(ix)) - cx) * pixel;
                const dy = (@as(f32, @floatFromInt(iy)) - cy) * pixel;
                variance += dx * dx + dy * dy;
            }
        }
    }

    const stddev = @sqrt(variance / (radius * radius));

    return FineStar{
        .x = cx,
        .y = cy,
        .stddev = stddev,
    };
}
