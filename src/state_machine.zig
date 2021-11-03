const std = @import("std");
const TokenType = @import("token.zig").TokenType;
const testing = std.testing;
const util = @import("util.zig");

const StackWidth = u128;
const StackElemWidth = u4; // TODO: we have an extra bit here so it's easier to debug - change this to u3 later?
const STACK_SHIFT = @bitSizeOf(StackElemWidth);
pub const MAX_STACK_SIZE = @bitSizeOf(StackWidth) / STACK_SHIFT; // add more stacks if we need more?

pub const State = enum {
    ObjectBegin,                // 0
    ArrayBegin,                 // 1
    MacroExprKey,               // 2
    MacroExprArgsBegin,         // 3
    MacroDeclParam,             // 4
    MacroExprBatchListBegin,    // 5
    MacroExprBatchArgsBegin,    // 6
    Value,                      // 7

    Decl,
    Key,
    Equals,
    ValueEnter,
    ValueConcat,

    ConsumeObjectEntry,
    ObjectEnd,

    ConsumeArrayItem,
    ArrayEnd,

    MacroDeclKey,
    MacroDeclOptionalParams,
    MacroDeclParamOptionalDefaultValue,
    ConsumeMacroDeclParam,
    ConsumeMacroDeclDefaultParam,
    MacroDeclParamsEnd,

    MacroExprOptionalArgsOrAccessors,
    ConsumeMacroExprArgsOrBatchList,
    MacroExprOptionalAccessors,
    MacroExprAccessors,
    MacroExprOptionalBatch,
    ConsumeMacroExprBatchArgsList,

    ConsumeMacroExprArg,
    MacroExprArgsEnd,

    ConsumeMacroExprBatchArgs,
    MacroExprBatchListEnd,
};

