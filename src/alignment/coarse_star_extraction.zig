const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Image = @import("../Image.zig");

pub const CoarseStar = struct {
    x: f32,
    y: f32,
    size: u32,
};

pub const CoarseStarList = std.MultiArrayList(CoarseStar);

pub const CoarseStarExtractor = struct {
    const PixelPos = struct {
        x: u16,
        y: u16,
    };

    const cutoff = 0.5;
    const Queue = std.fifo.LinearFifo(PixelPos, .Dynamic);

    /// Also holds the allocator for this struct.
    queue: Queue,
    seen: std.DynamicBitSetUnmanaged = .{},

    pub fn init(a: Allocator) CoarseStarExtractor {
        return .{
            .queue = Queue.init(a),
        };
    }

    pub fn deinit(self: *CoarseStarExtractor) void {
        self.seen.deinit(self.allocator());
        self.queue.deinit();
    }

    pub fn extract(self: *CoarseStarExtractor, a: Allocator, stars: *CoarseStarList, image: Image) !void {
        assert(image.descriptor.components == 1);
        try self.seen.resize(self.allocator(), image.descriptor.pixels(), false);
        self.seen.setRangeValue(.{.start = 0, .end = image.descriptor.pixels()}, false);

        var y: usize = 0;
        while (y < image.descriptor.height) : (y += 1) {
            var x: usize = 0;
            while (x < image.descriptor.width) : (x += 1) {
                const coarse = (try self.extractStar(image, @intCast(u16, x), @intCast(u16, y))) orelse continue;
                try stars.append(a, coarse);
            }
        }
    }

    fn extractStar(
        self: *CoarseStarExtractor,
        image: Image,
        sx: u16,
        sy: u16,
    ) !?CoarseStar {
        if (!try self.enqueue(image, sx, sy))
            return null;

        var i: usize = 0;
        var x_avg: usize = 0;
        var y_avg: usize = 0;
        while (self.queue.readItem()) |pos| {
            i += 1;
            x_avg += pos.x;
            y_avg += pos.y;

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
        return CoarseStar{
            .x = @intToFloat(f32, x_avg) / @intToFloat(f32, i),
            .y = @intToFloat(f32, y_avg) / @intToFloat(f32, i),
            .size = @intCast(u32, i),
        };
    }

    fn enqueue(self: *CoarseStarExtractor, image: Image, x: u16, y: u16) !bool {
        const pixel = image.pixel(x, y)[0];
        if (pixel >= cutoff and self.markSeen(image, x, y)) {
            try self.queue.writeItem(.{.x = x, .y = y});
            return true;
        }
        return false;
    }

    /// Returns true if the pixel has been marked for the first time.
    fn markSeen(self: *CoarseStarExtractor, image: Image, x: usize, y: usize) bool {
        const index = y * image.descriptor.width + x;
        const already_seen = self.seen.isSet(index);
        self.seen.set(index);
        return !already_seen;
    }

    fn allocator(self: CoarseStarExtractor) Allocator {
        return self.queue.allocator;
    }
};
