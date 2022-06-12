//! https://en.wikipedia.org/wiki/Netpbm
const std = @import("std");
const assert = std.debug.assert;
const StreamSource = std.io.StreamSource;
const Image = @import("../Image.zig");
const formats = @import("../formats.zig");

pub const PpmEncoder = struct {
    pub const Options = struct {
        /// Store the image as P6 (RGB) even if there is only one channel.
        force_rgb: bool = false,
    };

    const BufferedWriter = std.io.BufferedWriter(4096, StreamSource.Writer);
    pub const Error = BufferedWriter.Error;
    pub const Encoder = formats.Encoder(PpmEncoder, Error, encode);

    opts: Options,

    fn convertChannel(channel: f32) u8 {
        return @floatToInt(u8, std.math.clamp(channel * 255, 0, 255));
    }

    pub fn encode(self: PpmEncoder, source: *StreamSource, image: Image) Error!void {
        assert(image.descriptor.components == 1 or image.descriptor.components == 3);

        var bw = BufferedWriter{.unbuffered_writer = source.writer()};
        const writer = bw.writer();

        switch (image.descriptor.components) {
            1 => {
                if (self.opts.force_rgb) {
                    try writer.print("P6 {} {} 255\n", .{ image.descriptor.width, image.descriptor.height });
                    for (image.data()) |channel| {
                        const converted = convertChannel(channel);
                        try writer.writeIntLittle(u8, converted);
                        try writer.writeIntLittle(u8, converted);
                        try writer.writeIntLittle(u8, converted);
                    }
                } else {
                    try writer.print("P5 {} {} 255\n", .{ image.descriptor.width, image.descriptor.height });
                    for (image.data()) |channel| {
                        try writer.writeIntLittle(u8, convertChannel(channel));
                    }
                }
            },
            3 => {
                try writer.print("P6 {} {} 255\n", .{ image.descriptor.width, image.descriptor.height });
                for (image.data()) |channel| {
                    try writer.writeIntLittle(u8, convertChannel(channel));
                }
            },
            else => unreachable,
        }
        try bw.flush();
    }

    pub fn encoder(self: PpmEncoder) Encoder {
        return Encoder{.context = self};
    }
};

pub fn encoder(opts: PpmEncoder.Options) PpmEncoder {
    return .{.opts = opts};
}
