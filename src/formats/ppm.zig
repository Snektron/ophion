//! https://en.wikipedia.org/wiki/Netpbm

const std = @import("std");
const StreamSource = std.io.StreamSource;
const ColorImage = @import("../image.zig").ColorImage;

pub const Encoder = struct {
    fn convertChannel(channel: f32) u8 {
        return @floatToInt(u8, std.math.clamp(channel * 255, 0, 255));
    }

    pub fn encode(self: Encoder, source: *StreamSource, img: ColorImage) !void {
        _ = self;
        var bw = std.io.bufferedWriter(source.writer());
        const writer = bw.writer();
        try writer.print("P6 {} {} 255\n", .{ img.width, img.height });
        for (img.pixels()) |pixel| {
            try writer.writeIntLittle(u8, convertChannel(pixel[0]));
            try writer.writeIntLittle(u8, convertChannel(pixel[1]));
            try writer.writeIntLittle(u8, convertChannel(pixel[2]));
        }
        try bw.flush();
    }
};

pub fn encoder() Encoder {
    return .{};
}
