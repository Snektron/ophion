const std = @import("std");
const Progress = std.Progress;
const Allocator = std.mem.Allocator;

pub const coarse = @import("alignment/coarse_star_extraction.zig");
pub const fine = @import("alignment/fine_star_extraction.zig");
pub const constellation = @import("alignment/constellation_extraction.zig");

const Image = @import("Image.zig");
const filters = @import("filters.zig");
const StarList = fine.FineStarList;
const ConstellationList = constellation.ConstellationList;

const Frame = struct {
    /// The image index in the input array that this frame represents
    index: usize,
    /// The base image for this frame.
    image: Image,
    /// The stars in this frame, relative to the image.
    stars: StarList,
    /// The constellations in this frame, relative to the image.
    /// TODO: Spatial structure instead?
    constellations: ConstellationList,
};

pub const Aligner = struct {
    a: Allocator,
    tmp_grayscale: Image,
    tmp_starmask: Image,
    coarse_stars: coarse.CoarseStarList = .{},
    frames: std.ArrayListUnmanaged(Frame) = .{},

    pub fn init(a: Allocator) Aligner {
        return .{
            .a = a,
            .tmp_grayscale = Image.init(a, Image.Descriptor.empty) catch unreachable,
            .tmp_starmask = Image.init(a, Image.Descriptor.empty) catch unreachable,
        };
    }

    pub fn deinit(self: *Aligner) void {
        self.tmp_grayscale.deinit(self.a);
        self.tmp_starmask.deinit(self.a);

        self.coarse_stars.deinit(self.a);
        for (self.frames.items) |*frame| {
            frame.stars.deinit(self.a);
            frame.constellations.deinit(self.a);
        }
        self.frames.deinit(self.a);
    }

    pub fn alignImages(self: *Aligner, progress: *Progress.Node, images: []Image) !void {
        var extract_progress = progress.start("Extracting constellations", images.len);
        defer extract_progress.end();
        extract_progress.activate();

        self.frames.items.len = 0;

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

        for (images) |image, i| {
            if (i != 0) extract_progress.completeOne();

            try filters.grayscale.apply(&tmp_grayscale, image);
            try filters.gaussian.apply(&tmp_grayscale, &tmp_starmask, tmp_grayscale.unmanaged(), gaussian_kernel);
            try filters.binarize.apply(&tmp_starmask, tmp_grayscale.unmanaged(), .{});

            self.coarse_stars.len = 0;
            try coarse_extractor.extract(self.a, &self.coarse_stars, tmp_starmask.unmanaged());

            var stars = StarList{};
            errdefer stars.deinit(self.a);
            try fine.extract(self.a, &stars, tmp_grayscale.unmanaged(), self.coarse_stars);

            var constellations = ConstellationList{};
            errdefer constellations.deinit(self.a);
            try constellation_extractor.extract(self.a, &constellations, stars);

            if (constellations.len > 0) {
                try self.frames.append(self.a, .{
                    .index = i,
                    .image = image,
                    .stars = stars,
                    .constellations = constellations,
                });
            }
        }

        const Sorter = struct {
            fn cmp(_: void, a: Frame, b: Frame) bool {
                return a.stars.len > b.stars.len;
            }
        };
        std.sort.sort(Frame, self.frames.items, {}, Sorter.cmp);
    }
};
