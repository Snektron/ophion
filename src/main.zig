const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Progress = std.Progress;
const Image = @import("Image.zig");
const formats = @import("formats.zig");
const filters = @import("filters.zig");
const alignment = @import("alignment.zig");
const log = std.log;
const FitsDecoder = formats.fits.FitsDecoder;

pub const log_level = .debug;

const Options = struct {
    const Command = union(enum) {
        const PixelMedian = struct {
            inputs: []const []const u8,
            output: ?[]const u8,
        };
        const Stack = struct {
            inputs: []const []const u8,
            output: ?[]const u8,
            dark: ?[]const u8,
            bias: ?[]const u8,
        };

        pixel_median: PixelMedian,
        stack: Stack,
        help,
    };

    prog_name: []const u8,
    command: Command,

    fn parse(a: Allocator) !Options {
        const stderr = std.io.getStdErr().writer();

        var args = std.process.args();
        const prog_name = args.next() orelse return error.ExecutableNameMissing;

        invalid: {
            const command_name = args.next() orelse {
                try stderr.writeAll("Error: Missing <command>\n");
                break :invalid;
            };

            const command_or_err = if (std.mem.eql(u8, command_name, "stack"))
                parseStack(a, stderr, &args)
            else if (std.mem.eql(u8, command_name, "pixel-median"))
                parsePixelMedian(a, stderr, &args)
            else if (std.mem.eql(u8, command_name, "help"))
                @as(Command, .help)
            else {
                try stderr.print("Error: Invalid command '{s}'\n", .{command_name});
                break :invalid;
            };

            const command = command_or_err catch |err| switch (err) {
                error.InvalidArgs => break :invalid,
                else => |others| return others,
            };

            return Options{
                .prog_name = prog_name,
                .command = command,
            };
        }

        try stderr.print("See '{s} help'", .{prog_name});
        return error.InvalidArgs;
    }

    fn parseStack(a: Allocator, stderr: std.fs.File.Writer, args: *std.process.ArgIterator) !Command {
        var inputs = std.ArrayList([]const u8).init(a);
        defer inputs.deinit();

        var output: ?[]const u8 = null;
        var dark: ?[]const u8 = null;
        var bias: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                output = args.next() orelse {
                    try stderr.print("Error: Missing required argument <path> to {s}\n", .{ arg });
                    return error.InvalidArgs;
                };
            } else if (std.mem.eql(u8, arg, "--dark")) {
                dark = args.next() orelse {
                    try stderr.writeAll("Error: Missing required argument <path> to --dark\n");
                    return error.InvalidArgs;
                };
            } else if (std.mem.eql(u8, arg, "--bias")) {
                bias = args.next() orelse {
                    try stderr.writeAll("Error: Missing required argument <path> to --bias\n");
                    return error.InvalidArgs;
                };
            } else {
                try inputs.append(arg);
            }
        }

        if (inputs.items.len == 0) {
            try stderr.writeAll("Error: Command 'stack' requires at least one <input>\n");
            return error.InvalidArgs;
        }

        return Command{
            .stack = .{
                .inputs = inputs.toOwnedSlice(),
                .output = output,
                .dark = dark,
                .bias = bias,
            },
        };
    }

    fn parsePixelMedian(a: Allocator, stderr: std.fs.File.Writer, args: *std.process.ArgIterator) !Command {
        var inputs = std.ArrayList([]const u8).init(a);
        defer inputs.deinit();

        var output: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                output = args.next() orelse {
                    try stderr.print("Error: Missing required argument <path> to {s}\n", .{ arg });
                    return error.InvalidArgs;
                };
            } else {
                try inputs.append(arg);
            }
        }

        if (inputs.items.len == 0) {
            try stderr.writeAll("Error: Command 'pixel-median' requires at least one <input>\n");
            return error.InvalidArgs;
        }

        return Command{
            .pixel_median = .{
                .inputs = inputs.toOwnedSlice(),
                .output = output,
            },
        };
    }

    fn deinit(self: Options, a: Allocator) void {
        switch (self.command) {
            .stack => |stack| a.free(stack.inputs),
            .pixel_median => |pixel_median| a.free(pixel_median.inputs),
            .help => {},
        }
    }
};

fn printHelp(prog_name: []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Usage: {s} <command> [command-options...]
        \\
        \\Commands:
        \\help
        \\    Show this message and exit
        \\
        \\stack [options] <inputs...>
        \\    Stack a number of images together.
        \\    Additional options:
        \\    -o --output <path>
        \\        Write the result to this path.
        \\    --dark <path>
        \\        Specify path to dark image to denoise input with.
        \\    --bias <path>
        \\        Specify path to bias image to denoise input with.
        \\
        \\pixel-median [options] <input...>
        \\    Produce an image which is the pixel-wise median of each input image,
        \\    which can for example be used as dark- or bias when stacking.
        \\    Each image should be the same size.
        \\    Additional options:
        \\    -o --output <path>
        \\        Write the result to this path.
        \\
        ,
        .{prog_name},
    );
}

fn importImage(image: *Image.Managed, fits_decoder: *FitsDecoder, cwd: std.fs.Dir, path: []const u8) !void {
    var file = cwd.openFile(path, .{}) catch |err| {
        log.err("Failed to open file '{s}': {s}", .{ path, @errorName(err) });
        return error.ReportedError;
    };
    defer file.close();

    fits_decoder.decoder().decodeFile(image, file) catch |err| switch (err) {
        error.NotOpenForReading => unreachable,
        else => |other| {
            log.err("Failed to read file '{s}': {s}", .{ path, @errorName(other) });
            return error.ReportedError;
        },
    };
}

