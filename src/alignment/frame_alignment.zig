const std = @import("std");
const assert = std.debug.assert;
const Progress = std.Progress;
const Allocator = std.mem.Allocator;

const alignment = @import("../alignment.zig");
const Constellation = alignment.constellation.Constellation;
const ConstellationList = alignment.constellation.ConstellationList;
const FrameStack = alignment.frame.FrameStack;

const Star = struct {
    x: f32,
    y: f32,
};

const StarList = std.MultiArrayList(Star);

pub const FrameOffset = struct {
    dx: f32,
    dy: f32,
};

pub const FrameOffsetList = std.MultiArrayList(FrameOffset);

pub const FrameAligner = struct {

    a: Allocator,
    /// All currently known stars, relative to the reference frame.
    all_stars: StarList = .{},
    all_constellations: ConstellationList = .{},
    unprocessed_frames: std.ArrayListUnmanaged(u32) = .{},
    reference_frame: u32,

    pub fn init(a: Allocator) FrameAligner {
        return .{
            .a = a,
            .reference_frame = undefined,
        };
    }

    pub fn deinit(self: *FrameAligner) void {
        self.all_stars.deinit(self.a);
        self.all_constellations.deinit(self.a);
        self.unprocessed_frames.deinit(self.a);
    }

    fn hasStar(self: FrameAligner, x: f32, y: f32, err: f32) bool {
        var i: usize = 0;
        const xs = self.all_stars.items(.x);
        const ys = self.all_stars.items(.y);
        const errsq = err * err;
        while (i < self.all_stars.len) : (i += 1) {
            const dx = xs[i] - x;
            const dy = ys[i] - y;
            if (dx * dx + dy * dy < errsq)
                return true;
        }

        return false;
    }

    fn addStars(self: *FrameAligner, frame: u32, frame_stack: FrameStack, dx: f32, dy: f32) !void {
        const first_star = frame_stack.frames.items(.first_star);
        const off = first_star[frame];
        const num_stars = frame_stack.numStars(frame, first_star);
        var i: u32 = 0;
        const xs = frame_stack.stars.items(.x);
        const ys = frame_stack.stars.items(.y);
        try self.all_stars.ensureUnusedCapacity(self.a, num_stars);
        while (i < num_stars) : (i += 1) {
            // TODO: Deduplicating
            const x = xs[off + i] + dx;
            const y = ys[off + i] + dy;
            if (!self.hasStar(x, y, 50)) { // TODO: remove hardcoded value
                self.all_stars.appendAssumeCapacity(.{ .x = xs[off + i] + dx, .y = ys[off + i] + dy });
            }
        }

        // Update the constellations
        self.all_constellations.len = 0;
        var constellation_extractor = try alignment.constellation.ConstellationExtractor.init(self.a, .{});
        defer constellation_extractor.deinit(self.a);
        try constellation_extractor.extract(self.a, &self.all_constellations, self.all_stars.items(.x), self.all_stars.items(.y));
        // std.log.info("{} stars and {} constellations so far...", .{ self.all_stars.len, self.all_constellations.len });
    }

    const ConstellationPair = struct {
        internal_constellation: u32,
        frame_constellation: u32,
        frame_rotation: u8,
        distance_sq: f32,
    };

    fn closestConstellation(self: FrameAligner, frame: u32, frame_stack: FrameStack) ConstellationPair {
        const first_constellation = frame_stack.frames.items(.first_constellation);
        const num_constellations = frame_stack.numConstellations(frame, first_constellation);
        const off = first_constellation[frame];
        var min_dist_sq: f32 = std.math.f32_max;
        var min_i: u32 = 0;
        var min_j: u32 = 0;
        var rot_j: u8 = 0;

        var i: u32 = 0;
        while (i < self.all_constellations.len) : (i += 1) {
            const ci = self.all_constellations.get(i);
            var j: u32 = 0;
            while (j < num_constellations) : (j += 1) {
                const cj = frame_stack.constellations.get(off + j);
                const result = ci.cmp(cj);
                if (result.distance_sq < min_dist_sq) {
                    min_i = i;
                    min_j = off + j;
                    min_dist_sq = result.distance_sq;
                    rot_j = result.rotation;
                }
            }
        }

        return .{
            .internal_constellation = min_i,
            .frame_constellation = min_j,
            .frame_rotation = rot_j,
            .distance_sq = min_dist_sq,
        };
    }

    fn processNextFrame(self: *FrameAligner, offsets: *FrameOffsetList, frame_stack: FrameStack) !void {
        var closest_frame: u32 = 0;
        var closest_pair: ConstellationPair = .{
            .internal_constellation = undefined,
            .frame_constellation = undefined,
            .frame_rotation = undefined,
            .distance_sq = std.math.f32_max,
        };
        var unprocessed_frames_index: usize = undefined;
        for (self.unprocessed_frames.items) |frame_index, i| {
            const pair = self.closestConstellation(frame_index, frame_stack);
            if (pair.distance_sq < closest_pair.distance_sq) {
                closest_frame = frame_index;
                closest_pair = pair;
                unprocessed_frames_index = i;
            }
        }

        const c0 = self.all_constellations.get(closest_pair.internal_constellation);
        const c1 = frame_stack.constellations.get(closest_pair.frame_constellation).rotate(closest_pair.frame_rotation);

        const first_star_for_frame = frame_stack.frames.items(.first_star)[closest_frame];

        var dx: f32 = 0;
        var dy: f32 = 0;

        var i: usize = 0;
        while (i < c0.stars.len) : (i += 1) {
            const s0x = self.all_stars.items(.x)[c0.stars[1]];
            const s0y = self.all_stars.items(.y)[c0.stars[1]];
            const s1x = frame_stack.stars.items(.x)[first_star_for_frame + c1.stars[1]];
            const s1y = frame_stack.stars.items(.y)[first_star_for_frame + c1.stars[1]];
            dx += s0x - s1x;
            dy += s0y - s1y;
        }

        dy /= @intToFloat(f32, c0.stars.len);
        dx /= @intToFloat(f32, c0.stars.len);

        try self.addStars(closest_frame, frame_stack, dx, dy);
        _ = self.unprocessed_frames.swapRemove(unprocessed_frames_index);

        offsets.set(closest_frame, .{ .dx = dx, .dy = dy });

        // std.log.info("aligning: {} (image: {}, rotation: {}, distance: {d}, displacement: {d:.2} {d:.2})", .{
        //     closest_frame,
        //     frame_stack.frames.items(.image_index)[closest_frame],
        //     closest_pair.frame_rotation,
        //     closest_pair.distance_sq,
        //     dx,
        //     dy,
        // });
    }

    pub fn alignFrames(
        self: *FrameAligner,
        a: Allocator,
        offsets: *FrameOffsetList,
        progress: *Progress.Node,
        frame_stack: FrameStack,
    ) !void {
        assert(frame_stack.frames.len > 0);

        try offsets.ensureTotalCapacity(a, frame_stack.frames.len);

        var align_progress = progress.start("Aligning frames", frame_stack.frames.len);
        defer align_progress.end();
        align_progress.activate();

        const first_star = frame_stack.frames.items(.first_star);

        // Set the reference frame to the frame with the most stars, and start there.
        {
            var max: u32 = 0;
            var i: u32 = 0;
            while (i < frame_stack.frames.len) : (i += 1) {
                const num_stars = frame_stack.numStars(i, first_star);
                if (num_stars > max) {
                    max = num_stars;
                    self.reference_frame = i;
                }
            }
            offsets.set(self.reference_frame, .{ .dx = 0, .dy = 0 });
        }

        // Add the stars from the reference frame
        try self.addStars(self.reference_frame, frame_stack, 0, 0);

        // Also make a list of frames which have yet to be aligned.
        {
            self.unprocessed_frames.items.len = 0;
            try self.unprocessed_frames.ensureTotalCapacity(self.a, frame_stack.frames.len - 1);
            var i: u32 = 0;
            while (i < frame_stack.frames.len) : (i += 1) {
                if (i != self.reference_frame) {
                    self.unprocessed_frames.appendAssumeCapacity(i);
                }
            }
        }

        while (self.unprocessed_frames.items.len > 0) {
            align_progress.completeOne();
            try self.processNextFrame(offsets, frame_stack);
        }
    }
};
