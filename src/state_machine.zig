const std = @import("std");
const TokenType = @import("token.zig").TokenType;
const testing = std.testing;

const StackWidth = u128;
const StackElemWidth = u4; // TODO: we have an extra bit here so it's easier to debug - change this to u3 later
const STACK_SHIFT = @bitSizeOf(StackElemWidth);
pub const MAX_STACK_SIZE = @bitSizeOf(StackWidth) / STACK_SHIFT; // add more stacks if we need more?

const StackState = enum(StackElemWidth) {
    ObjectBegin,
    ArrayBegin,
    MacroExprKey,
    MacroExprArgsBegin,
    Value, // = 0b100
};

const NonStackState = enum(u5) { // we need 5 bits to represent these 18 values
    Decl = STACK_SHIFT + 1,
    Key,
    Equals,
    ValueConcat,

    ConsumeObjectEntry,
    ObjectEnd,

    ConsumeArrayItem,
    ArrayEnd,

    MacroDeclKey,
    MacroDeclOptionalParams,
    MacroDeclParams,

    MacroExprOptionalArgs,
    MacroExprOptionalAccessors,
    MacroExprAccessors,
    ConsumeMacroExprArgs,
    MacroExprEval,

    ConsumeMacroExprArg,
    MacroExprArgsEnd,
};

pub const State = @Type(blk: {
    const fields = @typeInfo(StackState).Enum.fields ++ @typeInfo(NonStackState).Enum.fields;

    break :blk .{
        .Enum = .{
            .layout = .Auto,
            .tag_type = std.math.IntFittingRange(0, fields.len - 1),
            .decls = &[_]std.builtin.TypeInfo.Declaration{},
            .fields = fields,
            .is_exhaustive = true,
        },
    };
});

