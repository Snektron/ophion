const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");
const alignment = @import("../alignment.zig");
const StarList = alignment.StarList;

const BBox = struct {
    xmin: u16,
    ymin: u16,
    xmax: u16,
    ymax: u16,
};

pub const StarExtractor = struct {
    const PixelPos = struct {
        x: u16,
        y: u16,
    };

    const cutoff = 0.5;
    const Queue = std.fifo.LinearFifo(PixelPos, .Dynamic);

    /// Also holds the allocator for this struct.
    queue: Queue,
    seen: std.DynamicBitSetUnmanaged = .{},

    pub fn init(a: Allocator) StarExtractor {
        return .{
            .queue = Queue.init(a),
        };
    }

    pub fn deinit(self: *StarExtractor) void {
        self.seen.deinit(self.allocator());
        self.queue.deinit();
    }

    pub fn extract(self: *StarExtractor, a: Allocator, stars: *StarList, image: Image) !void {
        assert(image.descriptor.components == 1);
        _ = stars;
        _ = a;
        try self.seen.resize(self.allocator(), image.descriptor.pixels(), false);
        self.seen.setRangeValue(.{.start = 0, .end = image.descriptor.pixels()}, false);

        var y: usize = 0;
        while (y < image.descriptor.height) : (y += 1) {
            var x: usize = 0;
            while (x < image.descriptor.width) : (x += 1) {
                try self.extractBlob(a, stars, image, @intCast(u16, x), @intCast(u16, y));
            }
        }
    }

    fn extractBlob(
        self: *StarExtractor,
        a: Allocator,
        stars: *StarList,
        image: Image,
        sx: u16,
        sy: u16,
    ) !void {
        if (!try self.enqueue(image, sx, sy))
            return;

        var bb = BBox{
            .xmin = sx,
            .ymin = sy,
            .xmax = sx,
            .ymax = sy,
        };

        var i: usize = 0;
        while (self.queue.readItem()) |pos| {
            i += 1;
            bb.xmin = @minimum(bb.xmin, pos.x);
            bb.ymin = @minimum(bb.ymin, pos.y);
            bb.xmax = @maximum(bb.xmax, pos.x);
            bb.ymax = @maximum(bb.ymax, pos.y);

            if (pos.x > 0) {
                _ = try self.enqueue(image, pos.x - 1, pos.y);
            }
            if (pos.x < image.descriptor.width - 1) {
                _ = try self.enqueue(image, pos.x + 1, pos.y);
            }
            if (pos.y > 0) {
                _ = try self.enqueue(image, pos.x, pos.y - 1);
            }
            if (pos.y < image.descriptor.height - 1) {
                _ = try self.enqueue(image, pos.x, pos.y + 1);
            }
        }

        // Relative magnitude is computed from the size. By assuming that a star is roughly round,
        // we can assume that i is the area. Divide by pi for fancyness, but the value is still pretty arbitrary.
        try stars.append(a, .{
            .x = (@intToFloat(f32, bb.xmin) + @intToFloat(f32, bb.xmax)) / 2,
            .y = (@intToFloat(f32, bb.ymin) + @intToFloat(f32, bb.ymax)) / 2,
            .relative_magnitude = @sqrt(@intToFloat(f32, i)) / std.math.pi,
        });
    }

    fn enqueue(self: *StarExtractor, image: Image, x: u16, y: u16) !bool {
        const pixel = image.pixel(x, y)[0];
        if (pixel >= cutoff and self.markSeen(image, x, y)) {
            try self.queue.writeItem(.{.x = x, .y = y});
            return true;
        }
        return false;
    }

    /// Returns true if the pixel has been marked for the first time.
    fn markSeen(self: *StarExtractor, image: Image, x: usize, y: usize) bool {
        const index = y * image.descriptor.width + x;
        const already_seen = self.seen.isSet(index);
        self.seen.set(index);
        return !already_seen;
    }

    fn allocator(self: StarExtractor) Allocator {
        return self.queue.allocator;
    }
};

