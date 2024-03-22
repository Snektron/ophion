//! See https://fits.gsfc.nasa.gov/standard30/fits_standard30aa.pdf

const std = @import("std");
const StreamSource = std.io.StreamSource;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const log = std.log.scoped(.fits);
const assert = std.debug.assert;
const Image = @import("../Image.zig");
const filters = @import("../filters.zig");
const formats = @import("../formats.zig");

/// Fits files are structures in blocks of 2880 bytes. Each block
/// can be either a header, consisting of a number of keywords, or
/// raw data.
pub const bytes_per_block = 2880;

/// keywords are 80 bytes.
pub const bytes_per_keyword = 80;
/// keyword names are 8 bytes.
pub const bytes_per_keyword_key = 8;

const value_separator = "= ";
/// Value separator, if present, has to be in bytes 9 and 10.
const value_separator_offset = 8;
/// Maximum number of bytes in a string value.
/// Subtract 2 for the two quotes, which we don't store.
const bytes_per_string = bytes_per_keyword - bytes_per_keyword_key - value_separator.len - 2;

pub const KeywordBuffer = [bytes_per_keyword]u8;

/// Minimum alignment for data bytes.
pub const data_align = blk: {
    var max_align = 1;
    for (@typeInfo(Data).Union.fields) |field| {
        max_align = @max(@alignOf(std.meta.Child(field.type)), max_align);
    }
    break :blk max_align;
};

pub const Key = struct {
    pub const HashContext = struct {
        pub fn hash(ctx: HashContext, key: Key) u64 {
            _ = ctx;
            return std.hash.Wyhash.hash(0, key.name());
        }

        pub fn eql(ctx: HashContext, a: Key, b: Key) bool {
            _ = ctx;
            return std.mem.eql(u8, a.name(), b.name());
        }
    };

    key: [bytes_per_keyword_key]u8,

    /// Initialize this key with a particular name.
    /// Asserts that it is in the right format:
    /// - min 1, max 8 characters.
    /// - only consist of [A-Z0-9_-].
    pub fn init(key_name: []const u8) Key {
        assert(isValidName(key_name));
        var result = Key{
            .key = " ".* ** bytes_per_keyword_key,
        };
        @memcpy(result.key[0..key_name.len], key_name);
        return result;
    }

    /// Return only the relevant part of the key.
    pub fn name(self: *const Key) []const u8 {
        return std.mem.sliceTo(&self.key, ' ');
    }

    /// Compare the name against a regular string
    pub fn eql(self: Key, key_name: []const u8) bool {
        return std.mem.eql(u8, self.name(), key_name);
    }

    /// Check if a particular string would be valid as a keyword name.
    pub fn isValidName(key_name: []const u8) bool {
        if (key_name.len == 0 or key_name.len > bytes_per_keyword_key) {
            return false;
        }

        for (key_name) |c| {
            switch (c) {
                'A'...'Z', '0'...'9', '-', '_' => {},
                else => return false,
            }
        }

        return true;
    }

    pub fn format(self: Key, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opts;
        try writer.writeAll(self.name());
    }
};

pub const Value = union(enum) {
    none,
    string: []u8,
    logical: bool,
    int: i64,
    float: f64,
    complex_int: std.math.Complex(i64),
    complex_float: std.math.Complex(f64),

    /// Attempt to unwrap the Value as a particular type. Returns null if not the right type.
    fn cast(self: Value, comptime tag: std.meta.Tag(Value)) ?std.meta.TagPayload(Value, tag) {
        if (self != tag) {
            return null;
        }

        return @field(self, @tagName(tag));
    }

    fn toFloat(self: Value) ?f64 {
        return switch (self) {
            .int => |value| @as(f32, @floatFromInt(value)),
            .float => |value| value,
            else => null,
        };
    }

    pub fn format(self: Value, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opts;
        switch (self) {
            .none => try writer.writeAll("(none)"),
            .string => |value| try writer.writeAll(value),
            .logical => |value| try writer.print("{}", .{value}),
            .int => |value| try writer.print("{}", .{value}),
            .float => |value| try writer.print("{d}", .{value}),
            .complex_int => |value| try writer.print("{}", .{value}),
            .complex_float => |value| try writer.print("{}", .{value}),
        }
    }
};

