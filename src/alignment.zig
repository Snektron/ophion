const std = @import("std");
pub const star_extraction = @import("alignment/star_extraction.zig");

pub const Star = struct {
    x: f32,
    y: f32,
    relative_magnitude: f32
};

pub const StarList = std.MultiArrayList(Star);
