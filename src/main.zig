const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Fits = @import("formats/Fits.zig");

const Options = struct {
    arena: std.heap.ArenaAllocator,
    prog_name: []const u8,

    input_path: []const u8,

    fn parse(backing: *Allocator) !Options {
        const stderr = std.io.getStdErr().writer();

        var arena = std.heap.ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const allocator = &arena.allocator;

        var maybe_input_path: ?[]const u8 = null;
        var help = false;

        var args = std.process.args();
        const prog_name = try args.next(allocator) orelse error.ExecutableNameMissing;

        invalid: {
            while (args.next(allocator)) |err_or_arg| {
                const arg = try err_or_arg;
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
                .arena = arena,
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

    fn deinit(self: *Options) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit()) {
        std.log.warn("Memory leaked", .{});
    };
    const allocator = &gpa.allocator;

    var opts = Options.parse(allocator) catch |err| switch (err) {
        error.InvalidArgs => std.process.exit(1),
        error.Help => return,
        else => |errs| return errs,
    };
    defer opts.deinit();

    const file = try std.fs.cwd().openFile(opts.input_path, .{});
    defer file.close();

    var source = std.io.StreamSource{.file = file};
    var fits = try Fits.read(allocator, &source);
    defer fits.deinit();

    while (true) {
        std.debug.print("Axes: {}, ", .{ fits.header.shape.items.len });
        for (fits.header.shape.items) |axis, i| {
            if (i != 0) {
                std.debug.print("x", .{});
            }
            std.debug.print("{}", .{axis});
        }

        std.debug.print("\n", .{});
        std.debug.print("Format: {}\n", .{ fits.header.format });
        std.debug.print("Total elements: {}\n", .{ fits.header.size() });
        std.debug.print("Data size: {:.2}\n", .{ std.fmt.fmtIntSizeBin(fits.header.dataSize()) });

        const data = try fits.readDataAlloc(allocator);
        defer data.free(allocator);

        const arr = data.float64;
        var min: f64 = std.math.f64_max;
        var max: f64 = -std.math.f64_max;
        for (arr) |x| {
            max = std.math.max(max, x);
            min = std.math.min(min, x);
        }

        std.debug.print("Data range: [{d:.2}, {d:.2}]\n", .{ min, max });

        if (!try fits.readNextHeader()) break;
    }
}
