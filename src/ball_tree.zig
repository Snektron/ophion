const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub fn BallTree(comptime dims: usize) type {
    return struct {
        const Self = @This();

        pub const dimensions = dims;
        pub const Point = [dimensions]f32;

        /// Strong alias because we need to process it to get the actual indices.
        pub const NodePointer = struct {
            value: u32,
        };

        pub const NodeIndex = union(enum) {
            inner: u32,
            leaf: u32,
        };

        pub const Ball = struct {
            center: Point,
            radius: f32,
        };

        pub const Node = struct {
            center: u32, // Always a leaf index
            radius: f32,
            inner: u32,
            outer: u32,
        };

        nodes: []Node,
        leaves: []Point,

        pub fn construct(a: Allocator, points: []Point) !Self {
            var nodes = std.ArrayList(Node).init(a);
            errdefer nodes.deinit();
        }

        fn boundingBall(points: []const Point) !Ball {}

        fn constructTree(
            nodes: *std.ArrayList(Node),
            all_points: []Point,
            points_off: usize,
            points_len: usize,
        ) !NodePointer {
            assert(points_len > 0);
            assert(points_off < all_points.len);

            if (points_len == 1) {
                return NodePointer{
                    .value = points_off,
                };
            }
        }

        fn index(self: Self, ptr: NodePointer) NodeIndex {
            assert(ptr.value < self.nodes.len + self.leaves.len);
            return if (ptr.value < self.leaves.len)
                .{ .leaf = ptr.value }
            else
                .{ .inner = ptr.value - self.leaves.len };
        }
    };
}
