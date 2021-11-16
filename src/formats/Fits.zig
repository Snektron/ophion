//! See https://fits.gsfc.nasa.gov/standard30/fits_standard30aa.pdf
//! This file implements a stream-based parser for Fits. One the data is read
//! for a particular HDU, it cannot be read again.
const Fits = @This();

const std = @import("std");
const StreamSource = std.io.StreamSource;
const Reader = StreamSource.Reader;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.fits);

/// A general purpose allocator used for temporary allocations. Note that
/// this is only used for some small allocations during parsing of headers,
/// and is not used for any large data allocations, for which a custom allocator
/// is accepted instead.
gpa: *Allocator,

/// A reader for the source we are fetching data from. Can be a memory buffer or a file.
reader: Reader,

/// The primary header for the current file.
header: Header,

/// User has already read the data for the current item.
data_read: bool = false,

pub const block_bytes = 2880;

/// A keyword is 80 bytes according to the spec.
pub const keyword_bytes = 80;
pub const keyword_name_max_len = 8;
const value_separator = "= ";

pub const KeywordBuffer = [keyword_bytes]u8;

/// The alignment required for data storage.
pub const data_align = blk: {
    var max_align = 1;
    inline for (@typeInfo(Data).Union.fields) |field| {
        max_align = std.math.max(@alignOf(std.meta.Child(field.field_type)), max_align);
    }
    break :blk max_align;
};

