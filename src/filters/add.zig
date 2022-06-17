const std = @import("std");
const assert = std.debug.assert;
const Image = @import("../Image.zig");

pub fn apply(image: Image, value: []const f32) void {
    assert(image.descriptor.components == value.len);
    const pixels = image.data();
    var i: usize = 0;
    while (i < pixels.len) : (i += value.len) {
        for (value) |v, j| {
            pixels[i + j] += v;
        }
    }
}
