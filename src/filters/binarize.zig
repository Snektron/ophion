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

    const result_data = dst.data();
    for (src.data()) |channel, i| {
        if (channel > opts.min_stddev * stddev + mean) {
            result_data[i] = 1;
        } else {
            result_data[i] = 0;
        }
    }
}