fn importImages(cwd: std.fs.Dir, fits_decoder: *FitsDecoder, progress: *Progress.Node, a: Allocator, paths: []const []const u8) ![]Image {
    var load_progress = progress.start("Loading images", paths.len);
    defer load_progress.end();
    load_progress.activate();

    var images = try a.alloc(Image, paths.len);
    errdefer a.free(images);

    // Initialize images just so that we can make the defer easier.
    for (images) |*image| image.* = Image.empty;
    errdefer for (images) |image| image.deinit(a);

    for (images) |*image, i| {
        // https://github.com/ziglang/zig/pull/10859#issuecomment-1159508818
        if (i != 0) load_progress.completeOne();

        const path = paths[i];
        var managed = image.managed(a);
        try importImage(&managed, fits_decoder, cwd, path);
        image.* = managed.unmanaged();
    }

    return images;
}

fn stack(cwd: std.fs.Dir, allocator: Allocator, opts: Options.Command.Stack) !void {
    var progress = Progress{};

    var progress_root = progress.start("", 0);
    defer progress_root.end();

    var fits_decoder = formats.fits.decoder(allocator);
    defer fits_decoder.deinit();

    const dark_image = if (opts.dark) |path| blk: {
        var image = Image.Managed.empty(allocator);
        try importImage(&image, &fits_decoder, cwd, path);
        break :blk image.unmanaged();
    } else
        null;
    defer if (dark_image) |image| image.deinit(allocator);

    const bias_image = if (opts.bias) |path| blk: {
        var image = Image.Managed.empty(allocator);
        try importImage(&image, &fits_decoder, cwd, path);
        break :blk image.unmanaged();
    } else
        null;
    defer if (bias_image) |image| image.deinit(allocator);

    const images = try importImages(cwd, &fits_decoder, progress_root, allocator, opts.inputs);
    defer {
        for (images) |image| image.deinit(allocator);
        allocator.free(images);
    }

    for (images) |image| {
        filters.dark_bias_drame.apply(image, dark_image, bias_image, .{.dark_frame_multiplier = 5.0 / 2.0});
        filters.normalize.apply(image);
    }

    if (images.len == 1) {
        if (opts.output) |path| {
            var denoiser = filters.denoise.Denoiser.init(allocator);
            defer denoiser.deinit();
            try denoiser.apply(images[0]);
            try formats.ppm.encoder(.{}).encoder().encodePath(path, images[0]);
        }
        return;
    }

    var frame_extractor = alignment.frame.FrameExtractor.init(allocator);
    defer frame_extractor.deinit();

    var frame_stack = try frame_extractor.extract(allocator, progress_root, images);
    defer frame_stack.deinit(allocator);

    if (frame_stack.frames.len == 0) {
        log.err("No stars detected in any frame", .{});
        return error.ReportedError;
    }

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

    // {
    //     var denoise_progress = progress_root.start("Denoising images", images.len);
    //     defer denoise_progress.end();
    //     denoise_progress.activate();

    //     var denoiser = filters.denoise.Denoiser.init(allocator);
    //     defer denoiser.deinit();
    //     for (images_to_stack) |image, i| {
    //         if (i != 0) denoise_progress.completeOne();
    //         try denoiser.apply(image);
    //     }
    // }

    var result = Image.Managed.empty(allocator);
    defer result.deinit();

    {
        var stack_progress = progress_root.start("Stacking images", 0);
        defer stack_progress.end();
        stack_progress.activate();
        try filters.stacking.apply(&result, images_to_stack, offsets.items(.dx), offsets.items(.dy));
    }

    var denoiser = filters.denoise.Denoiser.init(allocator);
    defer denoiser.deinit();
    try denoiser.apply(result.unmanaged());
    // filters.normalize.apply(result.unmanaged());

    if (opts.output) |path| {
        try formats.ppm.encoder(.{}).encoder().encodePath(path, result.unmanaged());
    }

    var i: usize = 0;
    const image_index = frame_stack.frames.items(.image_index);
    const first_star = frame_stack.frames.items(.first_star);
    const first_constellation = frame_stack.frames.items(.first_constellation);
    while (i < frame_stack.frames.len) : (i += 1) {
        progress.log("{s}: {} stars, {} constellations, offset {d:.2} {d:.2}\n", .{
            opts.inputs[image_index[i]],
            frame_stack.numStars(i, first_star),
            frame_stack.numConstellations(i, first_constellation),
            offsets.items(.dx)[i],
            offsets.items(.dy)[i],
        });
    }
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        log.warn("Memory leaked", .{});
    };
    const allocator = gpa.allocator();
    const cwd = std.fs.cwd();

    var opts = Options.parse(allocator) catch |err| switch (err) {
        error.InvalidArgs => return 1,
        else => |errs| return errs,
    };
    defer opts.deinit(allocator);

    const maybe_err = switch (opts.command) {
        .stack => |stack_opts| stack(cwd, allocator, stack_opts),
        .pixel_median => return error.Todo,
        .help => {
            try printHelp(opts.prog_name);
            return 0;
        },
    };

    maybe_err catch |err| switch (err) {
        error.ReportedError => return 1,
        else => |other| return other,
    };

    return 0;
}