pub const ValueAndComment = struct {
    value: Value,
    comment: ?[]u8,
};

pub const KeywordMap = std.HashMapUnmanaged(Key, ValueAndComment, Key.HashContext, std.hash_map.default_max_load_percentage);

/// Type of formats that can be present in a FITS file. Value equals the
/// expected value of the BITPIX keyword.
pub const Format = enum(i8) {
    int8 = 8,
    int16 = 16,
    int32 = 32,
    int64 = 64,
    float32 = -32,
    float64 = -64,

    /// Return the number of bits making up an individual element in this format.
    fn bitSize(self: Format) u8 {
        return @abs(@intFromEnum(self));
    }

    /// Return the number of bytes making up an individual data element in this format.
    fn size(self: Format) u8 {
        return @divExact(self.bitSize(), 8);
    }

    fn Type(comptime self: Format) type {
        return switch (self) {
            .int8 => i8,
            .int16 => i16,
            .int32 => i32,
            .int64 => i64,
            .float32 => f32,
            .float64 => f64,
        };
    }
};

pub const Data = union(Format) {
    int8: []i8,
    int16: []i16,
    int32: []i32,
    int64: []i64,
    float32: []f32,
    float64: []f64,

    /// Fetch the underlying storage of this data.
    pub fn storage(data: Data) []u8 {
        return switch (data) {
            .int8 => |x| std.mem.sliceAsBytes(x),
            .int16 => |x| std.mem.sliceAsBytes(x),
            .int32 => |x| std.mem.sliceAsBytes(x),
            .int64 => |x| std.mem.sliceAsBytes(x),
            .float32 => |x| std.mem.sliceAsBytes(x),
            .float64 => |x| std.mem.sliceAsBytes(x),
        };
    }

    /// Utility method to deal with freeing data
    pub fn free(data: Data, allocator: Allocator) void {
        allocator.free(data.storage());
    }
};

/// Known extensions, in the exact casing used in the value of the XTENSION keyword (minus padding).
pub const Extension = enum {
    IMAGE,
    TABLE,
    BINTABLE,
    IUEIMAGE,
    A3DTABLE,
    FOREIGN,
    DUMP,
};

/// A descriptor for a Header- and Data-Unit.
pub const Hdu = struct {
    pub const Kind = union(enum) {
        primary,
        extension: Extension,
    };

    /// The type of HDU. Can be primary or (a specific) extension.
    kind: Kind,
    /// The data format.
    format: Format,
    /// The data shape, as decoded from the NAXIS fields, in order.
    shape: []usize,
    /// byte offset at which the data of this file starts.
    /// The block is present only if dataBlocks() > 0.
    data_offset: usize,
    /// Additional keywords appearing in this HDU.
    /// Memory is managed externally.
    /// Padding should be done with spaces, and keys are left-justified as in the file itself.
    /// Note: Does not and should not (when encoding) contain the following keywords,
    /// as they are already present in other parts of this structure:
    /// NAXIS
    /// NAXISn
    /// BITPIX
    /// SIMPLE and XTENSION
    keywords: KeywordMap,

    /// Return the total number of elements in the data associated to this HDU,
    /// in terms of the type of data present (see Format).
    pub fn numElements(self: Hdu) usize {
        if (self.shape.len == 0) {
            return 0;
        }
        var total: usize = 1;
        for (self.shape) |axis| {
            total *= axis;
        }
        return total;
    }

    /// Return the number of data bytes associated to this HDU.
    /// Note: This is the number of *actual* data bytes, without including padding.
    pub fn dataSize(self: Hdu) usize {
        return self.numElements() * self.format.size();
    }

    /// Return the number of data blocks that are associated with this HDU.
    pub fn dataBlocks(self: Hdu) usize {
        return std.math.divCeil(usize, self.dataSize(), bytes_per_block) catch unreachable;
    }

    fn dump(self: Hdu, writer: anytype) !void {
        try writer.writeAll("{\n");
        switch (self.kind) {
            .primary => try writer.writeAll("    kind = primary,\n"),
            .extension => |ext| try writer.print("    kind = extension {s},\n", .{@tagName(ext)}),
        }
        try writer.print("    format = {s},\n    shape = ", .{@tagName(self.format)});
        for (self.shape, 0..) |axis, i| {
            if (i != 0) {
                try writer.writeByte('x');
            }
            try writer.print("{}", .{axis});
        }
        try writer.print(",\n    elements = {},\n    data bytes = {:.2},\n    data offset = {:.2},\n    blocks = {},\n", .{
            self.numElements(),
            std.fmt.fmtIntSizeBin(self.dataSize()),
            std.fmt.fmtIntSizeBin(self.data_offset),
            self.dataBlocks(),
        });
        var it = self.keywords.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.comment) |comment| {
                try writer.print("    {s: <8} = {} / {s},\n", .{ entry.key_ptr.name(), entry.value_ptr.value, comment });
            } else {
                try writer.print("    {s: <8} = {},\n", .{ entry.key_ptr.name(), entry.value_ptr.value });
            }
        }
        try writer.writeAll("  },\n");
    }
};