pub const Format = enum(i8) {
    int8 = 8,
    int16 = 16,
    int32 = 32,
    int64 = 64,
    float32 = -32,
    float64 = -64,

    fn bitWidth(self: Format) u8 {
        return std.math.absCast(@enumToInt(self));
    }

    fn byteWidth(self: Format) u8 {
        return self.bitWidth() / 8;
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
    pub fn free(data: Data, allocator: *Allocator) void {
        allocator.free(data.storage());
    }
};

pub const Extension = enum {
    IMAGE,
    TABLE,
    BINTABLE,
    IUEIMAGE,
    A3DTABLE,
    FOREIGN,
    DUMP,
};

pub const HeaderExtra = union(enum) {
    primary: struct { is_simple: bool },
    extension: struct { extension: Extension },
};

pub const Header = struct {
    format: Format,
    shape: std.ArrayListUnmanaged(u64),
    extra: HeaderExtra,

    /// Return the total number of elements in the data in this HDU.
    pub fn size(self: Header) u64 {
        var z: usize = 1;
        for (self.shape.items) |axis| {
            z *= axis;
        }
        return z;
    }

    /// Return the number of *bytes* required to store the data in this HDU.
    pub fn dataSize(self: Header) u64 {
        return self.size() * self.format.byteWidth();
    }
};

pub const FormatError = error {
    CorruptKeyword,
    IllegalKeywordBytes,
    InvalidKeywordName,
    InvalidKeywordType,
    InvalidValue,
    OutOfRangeInt,
    InvalidFormat,
    InvalidKeyword,
    InvalidAxes,
    UnexpectedDataEnd,
    InvalidExtension,
};

pub fn read(gpa: *Allocator, source: *StreamSource) !Fits {
    var reader = source.reader();
    var self = Fits{
        .gpa = gpa,
        .reader = reader,
        .header = undefined,
    };

    self.header.shape = .{};
    try self.readHeader(.primary);
    return self;
}

pub fn deinit(self: *Fits) void {
    self.header.shape.deinit(self.gpa);
    self.* = undefined;
}

/// Attempt to advance to the next HDU. Returns false if there is no none.
pub fn readNextHeader(self: *Fits) !bool {
    if (!self.data_read) {
        // User didn't read data for this block, so skip over it to find the next HDU.
        // TODO: Can merge below calls, we are currently at a block boundary.
        // try self.reader.skipBytes(self.header.dataSize(), .{});
        // try self.seekNextBlock();
        const skip_size = alignToNextBlock(self.header.dataSize());
        // We're just going to assume this file is less than an exabyte.
        try self.reader.context.seekBy(@intCast(i64, skip_size));
    }

    // TODO: Maybe there is a better method?
    if ((try self.reader.context.getEndPos()) == (try self.reader.context.getPos())) {
        return false;
    }

    try self.readHeader(.extension);
    return true;
}

/// Read the data associated to the current header.
/// Asserts that the supplied storage buffer is the exact required size.
/// Note: This function can only be called once for the current header
pub fn readData(self: *Fits, storage: []align(data_align) u8) !Data {
    const data_size = self.header.dataSize();
    std.debug.assert(data_size == storage.len);

    // First, read the data into the buffer raw, and then flip the endianness if required only after.
    if ((try self.reader.readAll(storage)) != data_size) {
        return error.UnexpectedDataEnd;
    }
    try self.seekNextBlock();

    self.data_read = true;

    inline for (@typeInfo(Data).Union.fields) |field| {
        if (self.header.format == @field(Format, field.name)) {
            const T = std.meta.Child(field.field_type);
            const IntType = std.meta.Int(.unsigned, @bitSizeOf(T));
            if (@sizeOf(IntType) > 1) {
                for (std.mem.bytesAsSlice(IntType, storage)) |*x| {
                    x.* = @byteSwap(IntType, x.*);
                }
            }

            return @unionInit(Data, field.name, std.mem.bytesAsSlice(T, storage));
        }
    }

    unreachable;
}

pub fn readDataAlloc(self: *Fits, allocator: *Allocator) !Data {
    var storage = try allocator.allocWithOptions(u8, self.header.dataSize(), data_align, null);
    errdefer allocator.free(storage);
    return try self.readData(storage);
}

fn alignToNextBlock(offset: anytype) @TypeOf(offset) {
    if (offset % block_bytes == 0) {
        return offset;
    }

    return offset - offset % block_bytes + block_bytes;
}

fn seekNextBlock(self: *Fits) !void {
    const pos = try self.reader.context.getPos();
    try self.reader.context.seekTo(alignToNextBlock(pos));
}

fn readHeader(self: *Fits, kind: enum {primary, extension}) !void {
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

    var it = KeywordIterator{.reader = &self.reader};

    switch (kind) {
        .primary => {
            const is_simple = try it.expectAs("SIMPLE", .logical);
            if (!is_simple) {
                log.warn("File does not report itself as SIMPLE", .{});
            }

            self.header.extra = .{.primary = .{.is_simple = is_simple}};
        },
        .extension => {
            const name = try it.expectAs("XTENSION", .string);
            const extension = std.meta.stringToEnum(Extension, name) orelse return error.InvalidExtension;
            self.header.extra = .{.extension = .{.extension = extension}};
        },
    }

    self.header.format = std.meta.intToEnum(Format, try it.expectAs("BITPIX", .int)) catch {
        return error.InvalidFormat;
    };

    const naxis = try it.expectAs("NAXIS", .int);
    if (naxis < 1 or naxis >= 999) {
        log.err("File reports {} axes", .{naxis});
        return error.InvalidAxes;
    }

    try self.header.shape.resize(self.gpa, @intCast(usize, naxis));

    for (self.header.shape.items) |*axis, i| {
        const kw = (try it.next()) orelse {
            log.err("Missing axis {}", .{i + 1});
            return error.InvalidAxes;
        };

        if (!std.mem.startsWith(u8, kw.name, "NAXIS")) {
            log.err("Expected keyword NAXIS{}, found keyword {s}", .{i + 1, kw.name});
            return error.InvalidAxes;
        }

        const num = std.fmt.parseInt(u64, kw.name["NAXIS".len..], 10) catch return error.InvalidAxes;
        if (num != i + 1) {
            log.err("Expected axis {}, found axis {}", .{i + 1, num});
            return error.InvalidAxes;
        }

        const val = try kw.value.cast(.int);
        axis.* = std.math.cast(usize, val) catch {
            log.err("Invalid axis dimension {}", .{val});
            return error.InvalidAxes;
        };
    }

    // Ignore other keywords for now.

    try self.seekNextBlock();
}

const KeywordIterator = struct {
    reader: *Reader,
    buf: KeywordBuffer = undefined,

    fn next(self: *KeywordIterator) !?Keyword {
        const r = try self.reader.readAll(&self.buf);
        if (r != keyword_bytes) {
            return error.CorruptKeyword;
        }

        const kw = try parseKeyword(&self.buf);
        if (std.mem.eql(u8, kw.name, "END")) {
            return null;
        }

        return kw;
    }

    fn expect(self: *KeywordIterator, keyword_name: []const u8) !Value {
        const kw = (try self.next()) orelse {
            log.err("Missing mandatory header {s}", .{keyword_name});
            return error.InvalidKeyword;
        };
        if (!std.mem.eql(u8, kw.name, keyword_name)) {
            log.err("Expected keyword {s}, found {s}", .{keyword_name, kw.name});
            return error.InvalidKeyword;
        }
        return kw.value;
    }

    fn expectAs(
        self: *KeywordIterator,
        keyword_name: []const u8,
        comptime tag: std.meta.Tag(Value),
    ) !std.meta.TagPayload(Value, tag) {
        const value = try self.expect(keyword_name);
        return try value.cast(tag);
    }
};

const Keyword = struct {
    name: []const u8,
    value: Value,
    comment: ?[]const u8,

    fn dup(self: Keyword, allocator: *Allocator) !Keyword {
        const value_offset = self.name.len;
        const comment_offset = value_offset + if (self.value == .string) self.value.string.len else 0;
        const len = comment_offset + if (self.comment) |comment| comment.len else 0;

        const buf = try allocator.alloc(u8, len);

        const kw = Keyword{
            .name = buf[0..value_offset],
            .value = if (self.value == .string) .{.string = buf[value_offset..comment_offset]} else self.value,
            .comment = if (self.comment != null) buf[comment_offset..] else null,
        };

        std.mem.copy(u8, kw.name, self.name);
        if (kw.value == .string) std.mem.copy(u8, kw.string, self.value.string);
        if (kw.comment) |comment| std.mem.copy(u8, comment, self.comment.?);

        return kw;
    }

    /// Note: Only required for a keyword allocated by dup().
    fn deinit(self: *Keyword, allocator: *Allocator) void {
        const value_len = if (self.value == .string) self.value.string.len else 0;
        const comment_len = if (self.comment) |comment| comment.len else 0;
        allocator.free(self.name.ptr[self.name.len + value_len + comment_len]);
        self.* = undefined;
    }
};

const Value = union(enum) {
    none,
    // Note: Note quotes, unescaped
    string: []const u8,
    logical: bool,
    int: i64,
    float: f64,
    complex_int: std.math.Complex(i64),
    complex_float: std.math.Complex(f64),

    fn cast(self: Value, comptime tag: std.meta.Tag(Value)) !std.meta.TagPayload(Value, tag) {
        if (self != tag) {
            return error.InvalidKeywordType;
        }

        return @field(self, @tagName(tag));
    }
};

fn parseKeyword(kw: *KeywordBuffer) !Keyword {
    for (kw) |c| {
        switch (c) {
            32...126 => {},
            else => return error.IllegalKeywordBytes,
        }
    }

    var i: usize = 0;
    while (i < keyword_name_max_len) : (i += 1) {
        switch (kw[i]) {
            'A'...'Z' => {},
            '0'...'9', '-', '_' => if (i == 0) return error.InvalidKeywordName,
            ' ' => break,
            else => return error.InvalidKeywordName,
        }
    }

    const name = kw[0..i];

    while (i < keyword_name_max_len) : (i += 1) {
        switch (kw[i]) {
            ' ' => {},
            else => return error.InvalidKeywordName,
        }
    }

    if (!std.mem.startsWith(u8, kw[i..], value_separator)) {
        // No value, but may still contain some text. Just put this under 'comment'.
        return Keyword{
            .name = name,
            .value = .none,
            .comment = kw[i..]
        };
    }

    // Now follows a value and optionally a comment.
    i = keyword_name_max_len + value_separator.len;

    // Skip over any whitespace. Everything will be parsed as free-form value, and we
    // are going to assume that any justification is done with spaces.
    while (i < keyword_bytes) : (i += 1) {
        if (kw[i] != ' ') break;
    } else {
        // No value, no comment
        return Keyword {
            .name = name,
            .value = .none,
            .comment = null,
        };
    }

    const value = switch (kw[i]) {
        ' ' => unreachable,
        '/' => Value.none,
        'T', 'F' => blk: {
            defer i += 1;
            break :blk .{.logical = kw[i] == 'T'};
        },
        '\'' => try parseString(kw, &i),
        '(' => try parseComplex(kw, &i),
        '+', '-', '0'...'9' => try parseNumber(kw, &i),
        else => return error.InvalidValue,
    };

    skipSpaces(kw, &i);
    const comment = if (i != keyword_bytes and kw[i] == '/') kw[i + 1..] else null;
    return Keyword{
        .name = name,
        .value = value,
        .comment = comment,
    };
}

fn parseComplex(kw: *KeywordBuffer, i: *usize) !Value {
    var j = i.*;
    std.debug.assert(kw[j] == '(');
    j += 1;

    skipSpaces(kw, &j);
    const a = try parseNumber(kw, &j);
    skipSpaces(kw, &j);
    if (j == keyword_bytes or kw[j] != ',') {
        return error.InvalidValue;
    }

    j += 1;
    skipSpaces(kw, &j);
    const b = try parseNumber(kw, &j);
    skipSpaces(kw, &j);
    if (j == keyword_bytes or kw[j] != ')') {
        return error.InvalidValue;
    }
    i.* = j + 1;

    if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
        return error.InvalidValue;
    }

    return switch (a) {
        .int => Value{.complex_int = std.math.Complex(i64).init(a.int, b.int)},
        .float => Value{.complex_float = std.math.Complex(f64).init(a.float, b.float)},
        else => unreachable,
    };
}

