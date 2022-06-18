const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");
const BoundedMinSet = @import("../util/min_set.zig").BoundedMinSet;

/// A "constellation" is in this case simply a triplet of stars.
/// Instead of simply computing points though, we store for each constellation
/// the angles between its stars. These values do not change under scaling, rotation and translation
/// and so gives us constant values to compare even if frames differ under these transformations.
/// Stars in a constellation are always counter-clockwise with respect to the order in the image.
pub const Constellation = struct {
    star_indices: struct {
        a: u32,
        b: u32,
        c: u32,
    },

    /// Angle between stars a and b
    cab: f32,
    /// Angle between stars b and c
    abc: f32,

    /// Return the angle between stars a and b on star c
    pub fn bca(self: Constellation) f32 {
        return std.math.pi - self.cab - self.abc;
    }
};

pub const ConstellationList = std.MultiArrayList(Constellation);

pub const Options = struct {
    /// The number of closest stars to consider when forming constellations.
    form_constellations_with: u32 = 5,
};

const Context = struct {
    xs: []f32,
    ys: []f32,
    target: u32,

    fn distsq(self: Context, ai: u32, bi: u32) f32 {
        const dx = self.xs[ai] - self.xs[bi];
        const dy = self.ys[ai] - self.ys[bi];
        return dx * dx + dy * dy;
    }

    fn cmp(self: Context, a: u32, b: u32) std.math.Order {
        const da = self.distsq(self.target, a);
        const db = self.distsq(self.target, b);
        return std.math.order(da, db);
    }
};

pub const ConstellationExtractor = struct {
    closest_stars: []u32,

    pub fn init(a: Allocator, opts: Options) !ConstellationExtractor {
        assert(opts.form_constellations_with >= 2);
        return ConstellationExtractor{
            .closest_stars = try a.alloc(u32, opts.form_constellations_with),
        };
    }

    pub fn deinit(self: ConstellationExtractor, a: Allocator) void {
        a.free(self.closest_stars);
    }

    pub fn extract(
        self: *ConstellationExtractor,
        a: Allocator,
        constellations: *ConstellationList,
        xs: []f32,
        ys: []f32,
    ) !void {
        assert(xs.len == ys.len);
        // We don't expect an extreme number of stars per image, maybe like 100 at most. Therefore we can
        // affort to implement this algorithm in a brute-force manner.
        // TODO: This extraction process could probably produce some better results by using a different method.

        var i: u32 = 0;
        while (i < xs.len) : (i += 1) {
            var context = Context{
                .xs = xs,
                .ys = ys,
                .target = i,
            };
            var closest_stars = BoundedMinSet(u32, Context, Context.cmp).init(context, self.closest_stars);

            var j: u32 = i + 1;
            while (j < xs.len) : (j += 1) {
                closest_stars.insert(j);
            }

            if (closest_stars.items.len >= 2) {
                try addConstellations(a, constellations, xs, ys, i, closest_stars.items);
            }
        }
    }

    fn addConstellations(
        a: Allocator,
        constellations: *ConstellationList,
        xs: []f32,
        ys: []f32,
        i: u32,
        closest_stars: []const u32,
    ) !void {
        for (closest_stars[0..closest_stars.len - 1]) |j, offset| {
            for (closest_stars[offset + 1..]) |k| {
                try addConstellation(a, constellations, xs, ys, i, j, k);
            }
        }
    }

    const Point = struct {
        x: f32,
        y: f32,

        fn load(xs: []f32, ys: []f32, i: u32) Point {
            return .{
                .x = xs[i],
                .y = ys[i],
            };
        }
    };

    fn halfSpaceTest(a: Point, b: Point, c: Point) bool {
        return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 0;
    }

    fn dist(a: Point, b: Point) f32 {
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        return @sqrt(dx * dx + dy * dy);
    }

    fn angle(a: f32, b: f32, c: f32) f32 {
        return std.math.acos((a * a + b * b - c * c) / (2 * a * b));
    }

    fn addConstellation(
        a: Allocator,
        constellations: *ConstellationList,
        xs: []f32,
        ys: []f32,
        i: u32,
        j: u32,
        k: u32,
    ) !void {
        // Make sure that the constellation has the correct winding order
        const p_i = Point.load(xs, ys, i);
        var p_j = Point.load(xs, ys, j);
        var p_k = Point.load(xs, ys, k);

        // Compute angles kij and ijk, jki follows from that
        // and we dont need to use trig for that.
        const ij = dist(p_i, p_j);
        const jk = dist(p_j, p_k);
        const ki = dist(p_k, p_i);

        const kij = angle(jk, ki, ij);
        const ijk = angle(ki, jk, ij);
        const jki = std.math.pi - kij - ijk;

        // If k is left of i->j, we need to flip the triangle to make it have the right winding order.
        const k_left_of_ij = halfSpaceTest(p_i, p_j, p_k);
        if (k_left_of_ij) {
            try constellations.append(a, .{
                .star_indices = .{
                    .a = i,
                    .b = j,
                    .c = k,
                },
                .cab = kij,
                .abc = ijk,
            });
        } else {
            try constellations.append(a, .{
                .star_indices = .{
                    .a = i,
                    .b = k,
                    .c = j,
                },
                .cab = kij,
                .abc = jki,
            });
        }
    }
};
