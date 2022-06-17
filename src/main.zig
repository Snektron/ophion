const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Image = @import("Image.zig");
const formats = @import("formats.zig");
const filters = @import("filters.zig");
const alignment = @import("alignment.zig");
const log = std.log.scoped(.main);

pub const log_level = .debug;

const Options = struct {
    prog_name: []const u8,

    inputs: [][]const u8,
    export_color: ?[]const u8,
    export_starmask: ?[]const u8,

    fn parse(a: Allocator) !Options {
        const stderr = std.io.getStdErr().writer();

        var help = false;

        var args = std.process.args();
        const prog_name = args.next() orelse return error.ExecutableNameMissing;

        var inputs = std.ArrayList([]const u8).init(a);
        defer inputs.deinit();

        var export_color: ?[]const u8 = null;
        var export_starmask: ?[]const u8 = null;

        invalid: {
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                    help = true;
                } else if (std.mem.eql(u8, arg, "--export-color")) {
                    export_color = args.next() orelse {
                        try stderr.print("Error: Missing required <path> to --export-color\n", .{});
                        break :invalid;
                    };
                } else if (std.mem.eql(u8, arg, "--export-starmask")) {
                    export_starmask = args.next() orelse {
                        try stderr.print("Error: Missing required <path> to --export-starmask\n", .{});
                        break :invalid;
                    };
                } else {
                    try inputs.append(arg);
                }
            }

            if (help) {
                try printHelp(prog_name);
                return error.Help;
            }

            if (inputs.items.len == 0) {
                try stderr.print("Error: Missing required positional argument <input path>\n", .{});
                break :invalid;
            }

            return Options{
                .prog_name = prog_name,
                .inputs = inputs.toOwnedSlice(),
                .export_color = export_color,
                .export_starmask = export_starmask,
            };
        }

        try stderr.print("See '{s} --help'", .{prog_name});
        return error.InvalidArgs;
    }

    fn deinit(self: Options, a: Allocator) void {
        a.free(self.inputs);
    }

    fn printHelp(prog_name: []const u8) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print(
            \\Usage: {s} [options..] <image paths...>
            \\
            \\Options:
            \\-h --help
            \\    Show this message and exit.
            \\--export-color <path>
            \\    Export the given image as color in ppm format. If multiple input images
            \\    are given, exports the first.
            \\--export-starmask <path>
            \\    Export the starmask of the given image in ppm format. If multiple input
            \\    images are given, exports the first.
            \\
            ,
            .{prog_name},
        );
    }
};

const Input = struct {
    image_index: usize,
    stars: usize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.log.warn("Memory leaked", .{});
    };
    const allocator = gpa.allocator();

    var opts = Options.parse(allocator) catch |err| switch (err) {
        error.InvalidArgs => std.process.exit(1),
        error.Help => return,
        else => |errs| return errs,
    };
    defer opts.deinit(allocator);

    var inputs = try allocator.alloc(Input, opts.inputs.len);
    defer allocator.free(inputs);

    var image = try Image.Managed.init(allocator, Image.Descriptor.empty);
    defer image.deinit();

    var grayscale = try Image.Managed.init(allocator, Image.Descriptor.empty);
    defer grayscale.deinit();

    var tmp = try Image.Managed.init(allocator, Image.Descriptor.empty);
    defer tmp.deinit();

    var coarse_stars = alignment.coarse.CoarseStarList{};
    defer coarse_stars.deinit(allocator);

    var fine_stars = alignment.StarList{};
    defer fine_stars.deinit(allocator);

    for (inputs) |*input, i| {
        const path = opts.inputs[i];
        log.info(" Loading '{s}'", .{path});

        {
            var decoder = formats.fits.decoder(allocator);
            defer decoder.deinit();
            try decoder.decoder().decodePath(&image, path);
        }

        filters.normalize.apply(image.unmanaged());

        if (opts.export_color) |export_path| {
            try formats.ppm.encoder(.{}).encoder().encodePath(export_path, image.unmanaged());
        }

        try filters.grayscale.apply(&grayscale, image.unmanaged());
        try filters.gaussian.apply(&tmp, &image, grayscale.unmanaged(), filters.gaussian.Kernel.init(3));
        try filters.binarize.apply(&image, tmp.unmanaged(), .{ .min_stddev = 3 });

        if (opts.export_starmask) |export_path| {
            try formats.ppm.encoder(.{}).encoder().encodePath(export_path, image.unmanaged());
        }

        coarse_stars.len = 0;
        {
            var coarse_extractor = alignment.coarse.CoarseStarExtractor.init(allocator);
            defer coarse_extractor.deinit();
            try coarse_extractor.extract(allocator, &coarse_stars, image.unmanaged());
        }

        fine_stars.len = 0;
        try alignment.fine.extract(allocator, &fine_stars, grayscale.unmanaged(), coarse_stars);

        input.* = .{
            .image_index = i,
            .stars = fine_stars.len,
        };
    }

    const Sorter = struct {
        fn cmp(_: @This(), a: Input, b: Input) bool {
            return a.stars > b.stars;
        }
    };

    log.info("----", .{});

    std.sort.sort(Input, inputs, Sorter{}, Sorter.cmp);

    const min_stars = 3;
    for (inputs) |input| {
        if (input.stars < min_stars) {
            break;
        }
        log.info("{s}: {} stars", .{ opts.inputs[input.image_index], input.stars });
    }
}