/// Represents a readable, immutable FITS handle.
/// When reading a FITS file, the data is not loaded into memory until queried specifically.
pub const Fits = struct {
    /// Used for various allocations related to this fits file.
    a: Allocator,
    /// Arena allocator used for allocations that have a predetermined max size.
    arena: ArenaAllocator.State,
    /// The backing storage for this FITS file. It can be either in memory
    /// or a file handle.
    source: *StreamSource,
    /// The list of HDUs present in this file. First index should be primary,
    /// others extensions.
    hdus: []Hdu,

    pub fn deinit(self: Fits) void {
        self.arena.promote(self.a).deinit();
        for (self.hdus) |*hdu| {
            hdu.keywords.deinit(self.a);
        }
        self.a.free(self.hdus);
    }

    pub fn dump(self: Fits, writer: anytype) !void {
        try writer.writeAll("{\n");
        for (self.hdus, 0..) |hdu, i| {
            try writer.print("  hdu[{}] = ", .{i});
            try hdu.dump(writer);
        }
        try writer.writeAll("}\n");
    }

    fn byteSwapSlice(comptime width: usize, buffer: []align(data_align) u8) void {
        const IntType = std.meta.Int(.unsigned, width);
        for (std.mem.bytesAsSlice(IntType, buffer)) |*x| {
            x.* = @byteSwap(x.*);
        }
    }

    /// Read raw data fro mthe HDU into the buffer, which must be large enough to hold all the data.
    /// Endianness is fixed to little, if required.
    pub fn readData(self: Fits, hdu: *const Hdu, storage: []align(data_align) u8) !Data {
        // Ensure that the pointer is one of ours.
        assert(@intFromPtr(self.hdus.ptr) <= @intFromPtr(hdu) and @intFromPtr(hdu) < @intFromPtr(self.hdus.ptr + self.hdus.len));
        try self.source.seekTo(hdu.data_offset);

        // First read all the data into the buffer raw, and then swap them after if required.
        var reader = self.source.reader();
        const data_size = hdu.dataSize();
        assert((try reader.readAll(storage[0..data_size])) == data_size); // Data present should be verified by the parsing part.

        const buffer = storage[0..data_size];

        // Flip endianness
        switch (hdu.format) {
            .int8 => {},
            .int16 => byteSwapSlice(16, buffer),
            .int32, .float32 => byteSwapSlice(32, buffer),
            .int64, .float64 => byteSwapSlice(64, buffer),
        }

        // Written out because stage 2 cannot cope with an inline for loop here...
        return switch (hdu.format) {
            .int8 => .{ .int8 = std.mem.bytesAsSlice(i8, buffer) },
            .int16 => .{ .int16 = std.mem.bytesAsSlice(i16, buffer) },
            .int32 => .{ .int32 = std.mem.bytesAsSlice(i32, buffer) },
            .int64 => .{ .int64 = std.mem.bytesAsSlice(i64, buffer) },
            .float32 => .{ .float32 = std.mem.bytesAsSlice(f32, buffer) },
            .float64 => .{ .float64 = std.mem.bytesAsSlice(f64, buffer) },
        };
    }

    pub fn readDataAlloc(self: Fits, hdu: *const Hdu, a: Allocator) !Data {
        const storage = try a.allocWithOptions(u8, hdu.dataSize(), data_align, null);
        errdefer a.free(storage);
        return try self.readData(hdu, storage);
    }
};

