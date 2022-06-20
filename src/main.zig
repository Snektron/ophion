const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Progress = std.Progress;
const Image = @import("Image.zig");
const formats = @import("formats.zig");
const filters = @import("filters.zig");
const alignment = @import("alignment.zig");
const log = std.log.scoped(.main);
const FitsDecoder = formats.fits.FitsDecoder;

pub const log_level = .debug;

const Options = struct {
    prog_name: []const u8,

    inputs: [][]const u8,
    export_individual_color: ?[]const u8,
    darkframe: ?[]const u8,
    biasframe: ?[]const u8,

    fn parse(a: Allocator) !Options {
        const stderr = std.io.getStdErr().writer();

        var help = false;

        var args = std.process.args();
        const prog_name = args.next() orelse return error.ExecutableNameMissing;

        var inputs = std.ArrayList([]const u8).init(a);
        defer inputs.deinit();

        var export_individual_color: ?[]const u8 = null;
        var darkframe: ?[]const u8 = null;
        var biasframe: ?[]const u8 = null;

        invalid: {
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                    help = true;
                } else if (std.mem.eql(u8, arg, "--export-individual-color")) {
                    export_individual_color = args.next() orelse {
                        try stderr.print("Error: Missing required <directory> to --export-individual-color\n", .{});
                        break :invalid;
                    };
                } else if (std.mem.eql(u8, arg, "--dark")) {
                    darkframe = args.next() orelse {
                        try stderr.print("Error: Missing required <path> to --dark\n", .{});
                        break :invalid;
                    };
                } else if (std.mem.eql(u8, arg, "--bias")) {
                    biasframe = args.next() orelse {
                        try stderr.print("Error: Missing required <path> to --bias\n", .{});
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
                try stderr.print("Error: Missing at least one <input path>\n", .{});
                break :invalid;
            }

            return Options{
                .prog_name = prog_name,
                .inputs = inputs.toOwnedSlice(),
                .export_individual_color = export_individual_color,
                .darkframe = darkframe,
                .biasframe = biasframe,
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
            \\--export-individual-color <directory>
            \\    Export the unaltered color versions of each decoded input image into
            \\    <directory>.
            \\--dark <path>
            \\    Specify the darkframe to be used.
            \\--bias <path>
            \\    Specify the biasframe to be used.
            ,
            .{prog_name},
        );
    }
};

fn importImages(fits_decoder: *FitsDecoder, progress: *Progress.Node, dark: ?Image, bias: ?Image, a: Allocator, paths: []const []const u8) ![]Image {
    var load_progress = progress.start("Loading images", paths.len);
    defer load_progress.end();
    load_progress.activate();

    var images = try a.alloc(Image, paths.len);
    errdefer a.free(images);

    // Initialize images just so that we can make the defer easier.
    for (images) |*image| image.* = Image.init(a, Image.Descriptor.empty) catch unreachable;
    errdefer for (images) |image| image.deinit(a);

    const cwd = std.fs.cwd();

    for (images) |*image, i| {
        // https://github.com/ziglang/zig/pull/10859#issuecomment-1159508818
        if (i != 0) load_progress.completeOne();

        const path = paths[i];

        var managed = image.managed(a);
        var file = cwd.openFile(path, .{}) catch |err| {
            log.err("Failed to open file '{s}': {s}", .{ path, @errorName(err) });
            return error.LoadFailed;
        };
        defer file.close();

        fits_decoder.decoder().decodeFile(&managed, file) catch |err| switch (err) {
            error.NotOpenForReading => unreachable,
            else => |other| {
                log.err("Failed to read file '{s}': {s}", .{ path, @errorName(other) });
                return error.LoadFailed;
            },
        };

        image.* = managed.unmanaged();
        filters.denoise.reduceInstrumentNoise(image.*, dark, bias);
        filters.normalize.apply(image.*);
    }

    return images;
}

fn exportColor(a: Allocator, progress: *Progress.Node, paths: []const []const u8, images: []Image, base_dir: []const u8) !void {
    assert(paths.len == images.len);

    var export_progress = progress.start("Exporting decoded images", paths.len);
    defer export_progress.end();
    export_progress.activate();

    const dir = std.fs.cwd().openDir(base_dir, .{}) catch |err| {
        log.err("Failed to open output directory '{s}': {s}", .{ base_dir, @errorName(err)  });
        return error.ExportFailed;
    };

    var path = std.ArrayList(u8).init(a);
    defer path.deinit();

    var ppm_encoder = formats.ppm.encoder(.{});
    for (images) |image, i| {
        if (i != 0) export_progress.completeOne();

        const basename = std.fs.path.basename(paths[i]);
        const ext = std.fs.path.extension(basename);

        path.items.len = 0;
        try std.fmt.format(path.writer(), "{s}.ppm", .{basename[0..basename.len - ext.len]});

        const file = dir.createFile(path.items, .{}) catch |err| {
            log.err("Failed to open file '{s}': {s}", .{ path.items, @errorName(err) });
            return error.ExportFailed;
        };
        defer file.close();

        try ppm_encoder.encoder().encodeFile(file, image);
    }
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.log.warn("Memory leaked", .{});
    };
    const allocator = gpa.allocator();

    var opts = Options.parse(allocator) catch |err| switch (err) {
        error.InvalidArgs => std.process.exit(1),
        error.Help => return 0,
        else => |errs| return errs,
    };
    defer opts.deinit(allocator);

    var progress = Progress{};

    var progress_root = progress.start("", 0);
    defer progress_root.end();

    var fits_decoder = formats.fits.decoder(allocator);
    defer fits_decoder.deinit();

    const darkframe = if (opts.darkframe) |path| blk: {
        var image = Image.Managed.init(allocator, Image.Descriptor.empty) catch unreachable;
        try fits_decoder.decoder().decodePath(&image, path);
        break :blk image.unmanaged();
    } else null;
    defer if (darkframe) |image| image.deinit(allocator);

    const biasframe = if (opts.biasframe) |path| blk: {
        var image = Image.Managed.init(allocator, Image.Descriptor.empty) catch unreachable;
        try fits_decoder.decoder().decodePath(&image, path);
        break :blk image.unmanaged();
    } else null;

    const images = importImages(&fits_decoder, progress_root, darkframe, biasframe, allocator, opts.inputs) catch return 1;
    defer {
        for (images) |image| image.deinit(allocator);
        allocator.free(images);
    }

    defer if (biasframe) |image| image.deinit(allocator);

    if (opts.export_individual_color) |base_dir| {
        exportColor(allocator, progress_root, opts.inputs, images, base_dir) catch return 1;
    }

    var frame_extractor = alignment.frame.FrameExtractor.init(allocator);
    defer frame_extractor.deinit();

    var frame_stack = try frame_extractor.extract(allocator, progress_root, images);
    defer frame_stack.deinit(allocator);

    var aligner = alignment.aligner.FrameAligner.init(allocator);
    defer aligner.deinit();

    var offsets = alignment.aligner.FrameOffsetList{};
    defer offsets.deinit(allocator);
    try aligner.alignFrames(allocator, &offsets, progress_root, frame_stack);

    var images_to_stack = try allocator.alloc(Image, frame_stack.frames.len);
    defer allocator.free(images_to_stack);

    {
        const image_index = frame_stack.frames.items(.image_index);
        for (images_to_stack) |*image, i| {
            image.* = images[image_index[i]];
        }
    }

    {
        var denoise_progress = progress_root.start("Denoising images", images.len);
        defer denoise_progress.end();
        denoise_progress.activate();

        var denoiser = filters.denoise.Denoiser.init(allocator);
        defer denoiser.deinit();
        for (images_to_stack) |image, i| {
            if (i != 0) denoise_progress.completeOne();
            try denoiser.apply(image);
        }
    }

    var result = Image.Managed.init(allocator, Image.Descriptor.empty) catch unreachable;
    defer result.deinit();

    {
        var stack_progress = progress_root.start("Stacking images", 0);
        defer stack_progress.end();
        stack_progress.activate();
        try filters.stacking.apply(&result, images_to_stack, offsets.items(.dx), offsets.items(.dy));
    }

    try formats.ppm.encoder(.{}).encoder().encodePath("out.ppm", result.unmanaged());

    // var i: usize = 0;
    // const image_index = frame_stack.frames.items(.image_index);
    // const first_star = frame_stack.frames.items(.first_star);
    // const first_constellation = frame_stack.frames.items(.first_constellation);
    // while (i < frame_stack.frames.len) : (i += 1) {
    //     progress.log("{s}: {} stars, {} constellations, offset {d:.2} {d:.2}\n", .{
    //         opts.inputs[image_index[i]],
    //         frame_stack.numStars(i, first_star),
    //         frame_stack.numConstellations(i, first_constellation),
    //         offsets.items(.dx)[i],
    //         offsets.items(.dy)[i],
    //     });
    // }

    return 0;
}
