//! This file models a generic 2D Image type, which can have different pixel types.
//! In effect, these images are just 2D data containers, with no options for stride
//! and such.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const ColorChannel = f32;

// We only care about images with floats for now.
pub const ColorImage = Image(Rgb);
pub const GrayscaleImage = Image(ColorChannel);

const Rgb = struct {
    r: ColorChannel,
    g: ColorChannel,
    b: ColorChannel,
};

fn Image(comptime T: type) type {
    return struct {
        const Self = @This();

        width: usize,
        height: usize,
        data: [*]T,

        pub fn alloc(a: Allocator, width: usize, height: usize) !Self {
            return Self{
                .width = width,
                .height = height,
                .data = (try a.alloc(T, width * height)).ptr,
            };
        }

        pub fn free(self: Self, a: Allocator) void {
            a.free(self.pixels());
        }

        pub fn isInBounds(self: Self, x: usize, y: usize) bool {
            return x < self.width and y < self.height;
        }

        pub fn index(self: Self, x: usize, y: usize) usize {
            assert(self.isInBounds(x, y));
            return y * self.width + x;
        }

        pub fn get(self: Self, x: usize, y: usize) f32 {
            return self.data[self.index(x, y)];
        }

        pub fn set(self: Self, x: usize, y: usize, value: T) void {
            self.data[self.index(x, y)] = value;
        }

        pub fn pixels(self: Self) []T {
            return self.data[0..self.width * self.height];
        }
    };
}