pub fn read(a: Allocator, source: *StreamSource) !Fits {
    var hdus = std.ArrayList(Hdu).init(a);
    defer hdus.deinit();

    errdefer {
        for (hdus.items) |*hdu| {
            hdu.keywords.deinit(a);
        }
    }

    const end = try source.getEndPos();

    var arena = ArenaAllocator.init(a);
    errdefer arena.deinit();

    try hdus.append(try readHdu(a, arena.allocator(), source, .primary));

    while ((try source.getPos()) < end) {
        try hdus.append(try readHdu(a, arena.allocator(), source, .extension));
    }

    return Fits{
        .a = a,
        .arena = arena.state,
        .source = source,
        .hdus = try hdus.toOwnedSlice(),
    };
}

fn readHdu(gpa: Allocator, arena: Allocator, source: *StreamSource, kind: std.meta.Tag(Hdu.Kind)) !Hdu {
    // Primary header constists of, in order:
    // SIMPLE = T
    // BITPIX
    // NAXIS
    // NAXISn
    // ...
    // END
    // Extension header consists of, in order:
    // XTENSION
    // BITPIX
    // NAXIS
    // NAXISn
    // PCOUNT
    // GCOUNT
    // ...
    // END

    const header_start = try source.getPos();
    var hdu = Hdu{
        .kind = undefined,
        .format = undefined,
        .shape = undefined,
        .data_offset = undefined,
        .keywords = KeywordMap{},
    };
    errdefer hdu.keywords.deinit(gpa);

    var reader = source.reader();
    var it = KeywordIterator{ .reader = &reader };

    switch (kind) {
        .primary => {
            const is_simple = try it.expectType("SIMPLE", .logical);
            if (!is_simple) {
                log.warn("File does not report itself as SIMPLE", .{});
            }

            hdu.kind = .primary;
        },
        .extension => {
            const name = try it.expectType("XTENSION", .string);
            const extension = std.meta.stringToEnum(Extension, name) orelse return error.InvalidExtension;
            hdu.kind = .{ .extension = extension };
        },
    }

    hdu.format = std.meta.intToEnum(Format, try it.expectType("BITPIX", .int)) catch {
        return error.InvalidFormat;
    };

    const naxis = try it.expectType("NAXIS", .int);
    if (naxis < 0 or naxis >= 999) {
        log.err("File reports {} axes", .{naxis});
        return error.InvalidAxes;
    }

    hdu.shape = try arena.alloc(usize, @as(usize, @intCast(naxis)));

    for (hdu.shape, 0..) |*axis, i| {
        const kw = (try it.next()) orelse {
            log.err("Missing axis {}", .{i + 1});
            return error.InvalidAxes;
        };

        if (!std.mem.startsWith(u8, kw.key.name(), "NAXIS")) {
            log.err("Expected keyword NAXIS{}, found keyword {s}", .{ i + 1, kw.key });
            return error.InvalidAxes;
        }

        const num = std.fmt.parseInt(u64, kw.key.name()["NAXIS".len..], 10) catch return error.InvalidAxes;
        if (num != i + 1) {
            log.err("Expected axis {}, found axis {}", .{ i + 1, num });
            return error.InvalidAxes;
        }

        const val = kw.value.cast(.int) orelse return error.InvalidKeywordType;
        axis.* = std.math.cast(usize, val) orelse {
            log.err("Invalid axis dimension {}", .{val});
            return error.InvalidAxes;
        };
    }

    while (try it.next()) |kw| {
        const value = switch (kw.value) {
            .string => |str| blk: {
                break :blk Value{ .string = try arena.dupe(u8, str) };
            },
            else => |value| value,
        };
        const comment = if (kw.comment) |text| try arena.dupe(u8, std.mem.trim(u8, text, " ")) else null;
        try hdu.keywords.put(gpa, kw.key, .{
            .value = value,
            .comment = comment,
        });
    }

    const header_end = try source.getPos();
    const header_blocks = std.math.divCeil(usize, header_end - header_start, bytes_per_block) catch unreachable;
    const data_start = header_blocks * bytes_per_block + header_start;
    hdu.data_offset = data_start;

    try source.seekTo(data_start + hdu.dataBlocks() * bytes_per_block);

    return hdu;
}

