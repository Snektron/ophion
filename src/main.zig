const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const fits = @import("formats/fits.zig");
const Image = @import("Image.zig");
const log = std.log.scoped(.main);

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

    var image = blk: {
        const file = try std.fs.cwd().openFile(opts.input_path, .{});
        defer file.close();

        var fits_reader = try fits.read(allocator, file.reader());
        defer fits_reader.deinit();

        if (fits_reader.header.format != .float64) {
            // TODO: We probably want to convert this at some point
            return error.InvalidFitsFormat;
        }

        if (fits_reader.header.shape.items.len != 2) {
            return error.InvalidFitsFormat;
        }

        const pixels = try fits_reader.readDataAlloc(allocator);
        break :blk Image{
            .width = fits_reader.header.shape.items[0],
            .height = fits_reader.header.shape.items[1],
            .pixels = pixels.float64.ptr,
        };
    };
    defer image.free(allocator);

    log.info("Loaded image of {}x{} pixels", .{ image.width, image.height });

    const file = try std.fs.cwd().createFile("balls.fits", .{});
    defer file.close();

    _ = try fits.write(
        file.writer(),
        fits.Header{
            .format = .float64,
            .shape = .{.items = &.{ image.width, image.height }, .capacity = 2},
            .extra = .{.primary = .{.is_simple = true}},
        },
        .{.float64 = image.data()},
    );
}
