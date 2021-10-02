const std = @import("std");
const TokenType = @import("token.zig").TokenType;
const testing = std.testing;

const StackWidth = u128;
const StackElemWidth = u4;
const STACK_SHIFT = @bitSizeOf(StackElemWidth);
pub const MAX_STACK_SIZE = @bitSizeOf(StackWidth) / STACK_SHIFT; // add more stacks if we need more?

pub const State = enum {
    Decl,
    MacroDecl,
    KvPair,
    Object,
    Array,
    MacroExpr,
    MacroExprArgs,
    Value,

    // ---

    Key,
    Equals,
    ObjectBegin,
    ObjectConsume,
    ObjectEnd,
    ArrayBegin,
    ArrayConsume,
    ArrayEnd,
    ValueConcat,
};

pub const StateStackElem = enum(StackElemWidth) {
    object,
    array,
    macro_expr,
    macro_expr_args,
    value,
};

pub const StateMachine = struct {
    const Self = @This();

    state: State = .Decl,
    stage: u8 = 0,

    // NOTE: the following bit-stack setup is based on zig/lib/std/json.zig
    stack: StackWidth = 0,
    stack_size: u8 = 0,

    pub fn push(self: *Self, stack_elem_: StateStackElem) !void {
        if (self.stack_size > MAX_STACK_SIZE) {
            return error.TooManyStateStackPushes;
        }
        self.stack <<= STACK_SHIFT;
        self.stack |= @enumToInt(stack_elem_);
        self.stack_size += 1;
    }

    pub fn push2(self: *Self, state_: State) !void {
        if (self.stack_size > MAX_STACK_SIZE) {
            return error.TooManyStateStackPushes;
        }
        const stack_elem: StackElemWidth = switch (state_) {
            .Object => 0,
            .Array => 1,
            .MacroExpr => 2,
            .MacroExprArgs => 3,
            .Value => 4,
            else => return error.UnexpectedStatePushed, // TODO: also log an error
        };
        // update stack
        self.stack <<= STACK_SHIFT;
        self.stack |= stack_elem;
        self.stack_size += 1;
        // update state
        self.state = state_;
        self.stage = 0;
    }

    pub fn pop(self: *Self) !StateStackElem {
        if (self.top()) |s| {
            self.stack >>= STACK_SHIFT;
            self.stack_size -= 1;
            return s;
        }
        return error.TooManyStateStackPops;
    }

    pub fn pop2(self: *Self) !State {
        if (self.top2()) |s| {
            // update stack
            self.stack >>= STACK_SHIFT;
            self.stack_size -= 1;
            // update state

        }
    }

    pub fn top(self: Self) ?StateStackElem {
        if (self.stack_size == 0) {
            return null;
        }
        return @intToEnum(StateStackElem, self.stack & 0b1111);
    }

    /// Transition the state machine to the next state. This will catch all the
    /// expected token type errors.
    pub fn transition(self: *Self, token_: TokenType) !void {
        switch (self.state) {
            .Decl => self.state = switch (token_) {
                .MacroKey => .MacroDecl,
                .String => .Key,
                else => return error.UnexpectedDeclToken,
            },
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
            .Equals => switch (token_) {
                .Equals => try self.push(.Value),
                else => return error.UnexpectedEqualsToken,
            },
            .ObjectConsume => self.state = .ObjectEnd, // TODO: is this even necessary?
            .ObjectEnd => switch (token_) {
                .String => self.state = .Key,
                .CloseCurly => _ = try self.pop(),
                else => return error.UnexpectedObjectEndToken,
            },
            .ArrayBegin => switch (token_) {
                .OpenSquare => try self.push(.Value),
                else => return error.UnexpectedArrayBeginToken,
            },
            .ArrayConsume => self.state = .ArrayEnd,
            .ArrayEnd => switch (token_) {
                .CloseSquare => _ = try self.pop(),
                else => return error.UnexpectedArrayEndToken,
            },
            .Value => switch (token_) {
                .String, .RawString, .MacroParamKey => self.state = .ValueConcat,
                .MacroKey => try self.push(.MacroExpr),
                .OpenCurly => try self.push(.ObjectBegin),
                .OpenSquare => try self.push(.ArrayBegin),
                .CloseSquare => {
                    _ = try self.pop();
                    self.state = .ArrayEnd;
                },
            },
            .ValueConcat => switch (token_) {
                .Plus, .RawString => .Value,
                else => _ = try self.pop(),
            }
        }
    }
};

test "temp" {
    const state = State.Object;
    var sm = StateMachine{};
    try sm.push2(state);
    try testing.expectEqual(state, sm.top2().?);
    try testing.expectEqual(state, try sm.pop2());
}