const KeywordIterator = struct {
    reader: *StreamSource.Reader,
    buf: KeywordBuffer = undefined,

    fn next(self: *KeywordIterator) !?Keyword {
        const r = try self.reader.readAll(&self.buf);
        if (r != bytes_per_keyword) {
            return error.CorruptKeyword;
        }

        const kw = try Keyword.read(&self.buf);
        if (kw.key.eql("END")) {
            return null;
        }

        return kw;
    }

    fn expect(self: *KeywordIterator, key_name: []const u8) !Value {
        const kw = (try self.next()) orelse {
            log.err("Missing mandatory keyword {s}", .{key_name});
            return error.InvalidKeyword;
        };
        if (!kw.key.eql(key_name)) {
            log.err("Expected keyword {s}, found {s}", .{ key_name, kw.key });
            return error.InvalidKeyword;
        }
        return kw.value;
    }

    fn expectType(
        self: *KeywordIterator,
        keyword_name: []const u8,
        comptime tag: std.meta.Tag(Value),
    ) !std.meta.TagPayload(Value, tag) {
        const value = try self.expect(keyword_name);
        return value.cast(tag) orelse error.InvalidKeywordType;
    }
};

const Keyword = struct {
    key: Key,
    value: Value,
    comment: ?[]const u8,

    fn read(kw: *KeywordBuffer) !Keyword {
        for (kw) |c| {
            switch (c) {
                32...126 => {},
                else => return error.IllegalKeywordBytes,
            }
        }

        const lhs = kw[0..bytes_per_keyword_key];
        const name = std.mem.sliceTo(lhs, ' ');

        if (!Key.isValidName(name)) {
            return error.InvalidKeywordName;
        }

        for (lhs[name.len..]) |c| {
            if (c != ' ') {
                return error.InvalidKeywordName; // Invalid justification characters
            }
        }

        const rhs = kw[value_separator_offset..];
        if (!std.mem.startsWith(u8, rhs, value_separator)) {
            // No value, but may still contain some text. Just put this under 'comment'.
            return Keyword{
                .key = Key.init(name),
                .value = .none,
                .comment = rhs,
            };
        }

        // Now follows a value and optionally a comment.
        var i = bytes_per_keyword_key + value_separator.len;

        // Skip over any whitespace. Everything will be parsed as free-form value, and we
        // are going to assume that any justification is done with spaces.
        while (i < bytes_per_keyword) : (i += 1) {
            if (kw[i] != ' ') break;
        } else {
            // No value, no comment
            return Keyword{
                .key = Key.init(name),
                .value = .none,
                .comment = null,
            };
        }

        var value_parser = ValueParser{ .kw = kw, .index = i };
        const value = switch (kw[i]) {
            ' ' => unreachable,
            '/' => Value.none,
            'T', 'F' => blk: {
                defer i += 1;
                break :blk Value{ .logical = kw[i] == 'T' };
            },
            '\'' => try value_parser.readString(),
            '(' => try value_parser.readComplex(),
            '+', '-', '0'...'9' => try value_parser.readNumber(),
            else => return error.InvalidValue,
        };

        value_parser.skipSpaces();
        i = value_parser.index;
        const comment = if (i != bytes_per_keyword and kw[i] == '/') kw[i + 1 ..] else null;
        return Keyword{
            .key = Key.init(name),
            .value = value,
            .comment = comment,
        };
    }
};

