const std = @import("std");
// const Image = @import("../Image.zig");

// pub const Options = struct {
//     /// The radius of each sample. The actual number of sampled pixels is
//     /// `(radius * 2 + 1) ^ 2`
//     radius: usize = 1,
//     min_stddev: f32 = 2,
// };

// fn stddev(image: Image, cx: isize, cy: isize, radius: isize) f32 {
//     const pix = image.get(@intCast(usize, cx), @intCast(usize, cy));

//     const mean = blk: {
//         var total: f32 = 0;
//         var n: usize = 0;

//         var y: isize = -radius;
//         while (y <= radius) : (y += 1) {
//             var x: isize = -radius;
//             while (x <= radius) : (x += 1) {
//                 const sx = cx - x;
//                 const sy = cy - y;
//                 if (sx >= 0 and sy >= 0 and sx < image.width and sy < image.height) {
//                     n += 1;
//                     total += image.get(@intCast(usize, sx), @intCast(usize, sy));
//                 }
//             }
//         }

//         break :blk total / @intToFloat(f32, n);
//     };

//     var variance: f32 = 0;
//     var n: usize = 0;
//     var y: isize = -radius;
//     while (y <= radius) : (y += 1) {
//         var x: isize = -radius;
//         while (x <= radius) : (x += 1) {
//             const sx = cx - x;
//             const sy = cy - y;
//             if (sx >= 0 and sy >= 0 and sx < image.width and sy < image.height) {
//                 n += 1;
//                 const diff = image.get(@intCast(usize, sx), @intCast(usize, sy)) - mean;
//                 variance += diff * diff;
//             }
//         }
//     }

//     variance /= @intToFloat(f32, n - 1);
//     return (pix - mean) / @sqrt(variance);
// }

// pub fn apply(result: Image, image: Image, opts: Options) void {
//     std.debug.assert(result.width == image.width);
//     std.debug.assert(result.height == image.height);

//     const radius = @intCast(isize, opts.radius);

//     var maxvar: f32 = std.math.f32_min;
//     var n: usize = 0;
//     var y: usize = 0;
//     while (y < image.height) : (y += 1) {
//         var x: usize = 0;
//         while (x < image.width) : (x += 1) {
//             const sample_stddev = stddev(image, @intCast(isize, x), @intCast(isize, y), radius);
//             if (sample_stddev > maxvar) {
//                 maxvar = sample_stddev;
//             }
//             if (sample_stddev > opts.min_stddev) {
//                 result.set(x, y, 1);
//                 n += 1;
//             } else {
//                 result.set(x, y, 0);
//             }
//         }
//     }
//     std.log.info("aaaa {d} {}", .{maxvar, n});
// }
