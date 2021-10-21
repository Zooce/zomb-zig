const std = @import("std");

const token = @import("token.zig");
pub const Tokenizer = token.Tokenizer;
pub const TokenType = token.TokenType;
pub const Token = token.Token;

const parse = @import("parse.zig");
pub const Parser = parse.Parser;
pub const Zomb = parse.Zomb;

const data = @import("data.zig");
pub const ZValue = data.ZValue;

pub const max_nested_depth = @import("state_machine.zig").MAX_STACK_SIZE;

pub const StringReader = @import("string_reader.zig").StringReader;

test {
    // the tests from each of these modules will be run when we import them here
    _ = @import("scan.zig");
    _ = @import("token.zig");
    _ = @import("parse.zig");
    _ = @import("data.zig");
    _ = @import("state_machine.zig");
}
