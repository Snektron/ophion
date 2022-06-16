const std = @import("std");
pub const coarse = @import("alignment/coarse_star_extraction.zig");
pub const fine = @import("alignment/fine_star_extraction.zig");

pub const Star = struct {
    x: f32,
    y: f32,
};

pub const StarList = std.MultiArrayList(Star);
