const std = @import("std");
const Scanner = @import("scan.zig").Scanner;

/// These are the delimiters that will be used as tokens.
const TokenDelimiter = enum(u8) {
    OpenParen = '(', // 0x28  40
    CloseParen = ')', // 0x29  41
    Plus = '+', // 0x2B
    Equals = '=', // 0x3D  61
    OpenSquare = '[', // 0x5B  91
    CloseSquare = ']', // 0x5D  93
    OpenCurly = '{', // 0x7B  123
    CloseCurly = '}', // 0x7D  125
};

/// These are the delimiters that will NOT be used as tokens.
const NonTokenDelimiter = enum(u8) {
    Tab = '\t', // 0x09  9
    LineFeed = '\n', // 0x0A  10
    CarriageReturn = '\r', // 0x0D  13
    Space = ' ', // 0x20  32
    Quote = '"', // 0x22  34
    Dollar = '$', // 0x24  36
    Percent = '%', // 0x25  37
    Comma = ',', // 0x2C  44
    Dot = '.', // 0x2E  46
    ReverseSolidus = '\\', // 0x5C  92
};

/// A enum that represents all individual delimiters (regardless of their use as actual tokens).
const Delimiter = @Type(blk: {
    const fields = @typeInfo(TokenDelimiter).Enum.fields
        ++ @typeInfo(NonTokenDelimiter).Enum.fields
        ++ &[_]std.builtin.TypeInfo.EnumField{ .{ .name = "None", .value = 0 } };

    break :blk .{
        .Enum = .{
            .layout = .Auto,
            .tag_type = u8,
            .decls = &[_]std.builtin.TypeInfo.Declaration{},
            .fields = fields,
            .is_exhaustive = true,
        },
    };
});

/// Since we need to iterate through the delimiters sometimes, we have this slice of them.
const delimiters = blk: {
    var delims: []const u8 = &[_]u8{};
    inline for (std.meta.fields(Delimiter)) |d| {
        if (d.value > 0) { // ignore the None field
            delims = delims ++ &[_]u8{d.value};
        }
    }
    break :blk delims;
};

/// Special token types (usually a combination of Delimiters)
const SpecialToken = enum(u8) {
    None = 0,
    Newline,
    Comment,
    String,
    RawString,
    MacroKey,
    MacroParamKey,
    MacroAccessor,
};

pub const TokenType = @Type(out: {
    const fields = @typeInfo(SpecialToken).Enum.fields ++ @typeInfo(TokenDelimiter).Enum.fields;
    break :out .{
        .Enum = .{
            .layout = .Auto,
            .tag_type = u8,
            .decls = &[_]std.builtin.TypeInfo.Declaration{},
            .fields = fields,
            .is_exhaustive = true,
        },
    };
});

/// Token - We store only the starting offset and the size instead of slices because we don't want
/// to deal with carrying around pointers and all of the stuff that goes with that.
pub const Token = struct {
    /// The offset into the file where this token begins.
    offset: usize = undefined,

    /// The number of bytes in this token.
    size: usize = 0,

    /// Since the Tokenizer is capable of handling streaming input, it's possible that a token may
    /// span multiple buffers, so we keep track of this. In this situation, it is still the caller's
    /// responsibility to use this information correctly.
    start_buffer: usize = undefined,
    end_buffer: usize = undefined,

    /// The line in the file where this token was discovered. This is based on the number of
    /// newline tokens the Tokenizer has encountered. If the calling code has altered the cursor
    line: usize = undefined,

    /// The type of this token (duh)
    token_type: TokenType = TokenType.None,

    /// Whether this token is a valid ZOMB token.
    is_valid: bool = false,

    // TODO: is_partial: bool = false, // token is valid, but ended at the EOF

    const Self = @This();

    /// Given the original input, return the slice of that input which this token represents.
    pub fn slice(self: Self, buffer_: []const u8) ![]const u8 {
        if (self.start_buffer != self.end_buffer) {
            std.log.warn("Token spans multiple buffers!", .{});
        }
        if (self.offset > buffer_.len) {
            return error.TokenOffsetTooBig;
        }
        if (self.offset + self.size > buffer_.len) {
            return error.TokenSizeTooBig;
        }
        return buffer_[self.offset..self.offset + self.size];
    }
};

