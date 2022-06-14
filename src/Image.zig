const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Image = @This();

descriptor: Descriptor,
pixels: [*]f32,

pub const Descriptor = struct {
    pub const empty = Descriptor{
        .width = 0,
        .height = 0,
        .components = 0,
    };

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

    pub fn flatPixelIndex(self: Descriptor, offset: usize) usize {
        assert(offset < self.pixels());
        return offset * self.components;
    }
};

pub const Managed = struct {
    descriptor: Descriptor,
    pixels: [*]f32,
    allocator: Allocator,

    pub fn init(a: Allocator, descriptor: Descriptor) !Managed {
        const image = try Image.init(a, descriptor);
        return image.managed(a);
    }

    pub fn deinit(self: Managed) void {
        self.unmanaged().deinit(self.allocator);
    }

    pub fn pixel(self: Managed, x: usize, y: usize) []f32 {
        return self.unmanaged().pixel(x, y);
    }

    pub fn flatPixel(self: Managed, offset: usize) []f32 {
        return self.unmanaged().flatPixel(offset);
    }

    pub fn data(self: Managed) []f32 {
        return self.unmanaged().data();
    }

    pub fn unmanaged(self: Managed) Image {
        return .{
            .descriptor = self.descriptor,
            .pixels = self.pixels,
        };
    }

    pub fn realloc(self: *Managed, descriptor: Descriptor) !void {
        const is_shrinking = descriptor.size() <= self.descriptor.size();
        const new_pixels = self.allocator.realloc(self.data(), descriptor.size()) catch {
            // Just keep the memory if shrinking fails...
            if (!is_shrinking) {
                return error.OutOfMemory;
            }
            return;
        };
        self.descriptor = descriptor;
        self.pixels = new_pixels.ptr;
    }
};

pub fn init(a: Allocator, descriptor: Descriptor) !Image {
    const pixels = try a.alloc(f32, descriptor.size());
    return Image{
        .descriptor = descriptor,
        .pixels = pixels.ptr,
    };
}

pub fn deinit(self: Image, a: Allocator) void {
    a.free(self.data());
}

pub fn pixel(self: Image, x: usize, y: usize) []f32 {
    const base = self.descriptor.pixelIndex(x, y);
    return self.data()[base..][0..self.descriptor.components];
}

pub fn flatPixel(self: Image, offset: usize) []f32 {
    const base = self.descriptor.flatPixelIndex(offset);
    return self.data()[base..][0..self.descriptor.components];
}

pub fn data(self: Image) []f32 {
    return self.pixels[0 .. self.descriptor.size()];
}

pub fn managed(self: Image, a: Allocator) Managed {
    return .{
        .descriptor = self.descriptor,
        .pixels = self.pixels,
        .allocator = a,
    };
}
