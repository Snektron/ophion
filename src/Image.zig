//! Straight-forward implementation of a 2-dimensional f64 grayscale image.
const Image = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

width: usize,
height: usize,
pixels: [*]f64,

pub fn alloc(allocator: Allocator, width: usize, height: usize) !Image {
    return Image{
        .width = width,
        .height = height,
        .pixels = try allocator.alloc(f64, width * height),
    };
}

pub fn free(self: *Image, allocator: Allocator) void {
    allocator.free(self.data());
    self.* = undefined;
}

pub fn isInBounds(self: Image, x: usize, y: usize) bool {
    return x < self.width and y < self.height;
}

pub fn index(self: Image, x: usize, y: usize) usize {
    assert(self.isInBounds(x, y));
    return y * self.width + x;
}

pub fn get(self: Image, x: usize, y: usize) f64 {
    return self.pixels[self.index(x, y)];
}

pub fn set(self: Image, x: usize, y: usize, value: f64) void {
    self.pixels[self.index(x, y)] = value;
}

pub fn data(self: Image) []f64 {
    return self.pixels[0..self.width * self.height];
}
