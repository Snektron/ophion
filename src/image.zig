//! This file models a generic 2D Image type, which can have different pixel types.
//! In effect, these images are just 2D data containers, with no options for stride
//! and such.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const ColorImage = Image(3);
pub const GrayscaleImage = Image(1);

fn Image(comptime components: usize) type {
    return struct {
        const Self = @This();

        pub const Pixel = [components]f32;

        width: usize,
        height: usize,
        data: [*]Pixel,

        pub fn alloc(a: Allocator, width: usize, height: usize) !Self {
            return Self{
                .width = width,
                .height = height,
                .data = (try a.alloc(Pixel, width * height)).ptr,
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

        pub fn get(self: Self, x: usize, y: usize) Pixel {
            return self.data[self.index(x, y)];
        }

        pub fn set(self: Self, x: usize, y: usize, value: Pixel) void {
            self.data[self.index(x, y)] = value;
        }

        pub fn pixels(self: Self) []Pixel {
            return self.data[0..self.width * self.height];
        }
    };
}
