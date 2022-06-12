const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Image = @This();

pub const Descriptor = struct {
    width: usize,
    height: usize,
    components: usize,

    pub fn pixels(self: Descriptor) usize {
        return self.width * self.height;
    }

    pub fn size(self: Descriptor) usize {
        return self.width * self.height * self.components;
    }

    pub fn isInBounds(self: Descriptor, x: usize, y: usize) bool {
        return x < self.width and y < self.height;
    }

    pub fn pixelIndex(self: Descriptor, x: usize, y: usize) usize {
        assert(self.isInBounds(x, y));
        return (y * self.width + x) * self.components;
    }
};

descriptor: Descriptor,
pixels: [*]f32,

pub fn alloc(a: Allocator, descriptor: Descriptor) !Image {
    const pixels = try a.alloc(f32, descriptor.size());
    return Image{
        .descriptor = descriptor,
        .pixels = pixels.ptr,
    };
}

pub fn free(self: Image, a: Allocator) void {
    a.free(self.data());
}

pub fn pixel(self: Image, x: usize, y: usize) []f32 {
    const base = self.descriptor.pixelIndex(x, y);
    return self.data()[base..][0..self.descriptor.components];
}

pub fn data(self: Image) []f32 {
    return self.pixels[0 .. self.descriptor.size()];
}
