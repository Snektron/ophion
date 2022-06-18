const std = @import("std");
const Allocator = std.mem.Allocator;
const Progress = std.Progress;
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

fn loadImages(progress: *Progress.Node, a: Allocator, paths: []const []const u8) ![]Image {
    var load_progress = progress.start("Loading images", paths.len);
    defer load_progress.end();
    load_progress.activate();

    var images = try a.alloc(Image, paths.len);
    errdefer a.free(images);

    // Initialize images just so that we can make the defer easier.
    for (images) |*image| image.* = Image.init(a, Image.Descriptor.empty) catch unreachable;
    errdefer for (images) |image| image.deinit(a);

    var fits_decoder = formats.fits.decoder(a);
    defer fits_decoder.deinit();

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
        filters.normalize.apply(image.*);
    }

    return images;
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

    var progress_root = progress.start("", 2);
    defer progress_root.end();

    const images = loadImages(progress_root, allocator, opts.inputs) catch return 1;
    defer {
        for (images) |image| image.deinit(allocator);
        allocator.free(images);
    }

    var aligner = alignment.Aligner.init(allocator);
    defer aligner.deinit();

    try aligner.alignImages(progress_root, images);

    for (aligner.frames.items) |frame| {
        progress.log("{s}: {} stars\n", .{ opts.inputs[frame.index], frame.stars.len });
    }

    return 0;
}