/// Parses tokens from the given input buffer.
pub const Tokenizer = struct {
    const Self = @This();

    const State = enum {
        None,
        QuotedString,
        MacroX,
        BareString,
        RawString,
        BareStringOrComment,
    };

    state: State = State.None,
    state_stage: u8 = 0,
    crlf: bool = false,

    /// The input buffer
    buffer: []const u8 = undefined,
    buffer_cursor: usize = 0,
    current_line: usize = 1,
    at_end_of_buffer: bool = false,

    /// This Tokenizer is capable of parsing buffered (or streaming) input, so we keep track of how
    /// many buffers we've parsed.
    buffer_index: usize = 0,

    /// The token currently being discovered
    token: Token = Token{},

    pub fn init(buffer_: []const u8) Self {
        return Self{
            .buffer = buffer_,
        };
    }

    pub fn setBuffer(self: *Self, buffer_: []const u8) void {
        self.buffer = buffer_;
        self.buffer_cursor = 0;
        self.buffer_index += 1;
    }

    fn tokenComplete(self: *Self) void {
        self.state = State.None;
        self.token.is_valid = true;
        self.token.end_buffer = self.buffer_index;
    }

    fn tokenMaybeComplete(self: *Self) void {
        self.token.is_valid = true;
        self.token.end_buffer = self.buffer_index;
    }

    fn tokenNotComplete(self: *Self) void {
        self.token.is_valid = false;
        self.token.end_buffer = undefined;
    }

    /// Get the next token. Cases where a valid token is not found indicate that either EOF has been
    /// reached or the current input buffer (when streaming the input) needs to be refilled. If an
    /// error is encountered, the error is returned.
    pub fn next(self: *Self) !?Token {
        if (self.at_end_of_buffer) {
            return null;
        }
        while (!self.at_end_of_buffer) {
            // std.log.err(
            //     \\
            //     \\State = {} (stage = {})
            //     \\Token = {}
            //     \\Slice = {s}
            //     \\Byte  = {c}
            //     \\
            // , .{self.state, self.state_stage, self.token, self.token.slice(self.buffer), self.peek().?});

            switch (self.state) {

                .None => {
                    if ((try self.skipSeparators()) == false) return self.token;

                    self.token = Token{
                        .offset = self.buffer_cursor,
                        .line = self.current_line,
                        .start_buffer = self.buffer_index,
                    };
                    self.state_stage = 0;

                    const byte = self.peek().?;
                    const byte_as_delimiter = std.meta.intToEnum(Delimiter, byte) catch Delimiter.None;
                    switch (byte_as_delimiter) {
                        .Quote => {
                            self.token.token_type = TokenType.String;
                            self.state = State.QuotedString;
                        },
                        .Dollar => {
                            self.token.token_type = TokenType.MacroKey;
                            self.state = State.MacroX;
                        },
                        .Percent => {
                            self.token.token_type = TokenType.MacroParamKey;
                            self.state = State.MacroX;
                        },
                        .Dot => {
                            self.token.token_type = TokenType.MacroAccessor;
                            self.state = State.MacroX;
                        },
                        .ReverseSolidus => {
                            self.state = State.RawString;
                        },
                        .None => {
                            switch (byte) {
                                0x00...0x1F => return error.InvalidControlCharacter,
                                '/' => self.state = State.BareStringOrComment,
                                else => {
                                    self.token.token_type = TokenType.String;
                                    self.state = State.BareString;
                                },
                            }
                        },
                        else => {
                            _ = self.consume();
                            self.token.token_type = std.meta.intToEnum(TokenType, byte) catch unreachable;
                            self.tokenComplete();
                            return self.token;
                        },
                    }
                },

                .QuotedString => switch (self.state_stage) {
                    0 => { // starting quotation mark
                        if (self.advance().? != '"') return error.UnexpectedCommonQuotedStringStage0Byte;
                        self.token.offset = self.buffer_cursor;
                        self.state_stage = 1;
                    },
                    1 => if (self.consumeToBytes("\\\"")) |_| { // non-escaped bytes or ending quotation mark
                        switch (self.peek().?) {
                            '"' => {
                                _ = self.advance();
                                self.tokenComplete();
                                return self.token;
                            },
                            '\\' => {
                                _ = self.consume();
                                self.state_stage = 2; // consume the escape sequence from stage 3
                            },
                            else => unreachable,
                        }
                    },
                    2 => switch (try self.consumeEscapedByte()) { // escaped byte
                        'u' => self.state_stage = 3,
                        else => self.state_stage = 1,
                    },
                    3 => { // hex 1
                        try self.consumeHex();
                        self.state_stage = 4;
                    },
                    4 => { // hex 2
                        try self.consumeHex();
                        self.state_stage = 5;
                    },
                    5 => { // hex 3
                        try self.consumeHex();
                        self.state_stage = 6;
                    },
                    6 => { // hex 4
                        try self.consumeHex();
                        self.state_stage = 1;
                    },
                    else => return error.UnexpectedCommonQuotedStringStage,
                },

                // TODO: add transition table comment
                .MacroX => switch (self.state_stage) {
                    0 => {
                        switch (self.advance().?) {
                            '$', '%', '.' => {
                                self.token.offset = self.buffer_cursor;
                                self.state_stage = 1;
                            },
                            else => return error.UnexpectedMacroXStage0Byte,
                        }
                    },
                    1 => switch (self.peek().?) {
                        '"' => {
                            self.state_stage = 0;
                            self.state = State.QuotedString;
                        },
                        else => self.state = State.BareString,
                    },
                    else => return error.UnexpectedMacroXStage,
                },

                .BareString => {
                    if (self.consumeToBytes(delimiters) != null) {
                        self.tokenComplete();
                        return self.token;
                    }
                    // we've reached the end of the buffer without knowing if we've completed this bare string token,
                    // however, bare strings are technically valid all the way to EOF, so we mark it as such, but we
                    // stay in this state in case there's more input and this bare string continues
                    self.tokenMaybeComplete();
                },

                .RawString => switch (self.state_stage) {
                    0 => { // first reverse solidus
                        if (self.advance().? != '\\') return error.UnexpectedRawStringStage0Byte;
                        self.state_stage = 1;
                    },
                    1 => { // second reverse solidus
                        if (self.advance().? != '\\') return error.UnexpectedRawStringStage1Byte;

                        // we may be continuing a raw string and since raw string tokens are broken into
                        // their individual lines (for parsing reasons) we need to make sure this is a new token and not
                        // a continuation of the previous one
                        self.token = Token{
                            .offset = self.buffer_cursor,
                            .line = self.current_line,
                            .start_buffer = self.buffer_index,
                            .token_type = TokenType.RawString,
                        };

                        //    ex -> key = \\this is the rest of the string<EOF>
                        //          ^      ^^                             ^...raw string end + file end
                        //          |      ||...start of buffer 2 + start of raw string
                        //          |      |...end of buffer 1
                        //          |...file start + start of buffer 1
                        self.tokenMaybeComplete();
                        self.state_stage = 2;
                    },
                    2 => if (self.consumeToBytes("\r\n")) |_| { // all bytes to (and including) end of line
                        switch (self.advance().?) { // don't consume the newline yet
                            '\r' => {
                                self.crlf = true;
                                self.state_stage = 3;
                                self.tokenNotComplete();
                            },
                            '\n' => {
                                self.crlf = false;
                                self.state_stage = 4;
                            },
                            else => unreachable,
                        }
                    },
                    3 => { // ending linefeed for CRLF
                        if (self.advance().? != '\n') return error.UnexpectedRawStringStage3Byte;
                        self.state_stage = 4;
                        self.tokenMaybeComplete();
                    },
                    4 => if (self.skipWhileBytes("\t ") != null) { // leading white space
                        self.state_stage = 5;
                    },
                    5 => switch (self.peek().?) { // next raw string or end of raw string
                        '\\' => {
                            self.state_stage = 0;
                            // since we're continuing this raw string on the next line, count the previous
                            // newline as part of this string
                            self.token.size += @as(usize, if (self.crlf) 2 else 1);

                            // we know we'll be continuing a raw string and since raw string tokens are
                            // broken into their individual lines (for parsing reasons) we return this one
                            return self.token;
                        },
                        else => {
                            self.tokenComplete();
                            return self.token;
                        }
                    },
                    else => return error.UnexpectedRawStringStage,
                },

                .BareStringOrComment => switch (self.state_stage) {
                    0 => {
                        if (self.consume().? != '/') return error.UnexpectedBareStringOrCommentStage0Byte;
                        self.state_stage = 1;
                        // so far, this is a valid bare string
                        self.token.token_type = TokenType.String;
                        self.tokenMaybeComplete();
                    },
                    1 => {
                        switch (self.peek().?) {
                            '/' => {
                                self.token.token_type = TokenType.Comment;
                                self.state_stage = 2;
                            },
                            else => {
                                self.state = State.BareString;
                            },
                        }
                    },
                    2 => if (self.consumeToBytes("\r\n") != null) {
                        self.tokenComplete();
                        return self.token;
                    },
                    else => return error.UnexpectedBareStringOrCommentStage,
                },

            } // end state switch
        } // end :loop

        std.log.info("Buffer depleted!", .{});
        return self.token;
    }

    // ---- Scanning Operations

    /// Returns the byte currently pointed to by the buffer cursor. If the buffer cursor points to
    /// the end of the buffer, then `null` is returned.
    fn peek(self: Self) ?u8 {
        if (self.at_end_of_buffer) {
            return null;
        }
        return self.buffer[self.buffer_cursor];
    }

    /// Advances the buffer cursor to the next byte, and returns the byte that the cursor previously
    /// pointed to. This also increments the current line if the byte returned is `\n`. If the input
    /// cursor already points to the end of the buffer, then `null` is returned.
    fn advance(self: *Self) ?u8 {
        if (self.at_end_of_buffer) {
            return null;
        }
        self.buffer_cursor += 1;
        self.at_end_of_buffer = self.buffer_cursor == self.buffer.len;
        const byte = self.buffer[self.buffer_cursor - 1];
        if (byte == '\n') self.current_line += 1;
        return byte;
    }

    /// Advances the buffer cursor to the next byte, saves and adds the byte previously pointed to
    /// by the buffer cursor to the token size (i.e. consumes it), and returns that previous byte.
    /// If the buffer cursor already pointed to the end of the buffer, then `null` is returned.
    fn consume(self: *Self) ?u8 {
        if (self.advance()) |byte| {
            self.token.size += 1;
            return byte;
        }
        return null;
    }

    /// Consume all bytes until one of the target bytes is found, and return that target byte. If
    /// the buffer cursor points to the end of the buffer, this returns `null`.
    fn consumeToBytes(self: *Self, targets_: []const u8) ?u8 {
        while (self.peek()) |byte| {
            for (targets_) |target| {
                if (byte == target) {
                    return byte;
                }
            }
            _ = self.consume();
        }

        // We didn't find any of the target bytes, and we've exhausted the buffer.
        return null;
    }

    /// Consumes all bytes while they match one of the given targets, and return the first byte that
    /// does not match a target. If the buffer cursor points to the end of the buffer, this returns
    /// `null`.
    fn consumeWhileBytes(self: *Self, targets_: []const u8) ?u8 {
        peekloop: while (self.peek()) |byte| {
            for (targets_) |target| {
                if (byte == target) {
                    _ = self.consume();
                    continue :peekloop;
                }
            }
            // The byte we're looking at did not match any target, so return.
            return byte;
        }
        return null; // we've exhausted the buffer
    }

    /// Skips all bytes while they match one of the given targets, and return the first byte that
    /// does not match a target. If the buffer cursor points to the end of the buffer, this returns
    /// `null`.
    fn skipWhileBytes(self: *Self, targets_: []const u8) ?u8 {
        peekloop: while (self.peek()) |byte| {
            for (targets_) |target| {
                if (byte == target) {
                    _ = self.advance();
                    continue :peekloop;
                }
            }
            // The byte we're looking at did not match any target, so return.
            return byte;
        }
        return null; // we've exhausted the buffer
    }

    /// Consumes (and returns) the next byte and expects it to be a valid escaped byte.
    fn consumeEscapedByte(self: *Self) !u8 {
        if (self.consume()) |byte| {
            switch (byte) {
                'b', 'f', 'n', 'r', 't', 'u', '\\', '\"' => return byte,
                else => return error.InvalidEscapedByte,
            }
        }
        return error.InvalidEscapedByte;
    }

    /// Consumes the next byte and expects it to be a valid HEX character.
    fn consumeHex(self: *Self) !void {
        if (self.consume()) |byte| {
            switch (byte) {
                '0'...'9', 'A'...'F', 'a'...'f' => return,
                else => return error.InvalidHex,
            }
        }
        return error.InvalidHex;
    }

    /// Advances the buffer cursor until a non-separator byte is encountered and returns `true`. If
    /// no non-separator is encountered, this returns `false`. If more than one comma is encountered
    /// then `error.TooManyCommas` is returned. If an invalid CRLF is encountered then
    /// `error.CarriageReturnError` is returned.
    fn skipSeparators(self: *Self) !bool {
        var found_comma = false;
        while (self.peek()) |byte| {
            switch (byte) {
                ' ', '\t', '\n' => {
                    _ = self.advance();
                },
                '\r' => { // TODO: is this block necessary?
                    _ = self.advance();
                    if ((self.peek() orelse 0) == '\n') {
                        _ = self.advance();
                    } else {
                        return error.CarriageReturnError;
                    }
                },
                ',' => {
                    if (found_comma) {
                        return error.TooManyCommas;
                    }
                    found_comma = true;
                    _ = self.advance();
                },
                else => return true,
            }
        }
        return false;
    }

    /// Whether the buffer cursor is pointing to a delimiter or EOF.
    fn atDelimiterOrEof(self: *Self) bool {
        const byte = self.peek() orelse return true;
        // check for delimiters
        for (delimiters) |d| {
            if (byte == d) {
                return true;
            }
        }
        return false;
    }
}; // end Tokenizer struct