const ValueParser = struct {
    kw: *KeywordBuffer,
    index: usize,

    fn skipSpaces(self: *ValueParser) void {
        while (self.index < bytes_per_keyword) : (self.index += 1) {
            if (self.kw[self.index] != ' ') break;
        }
    }

    fn readComplex(self: *ValueParser) !Value {
        assert(self.kw[self.index] == '(');
        self.index += 1;
        self.skipSpaces();

        const a = try self.readNumber();
        self.skipSpaces();
        if (self.index == bytes_per_keyword or self.kw[self.index] != ',') {
            return error.InvalidValue;
        }

        self.index += 1;
        self.skipSpaces();
        const b = try self.readNumber();
        self.skipSpaces();
        if (self.index == bytes_per_keyword or self.kw[self.index] != ')') {
            return error.InvalidValue;
        }
        self.index += 1;

        if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
            return error.InvalidValue;
        }

        return switch (a) {
            .int => Value{ .complex_int = std.math.Complex(i64).init(a.int, b.int) },
            .float => Value{ .complex_float = std.math.Complex(f64).init(a.float, b.float) },
            else => unreachable,
        };
    }

    fn readNumber(self: *ValueParser) !Value {
        const start = self.index;

        var state: enum {
            start,
            sign,
            dot,
            int_digits,
            fraction_digits,
            exp,
            exp_sign,
            exp_digits,
        } = .start;

        var maybe_exp_index: ?usize = null;
        while (self.index < bytes_per_keyword) : (self.index += 1) {
            const c = self.kw[self.index];
            switch (state) {
                .start => switch (c) {
                    '+', '-' => state = .sign,
                    '0'...'9' => state = .int_digits,
                    else => return error.InvalidValue,
                },
                .sign => switch (c) {
                    '.' => state = .dot,
                    '0'...'9' => state = .int_digits,
                    else => return error.InvalidValue,
                },
                .dot => switch (c) {
                    '0'...'9' => state = .fraction_digits,
                    else => break,
                },
                .int_digits => switch (c) {
                    '0'...'9' => {},
                    '.' => state = .fraction_digits,
                    'E', 'D' => {
                        maybe_exp_index = self.index;
                        state = .exp;
                    },
                    else => break,
                },
                .fraction_digits => switch (c) {
                    '0'...'9' => {},
                    'E', 'D' => {
                        maybe_exp_index = self.index;
                        state = .exp;
                    },
                    else => break,
                },
                .exp => switch (c) {
                    '+', '-' => state = .exp_sign,
                    '0'...'9' => state = .exp_digits,
                    else => return error.InvalidValue,
                },
                .exp_sign, .exp_digits => switch (c) {
                    '0'...'9' => state = .exp_digits,
                    else => break,
                },
            }
        }

        const text = self.kw[start..self.index];

        switch (state) {
            .start, .sign, .exp, .exp_sign => return error.InvalidValue,
            .int_digits => {
                const val = std.fmt.parseInt(i64, text, 10) catch |err| switch (err) {
                    error.InvalidCharacter => unreachable,
                    error.Overflow => return error.OutOfRangeInt,
                };
                return Value{ .int = val };
            },
            .dot, .fraction_digits, .exp_digits => {
                if (maybe_exp_index) |exp_index| {
                    // Cheekily replace the 'D' by an 'E' temporarily so std.fmt.parseFloat can parse it.
                    const exp = self.kw[exp_index];
                    defer self.kw[exp_index] = exp;

                    self.kw[exp_index] = 'E';
                    const val = std.fmt.parseFloat(f64, text) catch unreachable;
                    return Value{ .float = val };
                } else {
                    const val = std.fmt.parseFloat(f64, text) catch unreachable;
                    return Value{ .float = val };
                }
            },
        }
    }

    fn readString(self: *ValueParser) !Value {
        const start = self.index;
        assert(self.kw[start] == '\'');

        var state: enum {
            text,
            spaces,
            quote,
        } = .text;

        self.index += 1;
        var write_index = start;
        var end = write_index;
        while (self.index < bytes_per_keyword) : (self.index += 1) {
            const c = self.kw[self.index];

            switch (state) {
                .text => switch (c) {
                    '\'' => state = .quote,
                    ' ' => {
                        self.kw[write_index] = c;
                        write_index += 1;
                        state = .spaces;
                    },
                    else => {
                        self.kw[write_index] = c;
                        write_index += 1;
                        end = write_index;
                    },
                },
                .spaces => switch (c) {
                    ' ' => {
                        self.kw[write_index] = c;
                        write_index += 1;
                    },
                    '\'' => state = .quote,
                    else => {
                        self.kw[write_index] = c;
                        write_index += 1;
                        end = write_index;
                        state = .text;
                    },
                },
                .quote => switch (c) {
                    '\'' => {
                        self.kw[write_index] = c;
                        write_index += 1;
                        end = write_index;
                        state = .text;
                    },
                    else => break,
                },
            }
        } else {
            if (state != .quote)
                return error.UnterminatedString;
        }

        return Value{ .string = self.kw[start..end] };
    }
};