pub const StateMachine = struct {
    const Self = @This();

    state: State = .Decl,

    // NOTE: the following bit-stack setup is based on zig/lib/std/json.zig
    stack: StackWidth = 0,
    stack_size: u8 = 0,

    pub fn push(self: *Self, state_: State) !void {
        if (self.stack_size > MAX_STACK_SIZE) {
            return error.TooManyStateStackPushes;
        }
        switch (state_) {
            .ObjectBegin,
            .ArrayBegin,
            .MacroExprKey,
            .MacroExprArgsBegin,
            .MacroDeclParam,
            .MacroExprBatchListBegin,
            .MacroExprBatchArgsBegin,
            .Value, => {},
            else => return error.BadStatePush,
        }
        // update stack
        self.stack <<= STACK_SHIFT;
        self.stack |= @enumToInt(state_);
        self.stack_size += 1;
        // update state
        self.state = @intToEnum(State, @enumToInt(state_));
    }

    pub fn pop(self: *Self) !void {
        if (self.stack_size > 0) {
            // update stack
            self.stack >>= STACK_SHIFT;
            self.stack_size -= 1;
            // update state
            if (self.top()) |state| {
                // we always pop back to the corresponding consumption state
                self.state = switch (state) {
                    .ObjectBegin => .ConsumeObjectEntry,
                    .ArrayBegin => .ConsumeArrayItem,
                    .MacroExprKey => .ConsumeMacroExprArgsOrBatchList,
                    .MacroExprArgsBegin => .ConsumeMacroExprArg,
                    .MacroDeclParam => .ConsumeMacroDeclDefaultParam,
                    .MacroExprBatchListBegin => .ConsumeMacroExprBatchArgsList,
                    .MacroExprBatchArgsBegin => .ConsumeMacroExprBatchArgs,
                    .Value => .ValueConcat,
                    else => return error.UnexpectedStateOnStack,
                };
            } else {
                self.state = .Decl;
            }
        } else {
            return error.TooManyStateStackPops;
        }
    }

    pub fn top(self: Self) ?State {
        if (self.stack_size == 0) {
            return null;
        }
        return @intToEnum(State, self.stack & 0b1111);
    }

    pub fn log(self: Self, writer_: anytype) std.os.WriteError!void {
        try writer_.print(
            \\----[State Machine]----
            \\State = {}
            \\Stack = 0x{X:0>32}
            \\Size  = {}
            \\
            , .{ self.state, self.stack, self.stack_size }
        );
    }

    /// Transition the state machine to the next state. This will catch all the
    /// expected token type errors.
    pub fn transition(self: *Self, token_: TokenType) !void {
        if (util.DEBUG) {
            std.debug.print("{} --({})--> ", .{self.state, token_});
        }
        // we can still transition even if the token type is .None
        switch (self.state) {
            .Decl => self.state = switch (token_) {
                .MacroKey => .MacroDeclKey,
                .String => .Key,
                else => return error.UnexpectedDeclToken,
            },
            .Equals => switch (token_) {
                .Equals => self.state = .ValueEnter,
                else => return error.UnexpectedEqualsToken,
            },
            .ValueEnter => switch (token_) {
                .CloseSquare => self.state = .ArrayEnd,
                else => try self.push(.Value),
            },
            .Value => switch (token_) {
                .String, .RawString, .MacroParamKey => self.state = .ValueConcat,
                .MacroKey => try self.push(.MacroExprKey),
                .OpenCurly => try self.push(.ObjectBegin),
                .OpenSquare => try self.push(.ArrayBegin),
                .Question => try self.pop(), // we forbid placeholder concatenation....TODO: do we really need to?
                else => return error.UnexpectedValueToken,
            },
            .ValueConcat => switch (token_) {
                .Plus, .RawString => self.state = .Value,
                else => try self.pop(),
            },

            // Object
            .ObjectBegin => self.state = switch (token_) {
                .OpenCurly => .Key,
                else => return error.UnexpectedObjectBeginToken,
            },
            .Key => self.state = switch (token_) {
                .String => .Equals,
                .CloseCurly => .ObjectEnd,
                else => return error.UnexpectedKeyToken,
            },
            .ConsumeObjectEntry => self.state = .ObjectEnd,
            .ObjectEnd => switch (token_) {
                .String => self.state = .Key,
                .CloseCurly => try self.pop(),
                else => return error.UnexpectedObjectEndToken,
            },

            // Array
            .ArrayBegin => switch (token_) {
                .OpenSquare => self.state = .ValueEnter,
                else => return error.UnexpectedArrayBeginToken,
            },
            .ConsumeArrayItem => self.state = .ArrayEnd,
            .ArrayEnd => switch (token_) {
                .CloseSquare => try self.pop(),
                else => self.state = .ValueEnter,
            },

            // Macro Decl
            .MacroDeclKey => self.state = switch (token_) {
                .MacroKey => .MacroDeclOptionalParams,
                else => return error.UnexpectedMacroDeclKeyToken,
            },
            .MacroDeclOptionalParams => switch (token_) {
                .OpenParen => self.state = .MacroDeclParam,
                .Equals => self.state = .ValueEnter,
                else => return error.UnexpectedMacroDeclOptionalParamsToken,
            },
            .MacroDeclParam => switch (token_) {
                .String => self.state = .MacroDeclParamOptionalDefaultValue,
                .CloseParen => self.state = .MacroDeclParamsEnd,
                else => return error.UnexpectedMacroDeclParamToken,
            },
            .MacroDeclParamOptionalDefaultValue => switch (token_) {
                .Equals => {
                    try self.push(.MacroDeclParam);
                    self.state = .ValueEnter;
                },
                .String, .CloseParen => self.state = .ConsumeMacroDeclParam,
                else => return error.UnexpectedMacroDeclParamOptionalDefaultValueToken,
            },
            .ConsumeMacroDeclParam => self.state = switch (token_) {
                .String => .MacroDeclParam,
                .CloseParen => .MacroDeclParamsEnd,
                else => return error.UnexpectedConsumeMacroDeclParamToken,
            },
            .ConsumeMacroDeclDefaultParam => {
                try self.pop();
                self.state = switch (token_) {
                    .String => .MacroDeclParam,
                    .CloseParen => .MacroDeclParamsEnd,
                    else => return error.UnexpectedConsumeMacroDeclDefaultParamToken,
                };
            },
            .MacroDeclParamsEnd => self.state = switch (token_) {
                .CloseParen => .Equals,
                else => return error.UnexpectedMacroDeclParamsEndToken,
            },

            // Macro Expr
            .MacroExprKey => self.state = switch (token_) {
                .MacroKey => .MacroExprOptionalArgsOrAccessors,
                else => return error.UnexpectedMacroExprKeyToken,
            },
            .MacroExprOptionalArgsOrAccessors => switch (token_) {
                .MacroAccessor => self.state = .MacroExprOptionalAccessors,
                .OpenParen => try self.push(.MacroExprArgsBegin),
                else => self.state = .MacroExprOptionalBatch,
            },
            .ConsumeMacroExprArgsOrBatchList => self.state = .MacroExprOptionalAccessors,
            .MacroExprOptionalAccessors => self.state = switch (token_) {
                .MacroAccessor => .MacroExprAccessors,
                else => .MacroExprOptionalBatch,
            },
            .MacroExprAccessors => switch (token_) {
                .MacroAccessor => {}, // stay here
                else => self.state = .MacroExprOptionalBatch,
            },
            .MacroExprOptionalBatch => switch (token_) {
                .Percent => try self.push(.MacroExprBatchListBegin),
                else => try self.pop(),
            },
            .ConsumeMacroExprBatchArgsList => try self.pop(),

            // Macro Expr Args
            .MacroExprArgsBegin => switch (token_) {
                .OpenParen => self.state = .ValueEnter,
                else => return error.UnexpectedMacroExprArgsBeginToken,
            },
            .ConsumeMacroExprArg => self.state = .MacroExprArgsEnd,
            .MacroExprArgsEnd => switch (token_) {
                .CloseParen => try self.pop(),
                else => self.state = .ValueEnter,
            },

            // Macro Expr Batch List (outter array)
            .MacroExprBatchListBegin => switch (token_) {
                .OpenSquare => try self.push(.MacroExprBatchArgsBegin),
                else => return error.UnexpectedMacroExprBatchListBeginToken,
            },
            // Macro Expr Batch Args (inner arrays)
            .MacroExprBatchArgsBegin => switch (token_) {
                .OpenSquare => try self.push(.ArrayBegin),
                else => return error.UnexpectedMacroExprBatchArgsBegin,
            },
            .ConsumeMacroExprBatchArgs => {
                try self.pop();
                self.state = .MacroExprBatchListEnd;
            },
            .MacroExprBatchListEnd => switch (token_) {
                .CloseSquare => try self.pop(),
                else => try self.push(.MacroExprBatchArgsBegin),
            },
        }
        if (util.DEBUG) {
            std.debug.print("{}\n", .{self.state});
        }
    }
};

test "general stack logic" {
    var stack: u128 = 0;
    var stack_size: u8 = 0;
    const stack_size_limit: u8 = 64;
    const shift = 2;

    try testing.expectEqual(@as(u128, 0x0000_0000_0000_0000_0000_0000_0000_0000), stack);

    // This loop should push 0, 1, 2, and 3 in sequence until the max stack size
    // has been reached.
    var t: u8 = 0;
    while (stack_size < stack_size_limit) {
        stack <<= shift;
        stack |= t;
        stack_size += 1;
        t = (t + 1) % 4;
        if (stack_size != stack_size_limit) {
            try testing.expect(@as(u128, 0x1B1B_1B1B_1B1B_1B1B_1B1B_1B1B_1B1B_1B1B) != stack);
        }
    }
    try testing.expectEqual(@as(u128, 0x1B1B_1B1B_1B1B_1B1B_1B1B_1B1B_1B1B_1B1B), stack);
    while (stack_size > 0) {
        t = if (t == 0) 3 else (t - 1);
        try testing.expectEqual(@as(u128, t), (stack & 0b11));
        stack >>= shift;
        stack_size -= 1;
    }
    try testing.expectEqual(@as(u128, 0x0000_0000_0000_0000_0000_0000_0000_0000), stack);
}
