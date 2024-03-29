const std = @import("std");
const StreamSource = std.io.StreamSource;
const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Image = @import("Image.zig");

pub const fits = @import("formats/fits.zig");
pub const ppm = @import("formats/ppm.zig");

pub fn Encoder(
    comptime Context: type,
    comptime EncodeError: type,
    comptime encodeFn: fn (context: Context, source: *StreamSource, image: Image) EncodeError!void,
) type {
    return struct {
        const Self = @This();
        pub const Error = EncodeError;

        context: Context,

        pub fn encode(self: Self, source: *StreamSource, image: Image) EncodeError!void {
            return encodeFn(self.context, source, image);
        }

        pub fn encodeFile(self: Self, file: File, image: Image) !void {
            var ss = StreamSource{ .file = file };
            return try self.encode(&ss, image);
        }

        pub fn encodePath(self: Self, path: []const u8, image: Image) !void {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            return try self.encodeFile(file, image);
        }
    };
}

pub fn Decoder(
    comptime Context: type,
    comptime DecodeError: type,
    comptime decodeFn: fn (context: Context, image: *Image.Managed, source: *StreamSource) DecodeError!void,
) type {
    return struct {
        const Self = @This();
        pub const Error = DecodeError;

        context: Context,

        pub fn decode(self: Self, image: *Image.Managed, source: *StreamSource) DecodeError!void {
            return decodeFn(self.context, image, source);
        }

        pub fn decodeFile(self: Self, image: *Image.Managed, file: File) !void {
            var ss = StreamSource{ .file = file };
            return try self.decode(image, &ss);
        }

        pub fn decodePath(self: Self, image: *Image.Managed, path: []const u8) !void {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();
            return try self.decodeFile(image, file);
        }
    };
}
