const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");
const alignment = @import("../alignment.zig");
const CoarseStarList = alignment.coarse.CoarseStarList;

const radius = 16;

pub const FineStar = struct {
    x: f32,
    y: f32,
    stddev: f32,
};

pub const FineStarList = std.MultiArrayList(FineStar);

pub fn extract(a: Allocator, fine: *FineStarList, image: Image, coarse: CoarseStarList) !void {
    const xs = coarse.items(.x);
    const ys = coarse.items(.y);

    var i: usize = 0;
    while (i < coarse.len) : (i += 1) {
        const star = extractStar(image, xs[i], ys[i]) orelse continue;
        try fine.append(a, star);
    }
}

fn extractStar(
    image: Image,
    coarse_x: f32,
    coarse_y: f32,
) ?FineStar {
    const x = @floatToInt(usize, coarse_x);
    const y = @floatToInt(usize, coarse_y);
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
                total_x += @intToFloat(f32, ix) * pixel;
                total_y += @intToFloat(f32, iy) * pixel;
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
                const dx = (@intToFloat(f32, ix) - cx) * pixel;
                const dy = (@intToFloat(f32, iy) - cy) * pixel;
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