//==============================================================================
//
//
//
// Testing
//==============================================================================

const testing = std.testing;
const test_allocator = testing.allocator;

/// A structure describing the expected token.
const ExpectedToken = struct {
    str: []const u8,
    // most tests will have a single buffer, so make that the default
    start_buffer: usize = 0,
    end_buffer: usize = 0,
    line: usize,
    token_type: TokenType,
    // most tests should expect the token to be valid, so make that the default
    is_valid: bool = true,
};

fn expectToken(expected_token_: ExpectedToken, token_: Token, orig_str_: []const u8) !void {
    const str = try token_.slice(orig_str_);
    var ok = true;
    testing.expectEqualStrings(expected_token_.str, str) catch { ok = false; };
    testing.expectEqual(expected_token_.start_buffer, token_.start_buffer) catch { ok = false; };
    testing.expectEqual(expected_token_.end_buffer, token_.end_buffer) catch { ok = false; };
    testing.expectEqual(expected_token_.line, token_.line) catch { ok = false; };
    testing.expectEqual(expected_token_.token_type, token_.token_type) catch { ok = false; };
    testing.expectEqual(expected_token_.is_valid, token_.is_valid) catch { ok = false; };

    if (!ok) {
        return error.TokenTestFailure;
    }
}

fn doTokenTest(str_: []const u8, expected_tokens_: []const ExpectedToken) !void {
    var tokenizer = Tokenizer.init(str_);
    for (expected_tokens_) |expected_token, i| {
        const actual_token = (try tokenizer.next()) orelse return error.NullToken;
        errdefer {
            std.debug.print(
                \\
                \\Expected (#{}):
                \\  ExpectedToken{{ .str = "{s}", .line = {}, .token_type = {} }}
                \\Actual:
                \\  {}
                \\
                \\
            , .{i, expected_token.str, expected_token.line, expected_token.token_type, actual_token});
        }
        try expectToken(expected_token, actual_token, str_);
    }
}

test "simple comment" {
    const str = "// this is a comment";
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = str, .line = 1, .token_type = TokenType.Comment },
    };
    try doTokenTest(str, &expected_tokens);
}

