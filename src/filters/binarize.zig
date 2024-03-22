const std = @import("std");
const assert = std.debug.assert;
const Image = @import("../Image.zig");
const filters = @import("../filters.zig");

pub const Options = struct {
    min_stddev: f32 = 2,
};

pub fn apply(dst: *Image.Managed, src: Image, opts: Options) !void {
    assert(src.descriptor.components == 1);
    try dst.realloc(src.descriptor);

    const mean = filters.statistics.mean(src);
    const stddev = filters.statistics.stddev(src, mean);

    _ = opts;
    _ = stddev;

    const result_data = dst.data();
    for (src.data(), 0..) |channel, i| {
        if (channel > 0.2) {
            result_data[i] = 1;
        } else {
            result_data[i] = 0;
        }
    }
}
