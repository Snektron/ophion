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

    input_path: []const u8,

    fn parse() !Options {
        const stderr = std.io.getStdErr().writer();

        var maybe_input_path: ?[]const u8 = null;
        var help = false;

        var args = std.process.args();
        const prog_name = args.next() orelse return error.ExecutableNameMissing;

        invalid: {
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                    help = true;
                } else if (maybe_input_path == null) {
                    maybe_input_path = arg;
                } else {
                    try stderr.print("Error: Superficial argument '{s}'\n", .{arg});
                    break :invalid;
                }
            }

            if (help) {
                try printHelp(prog_name);
                return error.Help;
            }

            const input_path = maybe_input_path orelse {
                try stderr.print("Error: Missing required positional argument <input path>\n", .{});
                break :invalid;
            };

            return Options{
                .prog_name = prog_name,
                .input_path = input_path,
            };
        }

        try stderr.print("See '{s} --help'", .{prog_name});
        return error.InvalidArgs;
    }

    fn printHelp(prog_name: []const u8) !void {
        const stdout = std.io.getStdOut().writer();
        try stdout.print(
            \\Usage: {s} [-h|--help] <input path>
            \\
            ,
            .{prog_name},
        );
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.log.warn("Memory leaked", .{});
    };
    const allocator = gpa.allocator();

    var opts = Options.parse() catch |err| switch (err) {
        error.InvalidArgs => std.process.exit(1),
        error.Help => return,
        else => |errs| return errs,
    };

    log.info("Loading '{s}'", .{ opts.input_path });

    var image = try Image.Managed.init(allocator, Image.Descriptor.empty);
    defer image.deinit();

    var grayscale = try Image.Managed.init(allocator, Image.Descriptor.empty);
    defer grayscale.deinit();

    var tmp = try Image.Managed.init(allocator, Image.Descriptor.empty);
    defer tmp.deinit();

    {
        var decoder = formats.fits.decoder(allocator);
        defer decoder.deinit();
        try decoder.decoder().decodePath(&image, opts.input_path);
    }

    log.info("Loaded image of {}x{} pixels, {:.2}", .{
        image.descriptor.width,
        image.descriptor.height,
        std.fmt.fmtIntSizeBin(image.descriptor.bytes()),
    });

    filters.normalize.apply(image.unmanaged());
    try filters.grayscale.apply(&grayscale, image.unmanaged());
    try filters.gaussian.apply(&tmp, &image, grayscale.unmanaged(), filters.gaussian.Kernel.init(3));
    try filters.binarize.apply(&image, tmp.unmanaged(), .{});

    log.info("Extracting stars", .{});

    var coarse_stars = alignment.coarse.CoarseStarList{};
    defer coarse_stars.deinit(allocator);
    {
        var coarse_extractor = alignment.coarse.CoarseStarExtractor.init(allocator);
        defer coarse_extractor.deinit();
        try coarse_extractor.extract(allocator, &coarse_stars, image.unmanaged());
    }

    log.info("Coarse extractor found {} stars", .{ coarse_stars.len });

    var fine_stars = alignment.StarList{};
    defer fine_stars.deinit(allocator);
    try alignment.fine.extract(allocator, &fine_stars, grayscale.unmanaged(), coarse_stars);

    log.info("Fine extractor found {} stars", .{ fine_stars.len });

    var i: usize = 0;
    while (i < fine_stars.len) : (i += 1) {
        const star = fine_stars.get(i);
        log.info("({d:.2}, {d:.2})", .{ star.x, star.y });
    }

    log.info("Saving result", .{});
    try formats.ppm.encoder(.{}).encoder().encodePath("out.ppm", image.unmanaged());
}