pub const FitsDecoder = struct {
    pub const Error = StreamSource.ReadError || StreamSource.GetSeekPosError || error{ InvalidFitsImage, OutOfMemory };
    pub const Decoder = formats.Decoder(*FitsDecoder, Error, decode);

    /// Allocator to perform temporary allocations with,
    /// or allocations that can potentially be cached.
    a: Allocator,
    /// Pixel cache that can be shared over decodings.
    pixel_cache: std.ArrayListAlignedUnmanaged(u8, data_align) = .{},

    pub fn deinit(self: *FitsDecoder) void {
        self.pixel_cache.deinit(self.a);
        self.* = undefined;
    }

    pub fn decode(self: *FitsDecoder, image: *Image.Managed, source: *StreamSource) Error!void {
        const fits = read(self.a, source) catch |err| switch (err) {
            error.InvalidAxes,
            error.InvalidFormat,
            error.InvalidExtension,
            error.InvalidKeywordType,
            error.InvalidKeyword,
            error.InvalidKeywordName,
            error.IllegalKeywordBytes,
            error.OutOfRangeInt,
            error.InvalidValue,
            error.UnterminatedString,
            error.CorruptKeyword,
            => return error.InvalidFitsImage,
            error.OutOfMemory => return error.OutOfMemory,
            else => |others| return others,
        };
        defer fits.deinit();
        //  Handle the following cases:
        // - 3d data where the innermost dimension is 3 (for rgb)
        // - 2d data with no bayer matrix info (read as grayscale)
        // - 2d data with bayer matrix info (decode bayer matrix into rgb)
        const hdu = &fits.hdus[0];

        switch (hdu.shape.len) {
            2 => if (hdu.keywords.get(Key.init("BAYERPAT"))) |bayerpat| {
                return try self.decode2DBayer(image, fits, bayerpat.value);
            } else {
                log.err("TODO: Implement 2D grayscale data decoding", .{});
                unreachable;
            },
            3 => if (hdu.shape[2] == 3) {
                return try self.decode3DRGB(image, fits);
            } else {
                log.err("TODO: Implement 3D data decoding for non-rgb", .{});
                unreachable;
            },
            else => {
                log.err("fits image has {} dimensions, expected 2 or 3", .{hdu.shape.len});
                return error.InvalidFitsImage;
            },
        }
    }

    fn decode3DRGB(self: *FitsDecoder, dst: *Image.Managed, fits: Fits) !void {
        const hdu = &fits.hdus[0];
        try self.pixel_cache.resize(self.a, hdu.dataSize());
        const pixels = try fits.readData(hdu, self.pixel_cache.items);

        try dst.realloc(.{
            .width = hdu.shape[0],
            .height = hdu.shape[1],
            .components = 3,
        });

        switch (pixels) {
            .int8 => |src| {
                for (0..hdu.shape[0]) |x| {
                    for (0..hdu.shape[1]) |y| {
                        for (0..3) |c| {
                            // The channels is in the outermost array in the fits image, so we have to reshape here.
                            const dst_offset = (y * hdu.shape[0] + x) * 3 + c;
                            const src_offset = (c * hdu.shape[1] + y) * hdu.shape[0] + x;
                            // TODO: Properly apply DATAMIN/DATAMAX/BSCALE/BZERO or something...
                            dst.pixels[dst_offset] = @as(f32, @floatFromInt(@as(u8, @bitCast(src[src_offset])))) / 255;
                        }
                    }
                }
            },
            else => unreachable, // TODO
        }
    }

    fn decode2DBayer(self: *FitsDecoder, dst: *Image.Managed, fits: Fits, pat_value: Value) !void {
        // _ = self;
        // _ = dst;
        // _ = fits;
        // _ = pat_value;
        const pat = std.mem.trim(u8, pat_value.cast(.string) orelse return error.InvalidFitsImage, " ");
        const matrix = if (std.mem.eql(u8, pat, "RGGB"))
            filters.bayer_decoder.BayerMatrix.rg_gb
        else {
            log.err("Unknown bayer matrix {s}", .{pat});
            return error.InvalidFitsImage;
        };
        const hdu = &fits.hdus[0];

        const bscale: f32 = blk: {
            if (hdu.keywords.get(Key.init("BSCALE"))) |bscale_value| {
                const value = bscale_value.value.toFloat() orelse {
                    log.warn("BSCALE {} not convertable to float, falling back to 1", .{bscale_value.value});
                    break :blk 1;
                };
                break :blk @as(f32, @floatCast(value));
            }
            break :blk 1;
        };

        const bzero: f32 = blk: {
            if (hdu.keywords.get(Key.init("BZERO"))) |bzero_value| {
                const value = bzero_value.value.toFloat() orelse {
                    log.warn("BZERO {} not convertable to float, falling back to 0", .{bzero_value.value});
                    break :blk 0;
                };
                break :blk @as(f32, @floatCast(value));
            }
            break :blk 1;
        };

        // Ensure that we have enough data for both the image data directly as well
        // as the image data converted to floats, so that we can perform the conversion in-place.
        const num_elements = hdu.numElements();
        try self.pixel_cache.resize(self.a, @max(hdu.dataSize(), num_elements * @sizeOf(f32)));
        const pixels = try fits.readData(hdu, self.pixel_cache.items);
        const floating_pixels = std.mem.bytesAsSlice(f32, self.pixel_cache.items);

        // If the data size is larger than a float, we need to iterate from front to back.
        // If the data size is smaller than a float, we need to iterate from back to front.

        switch (pixels) {
            .int8 => |px| {
                var i: usize = num_elements;
                while (i > 0) {
                    i -= 1;
                    floating_pixels[i] = @as(f32, @floatFromInt(px[i])) * bscale + bzero;
                }
            },
            .int16 => |px| {
                var i: usize = num_elements;
                while (i > 0) {
                    i -= 1;
                    floating_pixels[i] = @as(f32, @floatFromInt(px[i])) * bscale + bzero;
                }
            },
            .int32 => |px| for (px, 0..) |x, i| {
                floating_pixels[i] = @as(f32, @floatFromInt(x)) * bscale + bzero;
            },
            .float32 => |px| for (px, 0..) |x, i| {
                floating_pixels[i] = x * bscale + bzero;
            },
            .int64 => |px| for (px, 0..) |x, i| {
                floating_pixels[i] = @as(f32, @floatFromInt(x)) * bscale + bzero;
            },
            .float64 => |px| for (px, 0..) |x, i| {
                floating_pixels[i] = @as(f32, @floatCast(x)) * bscale + bzero;
            },
        }

        const src = Image{
            .descriptor = .{
                .width = hdu.shape[0],
                .height = hdu.shape[1],
                .components = 1,
            },
            .pixels = floating_pixels.ptr,
        };

        try filters.bayer_decoder.apply(dst, src, matrix);
    }

    pub fn decoder(self: *FitsDecoder) Decoder {
        return Decoder{ .context = self };
    }
};

pub fn decoder(a: Allocator) FitsDecoder {
    return .{ .a = a };
}