test "comment at end of line" {
    const str =
        \\name = Zooce // this is a comment
        \\one = 12345// this is not a comment
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "name", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "Zooce", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "// this is a comment", .line = 1, .token_type = TokenType.Comment },
        ExpectedToken{ .str = "one", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 2, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "12345//", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "this", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "is", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "not", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "a", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "comment", .line = 2, .token_type = TokenType.String },
    };
    try doTokenTest(str, &expected_tokens);
}

// TODO: test complex comment - i.e. make sure no special Unicode characters mess this up

test "bare strings" {
    // IMPORTANT - this string is only for testing - it is not a valid zombie-file string
    const str = "I am.a,bunch{of\nstrings 01abc 123xyz=%d";
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "I", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "am", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "a", .line = 1, .token_type = TokenType.MacroAccessor },
        ExpectedToken{ .str = "bunch", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "{", .line = 1, .token_type = TokenType.OpenCurly },
        ExpectedToken{ .str = "of", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "strings", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "01abc", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "123xyz", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 2, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "d", .line = 2, .token_type = TokenType.MacroParamKey },
    };
    try doTokenTest(str, &expected_tokens);
}

test "quoted string" {
    const str = "\"this is a \\\"quoted\\\" string\\u1234 \\t\\r\\n$(){}[].,=\"";
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = str[1..str.len - 1], .line = 1, .token_type = TokenType.String },
    };
    try doTokenTest(str, &expected_tokens);
}