pub const StateMachine = struct {
    const Self = @This();

    state: State = .Decl,

    // NOTE: the following bit-stack setup is based on zig/lib/std/json.zig
    stack: StackWidth = 0,
    stack_size: u8 = 0,

    pub fn push(self: *Self, state_: StackState) !void {
        if (self.stack_size > MAX_STACK_SIZE) {
            return error.TooManyStateStackPushes;
        }
        // update stack
        self.stack <<= STACK_SHIFT;
        self.stack |= @enumToInt(state_);
        self.stack_size += 1;
        // update state
        self.state = @intToEnum(State, @enumToInt(state_));
    }

    pub fn pop(self: *Self) !void {
        if (self.top()) |_| {
            // update stack
            self.stack >>= STACK_SHIFT;
            self.stack_size -= 1;
            // update state
            if (self.top()) |state| {
                // we always pop back to the corresponding consumption state
                self.state = switch (state) {
                    .ObjectBegin => .ConsumeObjectEntry,
                    .ArrayBegin => .ConsumeArrayItem,
                    .MacroExprKey => .ConsumeMacroExprArgs,
                    .MacroExprArgsBegin => .ConsumeMacroExprArg,
                    .Value => .Value,
                };
            } else {
                self.state = .Decl;
            }
        } else {
            return error.TooManyStateStackPops;
        }
    }

    pub fn top(self: Self) ?StackState {
        if (self.stack_size == 0) {
            return null;
        }
        return @intToEnum(StackState, self.stack & 0b1111);
    }

    pub fn log(self: Self) void {
        std.debug.print(
            \\----[State Machine]----
            \\State = {}
            \\Stack = 0x{X:0>32} | {}
            , .{ self.state, self.stack, self.stack_size }
        );
    }

    // fn stateStackHasMacros(self: Self) bool {
    //     return (self.stack & 0x2222_2222_2222_2222_2222_2222_2222_2222) > 0;
    // }

    /// Transition the state machine to the next state. This will catch all the
    /// expected token type errors.
    pub fn transition(self: *Self, token_: TokenType) !void {
        switch (self.state) {
            .Decl => self.state = switch (token_) {
                .MacroKey => .MacroDeclKey,
                .String => .Key,
                else => return error.UnexpectedDeclToken,
            },
            .Equals => switch (token_) {
                .Equals => try self.push(.Value), // TODO: go to ValueEnter
                else => return error.UnexpectedEqualsToken,
            },
            // TODO: consider adding a ValueEnter state where we can push the appropriate list to the stack?
            // .ValueEnter => self.state = .Value,
            .Value => switch (token_) {
                .String, .RawString, .MacroParamKey => self.state = .ValueConcat,
                .MacroKey => try self.push(.MacroExprKey),
                .OpenCurly => try self.push(.ObjectBegin),
                .OpenSquare => try self.push(.ArrayBegin),
                .CloseSquare => {
                    try self.pop();
                    self.state = .ArrayEnd;
                },
                else => return error.UnexpectedValueToken,
            },
            .ValueConcat => switch (token_) {
                .Plus, .RawString => self.state = .Value,
                else => try self.pop(),
            },

            // Object
            .ObjectBegin => self.state = switch (token_) {
                .OpenCurly => .Key,
                // TODO: maybe we should handle the empty object case here instead of in the .Key state?
                else => return error.UnexpectedObjectBeginToken,
            },
            .Key => self.state = switch (token_) {
                .String => .Equals,
                .CloseCurly => .ObjectEnd, // TODO: stage 2 - maybe we don't handle empty objects this way anymore?
                else => return error.UnexpectedKeyToken,
            },
            .ConsumeObjectEntry => self.state = .ObjectEnd, // TODO: is this even necessary?
            .ObjectEnd => switch (token_) {
                .String => self.state = .Key,
                .CloseCurly => try self.pop(),
                else => return error.UnexpectedObjectEndToken,
            },

            // Array
            .ArrayBegin => switch (token_) {
                .OpenSquare => try self.push(.Value),
                else => return error.UnexpectedArrayBeginToken,
            },
            .ConsumeArrayItem => self.state = .ArrayEnd, // TODO: is this even necessary
            .ArrayEnd => switch (token_) {
                .CloseSquare => try self.pop(),
                else => try self.push(.Value), // TODO: maybe do this in the .ConsumeArrayItem state?
            },

            // Macro Decl
            .MacroDeclKey => self.state = switch (token_) {
                .MacroKey => .MacroDeclOptionalParams,
                else => return error.UnexpectedMacroDeclKeyToken,
            },
            .MacroDeclOptionalParams => switch (token_) {
                .OpenParen => self.state = .MacroDeclParams,
                .Equals => try self.push(.Value),
                else => return error.UnexpectedMacroDeclOptionalParmasToken,
            },
            .MacroDeclParams => switch (token_) {
                .String => {}, // stay in this state
                .CloseParen => self.state = .Equals,
                else => return error.UnexpectedMacroDeclParamsToken,
            },

            // Macro Expr
            .MacroExprKey => self.state = switch (token_) {
                .MacroKey => .MacroExprOptionalArgs,
                else => return error.UnexpectedMacroExprKeyToken,
            },
            .MacroExprOptionalArgs => switch (token_) {
                .MacroAccessor => self.state = .MacroExprOptionalAccessors,
                .OpenParen => try self.push(.MacroExprArgsBegin),
                else => self.state = .MacroExprEval,
            },
            .MacroExprOptionalAccessors => self.state = switch (token_) {
                .MacroAccessor => .MacroExprAccessors,
                else => .MacroExprEval,
            },
            .MacroExprAccessors => switch (token_) {
                .MacroAccessor => {}, // stay here
                else => self.state = .MacroExprEval,
            },
            .ConsumeMacroExprArgs => self.state = .MacroExprOptionalAccessors,
            .MacroExprEval => try self.pop(),

            // Macro Expr Args
            .MacroExprArgsBegin => switch (token_) {
                .OpenParen => try self.push(.Value),
                else => return error.UnexpectedMacroExprArgsBeginToken,
            },
            .ConsumeMacroExprArg => self.state = .MacroExprArgsEnd,
            .MacroExprArgsEnd => switch (token_) {
                .CloseParen => try self.pop(),
                else => try self.push(.Value),
            },
        }
    }
};

test "temp" {
    const state = StackState.ObjectBegin;
    var sm = StateMachine{};
    try sm.push(state);
    try testing.expectEqual(@intToEnum(State, @enumToInt(state)), sm.top().?);
    try sm.pop();
    try testing.expect(sm.top() == null);
}


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
