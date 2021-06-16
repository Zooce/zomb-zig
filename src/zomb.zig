const std = @import("std");

const token = @import("token.zig");
pub const Tokenizer = token.Tokenizer;
pub const TokenType = token.TokenType;
pub const Token = token.Token;

const parse = @import("parse.zig");
pub const Parser = parse.Parser;
pub const ZombType = parse.ZombType;

pub const ZombTypeMap = parse.ZombTypeMap;
pub const ZombTypeArray = parse.ZombTypeArray;
pub const Zomb = parse.Zomb;

pub const max_nested_depth = parse.max_stack_size;


pub const StringReader = @import("string_reader.zig").StringReader;

test {
    // the tests from each of these modules will be run when we import them here
    _ = @import("scan.zig");
    _ = @import("token.zig");
    _ = @import("parse.zig");
}
