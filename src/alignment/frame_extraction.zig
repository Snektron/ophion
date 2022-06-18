const std = @import("std");
const Progress = std.Progress;
const Allocator = std.mem.Allocator;

const alignment = @import("../alignment.zig");
const coarse = alignment.coarse;
const fine = alignment.fine;
const constellation = alignment.constellation;

const Image = @import("../Image.zig");
const filters = @import("../filters.zig");
const StarList = fine.FineStarList;
const ConstellationList = constellation.ConstellationList;

pub const FrameStack = struct {
    // TODO: Add some spatial structure for the constellations?
    pub const Frame = struct {
        image_index: u32,
        first_star: u32,
        first_constellation: u32,
    };

    images: []Image,
    frames: std.MultiArrayList(Frame) = .{},
    stars: StarList = .{},
    constellations: ConstellationList = .{},

    pub fn deinit(self: *FrameStack, a: Allocator) void {
        self.frames.deinit(a);
        self.stars.deinit(a);
        self.constellations.deinit(a);
    }

    pub fn num_stars(self: FrameStack, i: usize, first_star: []const u32) usize {
        return if (i == self.frames.len - 1)
            self.stars.len - first_star[i]
        else
            first_star[i + 1] - first_star[i];
    }

    pub fn num_constellations(self: FrameStack, i: usize, first_constellation: []const u32) usize {
        return if (i == self.frames.len - 1)
            self.constellations.len - first_constellation[i]
        else
            first_constellation[i + 1] - first_constellation[i];
    }
};

pub const FrameExtractor = struct {
    a: Allocator,
    tmp_grayscale: Image,
    tmp_starmask: Image,
    coarse_stars: coarse.CoarseStarList = .{},

    pub fn init(a: Allocator) FrameExtractor {
        return .{
            .a = a,
            .tmp_grayscale = Image.init(a, Image.Descriptor.empty) catch unreachable,
            .tmp_starmask = Image.init(a, Image.Descriptor.empty) catch unreachable,
        };
    }

    pub fn deinit(self: *FrameExtractor) void {
        self.tmp_grayscale.deinit(self.a);
        self.tmp_starmask.deinit(self.a);
        self.coarse_stars.deinit(self.a);
    }

    pub fn alignImages(self: *FrameExtractor, a: Allocator, progress: *Progress.Node, images: []Image) !FrameStack {
        var extract_progress = progress.start("Extracting constellations", images.len);
        defer extract_progress.end();
        extract_progress.activate();

        // TODO: make unmanaged and move to struct
        var coarse_extractor = coarse.CoarseStarExtractor.init(self.a);
        defer coarse_extractor.deinit();
        var constellation_extractor = try constellation.ConstellationExtractor.init(self.a, .{});
        defer constellation_extractor.deinit(self.a);

        // TODO: make everything configurable
        var gaussian_kernel = filters.gaussian.Kernel.init(3);

        var tmp_grayscale = self.tmp_grayscale.managed(self.a);
        var tmp_starmask = self.tmp_starmask.managed(self.a);
        // Make sure that we update the memory in event of an error.
        // TODO: Probably going to be problems when either of these fail to resize.
        defer {
            self.tmp_grayscale = tmp_grayscale.unmanaged();
            self.tmp_starmask = tmp_starmask.unmanaged();
        }

        var frame_stack = FrameStack{
            .images = images,
        };
        errdefer frame_stack.deinit(a);

        for (images) |image, i| {
            if (i != 0) extract_progress.completeOne();

            try filters.grayscale.apply(&tmp_grayscale, image);
            try filters.gaussian.apply(&tmp_grayscale, &tmp_starmask, tmp_grayscale.unmanaged(), gaussian_kernel);
            try filters.binarize.apply(&tmp_starmask, tmp_grayscale.unmanaged(), .{});

            self.coarse_stars.len = 0;
            try coarse_extractor.extract(self.a, &self.coarse_stars, tmp_starmask.unmanaged());

            const first_star = frame_stack.stars.len;
            try fine.extract(
                a,
                &frame_stack.stars,
                tmp_grayscale.unmanaged(),
                self.coarse_stars.items(.x),
                self.coarse_stars.items(.y),
            );

            const first_constellation = frame_stack.constellations.len;
            try constellation_extractor.extract(
                a,
                &frame_stack.constellations,
                frame_stack.stars.items(.x)[first_star..],
                frame_stack.stars.items(.y)[first_star..],
            );

            const num_constellations = frame_stack.constellations.len - first_constellation;
            if (num_constellations > 0) {
                try frame_stack.frames.append(a, .{
                    .image_index = @intCast(u32, i),
                    .first_star = @intCast(u32, first_star),
                    .first_constellation = @intCast(u32, first_constellation),
                });
            } else {
                frame_stack.stars.len = first_star;
                frame_stack.constellations.len = first_constellation;
            }
        }

        return frame_stack;
    }
};