// raw String Tests

test "basic raw string" {
    const str =
        \\\\line one
        \\\\line two
        \\\\line three
        \\
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "line one\n", .line = 1, .token_type = TokenType.RawString },
        ExpectedToken{ .str = "line two\n", .line = 2, .token_type = TokenType.RawString },
        ExpectedToken{ .str = "line three", .line = 3, .token_type = TokenType.RawString },
    };
    try doTokenTest(str, &expected_tokens);
}

test "raw string with leading space" {
    const str =
        \\ \\line one
        \\  \\line two
        \\          \\line three
        \\
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "line one\n", .line = 1, .token_type = TokenType.RawString },
        ExpectedToken{ .str = "line two\n", .line = 2, .token_type = TokenType.RawString },
        ExpectedToken{ .str = "line three", .line = 3, .token_type = TokenType.RawString },
    };
    try doTokenTest(str, &expected_tokens);
}

test "raw string at EOF" {
    const str =
        \\\\line one
        \\\\line two
        \\\\line three
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "line one\n", .line = 1, .token_type = TokenType.RawString },
        ExpectedToken{ .str = "line two\n", .line = 2, .token_type = TokenType.RawString },
        ExpectedToken{ .str = "line three", .line = 3, .token_type = TokenType.RawString },
    };
    try doTokenTest(str, &expected_tokens);
}