fn skipSpaces(kw: *KeywordBuffer, i: *usize) void {
    var j = i.*;
    while (j < keyword_bytes) : (j += 1) {
        if (kw[j] != ' ') break;
    }

    i.* = j;
}

fn parseNumber(kw: *KeywordBuffer, i: *usize) !Value {
    const start = i.*;

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
    var j = start;
    while (j < keyword_bytes) : (j += 1) {
        const c = kw[j];
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
                    maybe_exp_index = j;
                    state = .exp;
                },
                else => break,
            },
            .fraction_digits => switch (c) {
                '0'...'9' => {},
                'E', 'D' => {
                    maybe_exp_index = j;
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

    const text = kw[start..j];
    i.* = j;

    switch (state) {
        .start, .sign, .exp, .exp_sign => return error.InvalidValue,
        .int_digits => {
            const val = std.fmt.parseInt(i64, text, 10) catch |err| switch (err) {
                error.InvalidCharacter => unreachable,
                error.Overflow => return error.OutOfRangeInt,
            };
            return Value{.int = val};
        },
        .dot, .fraction_digits, .exp_digits => {
            if (maybe_exp_index) |exp_index| {
                // Cheekily replace the 'D' by an 'E' temporarily so std.fmt.parseFloat can parse it.
                const exp = kw[exp_index];
                defer kw[exp_index] = exp;

                kw[exp_index] = 'E';
                const val = std.fmt.parseFloat(f64, text) catch unreachable;
                return Value{.float = val};
            } else {
                const val = std.fmt.parseFloat(f64, text) catch unreachable;
                return Value{.float = val};
            }
        },
    }
}

fn parseString(kw: *KeywordBuffer, i: *usize) !Value {
    const start = i.*;
    std.debug.assert(kw[start] == '\'');

    var state: enum {
        start,
        text,
        spaces,
        quote,
    } = .start;

    var j = start + 1;
    var write_index = start;
    var last_non_space = write_index;
    while (j < keyword_bytes) : (j += 1) {
        const c = kw[j];
        switch (state) {
            .start => switch (c) {
                '\'' => {
                    state = .quote;
                    continue;
                },
                else => state = .text,
            },
            .text => switch (c) {
                ' ' => {
                    state = .spaces;
                    kw[write_index] = c;
                    write_index += 1;
                },
                '\'' => state = .quote,
                else => {},
            },
            .spaces => switch (c) {
                ' ' => {
                    kw[write_index] = c;
                    write_index += 1;
                },
                '\'' => state = .quote,
                else => state = .text,
            },
            .quote => switch (c) {
                '\'' => state = .text,
                else => break,
            },
        }

        kw[write_index] = c;
        write_index += 1;
        last_non_space = write_index;
    } else {
        return error.UnterminatedString;
    }

    i.* = j;

    return Value{.string = kw[start..last_non_space]};
}

