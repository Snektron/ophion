const std = @import("std");
const Order = std.math.Order;
const testing = std.testing;

pub fn BoundedMinSet(
    comptime T: type,
    comptime Context: type,
    comptime cmp: fn (Context, T, T) Order,
) type {
    return struct {
        const Self = @This();

        context: Context,
        items: []T,
        capacity: usize = 0,

        pub fn init(context: Context, store: []T) Self {
            var self = Self{
                .context = context,
                .items = undefined,
                .capacity = store.len,
            };
            // .items = store[0..0] causes the pointer to be 0xAA.. in debug mode.
            self.items.ptr = store.ptr;
            self.items.len = 0;
            return self;
        }

        pub fn insert(self: *Self, new: T) void {
            const index = for (self.items) |item, i| {
                if (cmp(self.context, new, item).compare(.lt)) {
                    break i;
                }
            } else if (self.items.len == self.capacity) {
                return;
            } else self.items.len;

            if (self.items.len < self.capacity) {
                self.items.len += 1;
            }

            var i: usize = self.items.len;
            while (i > index + 1) {
                i -= 1;
                self.items[i] = self.items[i - 1];
            }
            self.items[index] = new;
        }
    };
}

fn compareUsize(_: void, a: usize, b: usize) Order {
    return std.math.order(a, b);
}

test "BoundedMinSet" {
    var a: [5]usize = undefined;
    var minset = BoundedMinSet(usize, void, compareUsize).init({}, &a);
    try testing.expectEqualSlices(usize, &.{}, minset.items);

    minset.insert(5);
    try testing.expectEqualSlices(usize, &.{5}, minset.items);

    minset.insert(7);
    try testing.expectEqualSlices(usize, &.{5, 7}, minset.items);
    std.debug.print("----\n", .{});
    minset.insert(3);
    try testing.expectEqualSlices(usize, &.{3, 5, 7}, minset.items);

    minset.insert(4);
    try testing.expectEqualSlices(usize, &.{3, 4, 5, 7}, minset.items);

    minset.insert(6);
    try testing.expectEqualSlices(usize, &.{3, 4, 5, 6, 7}, minset.items);

    minset.insert(1);
    try testing.expectEqualSlices(usize, &.{1, 3, 4, 5, 6}, minset.items);

    minset.insert(2);
    try testing.expectEqualSlices(usize, &.{1, 2, 3, 4, 5}, minset.items);

    minset.insert(8);
    try testing.expectEqualSlices(usize, &.{1, 2, 3, 4, 5}, minset.items);
}