test "string-raw-string kv-pair" {
    const str =
        \\key = \\first line
        \\      \\ second line
        \\     \\   third line
        \\123 = 456
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "key", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "first line\n", .line = 1, .token_type = TokenType.RawString },
        ExpectedToken{ .str = " second line\n", .line = 2, .token_type = TokenType.RawString },
        ExpectedToken{ .str = "   third line", .line = 3, .token_type = TokenType.RawString },
        ExpectedToken{ .str = "123", .line = 4, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 4, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "456", .line = 4, .token_type = TokenType.String },
    };
    try doTokenTest(str, &expected_tokens);
}

test "string-string concat" {
    const str =
        \\key = "hello, " + world
    ;

    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "key", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "hello, ", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "+", .line = 1, .token_type = TokenType.Plus },
        ExpectedToken{ .str = "world", .line = 1, .token_type = TokenType.String },
    };
    try doTokenTest(str, &expected_tokens);
}

// TODO: the following tests aren't really testing macros - move these to the parsing file

test "simple macro declaration" {
    const str =
        \\$name = "Zooce Dark"
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "name", .line = 1, .token_type = TokenType.MacroKey },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "Zooce Dark", .line = 1, .token_type = TokenType.String },
    };
    try doTokenTest(str, &expected_tokens);
}

test "macro object declaration" {
    const str =
        \\$black_forground = {
        \\    foreground = #2b2b2b
        \\}
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "black_forground", .line = 1, .token_type = TokenType.MacroKey },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "{", .line = 1, .token_type = TokenType.OpenCurly },
        ExpectedToken{ .str = "foreground", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 2, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "#2b2b2b", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "}", .line = 3, .token_type = TokenType.CloseCurly },
    };
    try doTokenTest(str, &expected_tokens);
}

