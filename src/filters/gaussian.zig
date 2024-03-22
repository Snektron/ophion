const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");
const filters = @import("../filters.zig");

pub const Kernel = struct {
    pub const stddev_to_radius_factor = 4;

    coefficients: []f32,

    pub fn initAlloc(a: Allocator, stddev: f32) !Kernel {
        const num_coeffs = radiusForStddev(stddev) + 1; // add one for the center
        const coefficients = try a.alloc(f32, num_coeffs);
        errdefer a.free(coefficients);
        computeCoefficients(coefficients);
        return Kernel{
            .coefficients = coefficients,
        };
    }

    pub fn init(comptime stddev: f32) Kernel {
        const coefficients = comptime blk: {
            const num_coeffs = radiusForStddev(stddev) + 1;
            var coefficients: [num_coeffs]f32 = undefined;
            computeCoefficients(&coefficients, stddev);
            break :blk &coefficients;
        };
        return Kernel{
            .coefficients = coefficients,
        };
    }

    fn computeCoefficients(coefficients: []f32, stddev: f32) void {
        const variance = stddev * stddev;
        for (coefficients, 0..) |*coeff, i| {
            const x = @as(f32, @floatFromInt(i));
            coeff.* = @exp(-x * x / (2 * variance));
        }

        // Instead of computing a coefficient, compute the total and scale by that.
        // This way, the filter is energy conserving even if it only approximates the blur
        // by a certain number of values.

        // We only compute one side of coefficients, since they are mirrored.
        // For that case, the center needs to be counted once, but all the others need
        // are included twice in the result.
        var total = coefficients[0];
        for (coefficients[1..]) |coeff| {
            total += coeff * 2;
        }

        for (coefficients) |*coeff| {
            coeff.* /= total;
        }
    }

    pub fn deinit(self: Kernel, a: Allocator) void {
        a.free(self.coefficients);
    }

    pub fn radiusForStddev(stddev: f32) usize {
        return @as(usize, @intFromFloat(@ceil(stddev * stddev_to_radius_factor)));
    }

    pub fn horizontalRadius(self: Kernel) usize {
        return self.coefficients.len - 1;
    }

    pub fn verticalRadius(self: Kernel) usize {
        return self.coefficients.len - 1;
    }

    pub fn getHorizontal(self: Kernel, x: isize) f32 {
        return self.coefficients[@abs(x)];
    }

    pub fn getVertical(self: Kernel, y: isize) f32 {
        return self.getHorizontal(y);
    }
};

pub fn apply(dst: *Image.Managed, tmp: *Image.Managed, src: Image, kernel: Kernel) !void {
    try filters.convolve_separable.apply(dst, tmp, src, kernel);
}