// ref: https://zigforum.org/t/how-to-debug-zig-tests-with-gdb-or-other-debugger/487/4?u=zooce
// zig test ./test.zig --test-cmd gdb --test-cmd '--eval-command=run' --test-cmd-bin
// zig test src/token.zig --test-cmd lldb --test-cmd-bin
// zig test --test-filter "macro array declaration" src/token.zig --test-cmd lldb --test-cmd-bin
test "macro array declaration" {
    const str =
        \\$ports = [ 8000 8001 8002 ]
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "ports", .line = 1, .token_type = TokenType.MacroKey },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "[", .line = 1, .token_type = TokenType.OpenSquare },
        ExpectedToken{ .str = "8000", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "8001", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "8002", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "]", .line = 1, .token_type = TokenType.CloseSquare },
    };
    try doTokenTest(str, &expected_tokens);
}

test "macro with parameters declaration" {
    const str =
        \\$scope_def (scope settings) = {
        \\    scope = %scope
        \\    settings = %settings
        \\}
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "scope_def", .line = 1, .token_type = TokenType.MacroKey },
        ExpectedToken{ .str = "(", .line = 1, .token_type = TokenType.OpenParen },
        ExpectedToken{ .str = "scope", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "settings", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = ")", .line = 1, .token_type = TokenType.CloseParen },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "{", .line = 1, .token_type = TokenType.OpenCurly },
        ExpectedToken{ .str = "scope", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 2, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "scope", .line = 2, .token_type = TokenType.MacroParamKey },
        ExpectedToken{ .str = "settings", .line = 3, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 3, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "settings", .line = 3, .token_type = TokenType.MacroParamKey },
        ExpectedToken{ .str = "}", .line = 4, .token_type = TokenType.CloseCurly },
    };
    try doTokenTest(str, &expected_tokens);
}

test "quoted macro keys and parameters" {
    const str =
        \\$" ok = ." = 5
        \\$" = {\""(" = ") = {
        \\    scope = %" = "
        \\}
        \\
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = " ok = .", .line = 1, .token_type = TokenType.MacroKey },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "5", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = " = {\\\"", .line = 2, .token_type = TokenType.MacroKey },
        ExpectedToken{ .str = "(", .line = 2, .token_type = TokenType.OpenParen },
        ExpectedToken{ .str = " = ", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = ")", .line = 2, .token_type = TokenType.CloseParen },
        ExpectedToken{ .str = "=", .line = 2, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "{", .line = 2, .token_type = TokenType.OpenCurly },
        ExpectedToken{ .str = "scope", .line = 3, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 3, .token_type = TokenType.Equals },
        ExpectedToken{ .str = " = ", .line = 3, .token_type = TokenType.MacroParamKey },
        ExpectedToken{ .str = "}", .line = 4, .token_type = TokenType.CloseCurly },
    };
    try doTokenTest(str, &expected_tokens);
}

test "macro accessor" {
    const str =
        \\person = { name = Zooce,
        \\    occupation = $job(a b c).occupations.0 }
    ;
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "person", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "{", .line = 1, .token_type = TokenType.OpenCurly },
        ExpectedToken{ .str = "name", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "Zooce", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "occupation", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 2, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "job", .line = 2, .token_type = TokenType.MacroKey },
        ExpectedToken{ .str = "(", .line = 2, .token_type = TokenType.OpenParen },
        ExpectedToken{ .str = "a", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "b", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = "c", .line = 2, .token_type = TokenType.String },
        ExpectedToken{ .str = ")", .line = 2, .token_type = TokenType.CloseParen },
        ExpectedToken{ .str = "occupations", .line = 2, .token_type = TokenType.MacroAccessor },
        ExpectedToken{ .str = "0", .line = 2, .token_type = TokenType.MacroAccessor },
    };
    try doTokenTest(str, &expected_tokens);
}

test "string-string kv-pair" {
    const str = "key = value";
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "key", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "value", .line = 1, .token_type = TokenType.String },
    };
    try doTokenTest(str, &expected_tokens);
}

test "number-number kv-pair" {
    const str = "123 = 456";
    const expected_tokens = [_]ExpectedToken{
        ExpectedToken{ .str = "123", .line = 1, .token_type = TokenType.String },
        ExpectedToken{ .str = "=", .line = 1, .token_type = TokenType.Equals },
        ExpectedToken{ .str = "456", .line = 1, .token_type = TokenType.String },
    };
    try doTokenTest(str, &expected_tokens);
}
