const std = @import("std");

const Tokenizer = @import("token.zig").Tokenizer;
const Token = @import("token.zig").Token;
// const State = @import("state_machine.zig").State;
const StateMachine = @import("state_machine.zig").StateMachine;

const ZValue = @import("data.zig").ZValue;
const ZExpr = @import("data.zig").ZExpr;
const ZExprArg = @import("data.zig").ZExprArg;
const ConcatItem = @import("data.zig").ConcatItem;
const ConcatList = @import("data.zig").ConcatList;
const ZMacro = @import("data.zig").ZMacro;

const ParseMacro = struct {
    const Self = @This();

    key: []const u8,
    current_param: ?[]const u8 = null,
    macro: *ZMacro,
    parameter_counts: ?std.StringArrayHashMap(usize) = null,

    pub fn deinit(self: *Self) void {
        self.parameter_counts.deinit();
    }

    pub fn initParams(self: *Self, allocator_: *std.mem.Allocator) void {
        self.macro.*.parameters = std.StringArrayHashMap(?ConcatList).init(allocator_);
        self.parameter_counts = std.StringArrayHashMap(usize).init(allocator_);
    }

    pub fn newParameter(self: *Self, param_name_: []const u8) !void {
        try self.macro.*.parameters.?.putNoClobber(param_name_, null);
        try self.parameter_counts.?.putNoClobber(param_name_, 0);
        self.current_param = param_name_;
    }

    pub fn consumeDefaultParam(self: *Self, default_val_: ConcatList) !void {
        defer self.current_param = null;
        if (try self.macro.*.parameters.?.getPtr(self.current_param.?)) |res_ptr| {
            res_ptr.* = default_val_;
        } else {
            std.log.err("no parameter named '{s}'", .{ self.current_param.? });
            return error.InvalidMacroParameter;
        }
    }

    pub fn validate(self: Self) !void {
        if (parameter_counts) |param_counts| {
            var iter = param_counts.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* == 0) {
                    std.log.err("'{}' parameter never used inside '{}' macro", .{ entry.key_ptr.*, self.key });
                    return error.UnusedMacroParamter;
                }
            }
        }
    }
};

const StackElem = @import("stack.zig").StackElem;
const Stack = @import("stack.zig").Stack;

pub const Zomb = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringArrayHashMap(ZombValue),

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }
};

pub const Parser = struct {
    const Self = @This();

    arena: std.heap.ArenaAllocator,
    input: []const u8 = undefined,
    tokenizer: Tokenizer,
    state_machine: StateMachine = StateMachine{},
    parse_macro: ?ParseMacro = null,
    macros: std.StringArrayHashMap(ZombMacro) = undefined,
    token: ?Token = null,

    pub fn init(input_: []const u8, alloc_: *std.mem.Allocator) Self {
        return Self{
            .arena = std.heap.ArenaAllocator.init(alloc_),
            .input = input_,
            .tokenizer = Tokenizer.init(input_),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn parse(self: *Self, allocator_: *std.mem.Allocator) !Zomb {
        // initialize some temporary memory we need for parsing
        self.stack = Stack.init(&self.arena.allocator);
        self.macros = std.StringArrayHashMap(ZombMacro).init(&self.arena.allocator);

        // this arena will be given to the caller so they can clean up the memory we allocate for the ZOMB types
        var out_arena = std.heap.ArenaAllocator.init(allocator_);
        errdefer out_arena.deinit();

        // add the implicit top-level object to our type stack
        try self.stack.push(.{ .Val = .{ .Object = std.StringArrayHashMap(ZValue).init(&out_arena.allocator) } });

        var done = false;
        while (!done) {
            try self.log();
            try self.step(&out_arena);
            done = self.token != null;
        }

        if (self.zomb_value_stack.items.len > 1) {
            switch (self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1]) {
                .Expr => {
                    const value = try self.evaluateMacroExpr(&out_arena.allocator, self.zomb_value_stack.pop().Expr);
                    try self.zomb_value_stack.append(.{ .Value = value });
                },
                .ExprArgs => {
                    var args = self.zomb_value_stack.pop().ExprArgs;
                    var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                    expr.*.args = args;
                    const value = try self.evaluateMacroExpr(&out_arena.allocator, self.zomb_value_stack.pop().Expr);
                    try self.zomb_value_stack.append(.{ .Value = value });
                },
                .Value => {},
                else => return error.UnexpectedStackTop,
            }
            try self.stackConsumeKvPair();
        }
        return Zomb{
            .arena = out_arena,
            .map = self.zomb_value_stack.pop().Value.Object,
        };
    }

    /// Process the current token based on the current state, transition to the
    /// next state, and update the current token if necessary.
    ///
    /// NOTE: Any time you see a `return` in this function, it means we do not
    ///       want to transition to the next state and we also want to keep the
    ///       current token.
    pub fn step(self: *Self, out_arena_: *std.heap.ArenaAllocator) !void {
        // comments are ignored everywhere - make sure to get the next token as well
        if (self.token == null or self.token.?.token_type == .Comment) {
            self.token = try self.tokenizer.next();
            return;
        }
        // get the token slice for convenience
        const token_slice = try self.token.?.slice(self.input);
        var keep_token = false;
        // process the current token based on our current state
        switch (self.state_machine.state) {
            .Decl => {
                // TODO: is it possible NOT to have this "lagging" consume?
                if (self.parse_macro) |parse_macro| {
                    try parse_macro.validate();
                    parse_macro.macro.*.value = self.stack.pop().CList;
                } else if (self.stack.size() > 1) {
                    try self.stack.consumeObjectEntry(&out_arena_.allocator, self.macros);
                }
                self.parse_macro.deinit();
                self.parse_macro = null;
                keep_token = true;
            },
            .Equals => {
                try self.stack.push(.{ .CList = ConcatList.init(&self.arena.allocator) });
            },
            .Value => {
                var concat_list = self.stack.top();
                switch (self.token.?.token_type) {
                    .String, .RawString => try concat_list.*.append(.{ .CItem = .{ .String = token_slice } }),
                    .MacroParamKey => {
                        if (self.parse_macro) |parse_macro| {
                            if (parse_macro.current_param != null) {
                                return error.UseOfParameterAsDefaultValue;
                            }
                            if (parse_macro.parameter_counts.?.getPtr(token_slice)) |p| {
                                p.* += 1; // count the usage of this parameter
                            } else {
                                return error.InvalidParameterUse;
                            }
                            try concat_list.*.append(.{ .CItem = .{ .Parameter = token_slice } });
                        } else {
                            return error.MacroParamKeyUsedOutsideMacroDecl;
                        }
                    },
                    .MacroKey, .OpenCurly, .OpenSquare, .CloseSquare => keep_token = true,
                    else => {},
                }
            },
            .ValueConcat => if (self.token.?.token_type != .Plus) {
                keep_token = true;
            },

            // Objects
            .ObjectBegin => {
                var obj = if (self.parse_macro) |_| {
                    .{ .CItem = .{ .Object = std.StringArrayHashMap(ConcatList).init(&self.arena.allocator) } }
                } else {
                    .{ .Val = .{ .Object = std.StringArrayHashMap(ZValue).init(&out_arena_.allocator) } }
                };
                try self.stack.push(obj);
            },
            .Key => {
                try self.stack.push(.{ .Key = token_slice });
            },
            .ConsumeObjectEntry => {
                var alloc = if (self.parse_macro) |_| null else &out_arena_.allocator;
                try self.stack.consumeObjectEntry(alloc, self.macros);
                keep_token = true;
            },
            .ObjectEnd => switch (self.token.?.token_type) {
                .String => keep_token = true,
                else => {}, // do nothing
            },

            // Arrays
            .ArrayBegin => {
                var arr = if (self.parse_macro) |_| {
                    .{ .CItem = .{ .Array = std.ArrayList(ConcatList).init(&self.arena.allocator) } }
                } else {
                    .{ .Val = .{ .Array = std.ArrayList(ZValue).init(&out_arena_.allocator) } }
                };
                try self.stack.push(arr);
                try self.stack.push(.{ .CList = ConcatList.init(&self.arena.allocator) });
            },
            .ConsumeArrayItem => {
                var alloc = if (self.parse_macro) |_| null else &out_arena_.allocator;
                try self.stack.consumeArrayItem(alloc, self.macros);
                keep_token = true;
            },
            .ArrayEnd => switch (self.token.?.token_type) {
                .CloseSquare => {}, // do nothing
                else => {
                    keep_token = true
                    try self.stack.push(.{ .CList = ConcatList.init(&self.arena.allocator) });
                },
            },

            // Macro Declaration
            .MacroDeclKey => {
                var res = try self.macros.getOrPut(token_slice);
                if (res.found_existing) return error.DuplicateMacroName;
                res.value_ptr.* = ZMacro{};
                self.parse_macro = ParseMacro{
                    .key = token_slice,
                    .macro = res.value_ptr,
                };
            },
            .MacroDeclOptionalParams => if (self.token.?.token_type == .OpenParen) {
                self.parse_macro.?.initParams(&self.arena.allocator);
            },
            .MacroDeclParam => switch (self.token.?.token_type) {
                .String => try self.parse_macro.?.newParameter(token_slice),
                .CloseParen => if (self.parse_macro.?.param_counts.?.count() == 0) {
                    return error.EmptyMacroDeclParams;
                },
                else => {}, // state machine will catch unexpected token errors
            },
            .MacroDeclParamOptionalDefaultValue => switch (self.token.?.token_type) {
                .String => keep_token = true, // no default value
                .Equals => try self.stack.push(.{ .CList = ConcatList.init(&self.arena.allocator) }),
                else => {}, // state machine will catch unexpected token errors
            },
            .ConsumeMacroDeclParam => {
                const default_param = try self.stack.pop().CList;
                try self.parse_macro.?.consumeDefaultParam(default_param);
                keep_token = true;
            },

            // TODO: Macro Expression
            .MacroExprKey => {
                // var concat_list = &self.stack.items[self.stack.items.len - 1].ConcatList;
                // try concat_list.append(.{ .Expr = .{ .key = token_slice } });
                if (self.parse_macro) |_| {
                    try self.zomb_macro_value_stack.append(.{ .Expr = .{ .Expr = ZombMacroDeclExpr{ .key = token_slice } } });
                } else {
                    try self.zomb_value_stack.append(.{ .Expr = ZombMacroExpr{ .key = token_slice } });
                }
            },
            .MacroExprOptionalArgs => keep_token = true,
            .MacroExprOptionalAccessors => {
                if (self.token.?.token_type == .MacroAccessor) {
                    // var expr = &self.stack.items[self.stack.items.len - 1].Expr;
                    // if (expr.*.accessors == null) {
                    //     expr.*.accessors = std.ArrayList([]const u8).init(&self.arena.allocator);
                    // }
                    if (self.parse_macro) |_| {
                        var expr = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].Expr.Expr;
                        if (expr.*.accessors == null) {
                            expr.*.accessors = std.ArrayList([]const u8).init(&self.arena.allocator);
                        }
                    } else {
                        var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                        if (expr.*.accessors == null) {
                            expr.*.accessors = std.ArrayList([]const u8).init(&self.arena.allocator);
                        }
                    }
                }
                keep_token = true;
            },
            .MacroExprAccessors => switch (self.token.?.token_type) {
                .MacroAccessor => {
                    // var expr = &self.stack.items[self.stack.items.len - 1].Expr;
                    // try expr.*.accessors.?.append(token_slice);
                    if (self.parse_macro) |_| {
                        var expr = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].Expr.Expr;
                        try expr.*.accessors.?.append(token_slice);
                    } else {
                        var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                        try expr.*.accessors.?.append(token_slice);
                    }
                },
                else => keep_token = true,
            },
            .ConsumeMacroExprArgs => {
                // TODO: update for single stack design
                // TODO: update for expression batching
                // var isBatch = false;
                if (self.parse_macro) |_| {
                    var args = self.zomb_macro_value_stack.pop().ExprArgs;
                    var expr = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].Expr;
                    expr.*.Expr.args = args;
                    // TODO: iterate through args - if `?` is found, this is a batch
                } else {
                    var args = self.zomb_value_stack.pop().ExprArgs;
                    var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                    expr.*.args = args;
                    // TODO: iterate through args - if `?` is found, this is a batch
                }
                // TODO: if `isBatch == true` go to new stage to wait for `%`
                keep_token = true;
            },
            .MacroExprEval => {
                // var expr = self.stack.pop().Expr;
                if (self.parse_macro) |_| {
                    // var concat_list = &self.stack.items[self.stack.items.len - 1].ConcatList;
                    // try concat_list.append(expr);
                    var expr = self.zomb_macro_value_stack.pop().Expr;
                    var list = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].List.ExprList;
                    try list.append(expr);
                } else {
                    // var value = try self.evaluateMacroExpr(&out_arena_.allocator, expr);
                    // try self.stack.append(.{ .Value = value });
                    var expr = self.zomb_value_stack.pop().Expr;
                    var value = try self.evaluateMacroExpr(&out_arena_.allocator, expr);
                    try self.zomb_value_stack.append(.{ .Value = value });
                }
                keep_token = true;
            },

            // Macro Expression Arguments
            .MacroExprArgsBegin => {
                // try self.stack.append(.{ .ExprArgList = std.ArrayList(ExprArgType).init(&self.arena.allocator) });
                if (self.parse_macro) |_| {
                    try self.zomb_macro_value_stack.append(.{ .ExprArgs = std.ArrayList(DeclExprArgType).init(&self.arena.allocator) });
                } else {
                    try self.zomb_value_stack.append(.{ .ExprArgs = std.ArrayList(ExprArgType).init(&self.arena.allocator) });
                }
            },
            .ConsumeMacroExprArg => {
                // const arg = self.stack.pop().ExprArg;
                // var arg_list = &self.stack.items[self.stack.items.len - 1].ExprArgList;
                // try arg_list.append(arg);
                if (self.parse_macro) |_| {
                    const val = self.zomb_macro_value_stack.pop().ExprArg;
                    var args = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].ExprArgs;
                    try args.append(val);
                } else {
                    const arg = self.zomb_value_stack.pop().ExprArg;
                    var args = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].ExprArgs;
                    try args.append(arg);
                }
                keep_token = true;
            },
            .MacroExprArgsEnd => if (self.token.?.token_type != .CloseParen) {
                keep_token = true;
            },
        }
        // transition to the next state
        try self.state_machine.transition(self.token.?.token_type);
        // get a new token if necessary - we must do this _after_ the state machine transition
        if (!keep_token) {
            self.token = try self.tokenizer.next();
        }
    }

    //=============
    // Macro Stacks

    fn macroStackTop(self: Self) !*ZombMacroStackType {
        const len = self.zomb_macro_value_stack.items.len;
        if (len == 0) {
            return error.MacroStackEmpty;
        }
        return &self.zomb_macro_value_stack.items[len - 1];
    }

    //================================
    // ZombValue Consumption Functions

    fn stackConsumeKvPair(self: *Self) !void {
        const val = self.zomb_value_stack.pop().Value;
        const key = self.zomb_value_stack.pop().Key;
        var object = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Value.Object;
        try object.put(key, val);
    }

    fn evaluateMacroExpr(self: *Self, alloc_: *std.mem.Allocator, expr_: ZombMacroExpr) !ZombValue {
        const macro = self.macros.get(expr_.key) orelse return error.KeyNotFound;
        var value = try macro.value.toZombValue(alloc_,
            if (macro.params) |p| p.keys() else null,
            if (expr_.args) |a| a.items else null,
            self.macros,
            if (expr_.accessors) |acc| acc.items else null);
        // if (expr_.accessors) |accessors| {
        //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
        //     value = try value.access(accessors.items);
        // }
        return value;
    }

    // TODO: This is for prototyping only -- remove before release
    pub fn log(self: Self) !void {
        if (self.token == null) {
            return;
        }
        self.state_machine.log();
        std.debug.print(
            \\----[Token]----
            \\Token = {} | {s} | {}
        , .{
            if (self.token) |t| t.token_type else .None,
            if (self.token) |t| try t.slice(self.input) else "",
            if (self.token) |t| t.line else 0,
        });
        std.debug.print(
            \\----[Parse Stack]----
            , .{}
        );
        // for (self.stack.items) |stack_elem| {
        //     switch (stack_elem) {
        //         .List => |list| {
        //             for (list) |item| {
        //                 switch (item) {
        //                     .MVal => |m| switch (m) {
        //                         .Object => |obj| {
        //                             // TODO: iterate the object entries and print them out
        //                         },
        //                         .Array => |arr| {
        //                             // TODO: iterate the array items and print them out
        //                         },
        //                         .String => |str|
        //                     },
        //                 }
        //             }
        //         }
        //     }
        // }
        std.debug.print("\n\n", .{});
    }
};

//==============================================================================
//
//
//
// Testing
//==============================================================================

const testing = std.testing;

const StringReader = @import("string_reader.zig").StringReader;
const StringParser = Parser(StringReader, 32);

fn parseTestInput(input_: []const u8) !Zomb {
    var parser = Parser.init(input_, testing.allocator);
    defer parser.deinit();

    return try parser.parse(testing.allocator);
}

fn doZombValueStringTest(expected_: []const u8, actual_: ZombValue) !void {
    switch (actual_) {
        .String => |str| try testing.expectEqualStrings(expected_, str.items),
        else => return error.UnexpectedValue,
    }
}

test "bare string value" {
    const input = "key = value";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("value", entry.value_ptr.*);
}

test "empty quoted string value" {
    const input = "key = \"\"";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("", entry.value_ptr.*);
}

test "quoted string value" {
    const input = "key = \"value\"";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("value", entry.value_ptr.*);
}

test "empty raw string value" {
    const input = "key = \\\\";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("", entry.value_ptr.*);
}

test "one line raw string value" {
    const input = "key = \\\\value";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("value", entry.value_ptr.*);
}

test "two line raw string value" {
    const input =
        \\key = \\one
        \\      \\two
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("one\ntwo", entry.value_ptr.*);
}

test "raw string value with empty newline in the middle" {
    const input =
        \\key = \\one
        \\      \\
        \\      \\two
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("one\n\ntwo", entry.value_ptr.*);
}

test "bare string concatenation" {
    const input = "key = one + two + three";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("onetwothree", entry.value_ptr.*);
}

test "quoted string concatenation" {
    const input =
        \\key = "one " + "two " + "three"
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("one two three", entry.value_ptr.*);
}

test "raw string concatenation" {
    const input =
        \\key = \\part one
        \\      \\
        \\    + \\part two
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("part one\npart two", entry.value_ptr.*);
}

test "general string concatenation" {
    const input =
        \\key = bare_string + "quoted string" + \\raw
        \\                                      \\string
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZombValueStringTest("bare_stringquoted stringraw\nstring", entry.value_ptr.*);
}

test "quoted key" {
    const input =
        \\"quoted key" = value
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("quoted key") orelse return error.KeyNotFound;
    try doZombValueStringTest("value", entry.value_ptr.*);
}

test "empty object value" {
    const input = "key = {}";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            try testing.expectEqual(@as(usize, 0), obj.count());
        },
        else => return error.UnexpectedValue,
    }
}

test "basic object value" {
    const input =
        \\key = {
        \\    a = hello
        \\    b = goodbye
        \\}
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
            try doZombValueStringTest("hello", entry_a.value_ptr.*);

            const entry_b = obj.getEntry("b") orelse return error.KeyNotFound;
            try doZombValueStringTest("goodbye", entry_b.value_ptr.*);
        },
        else => return error.UnexpectedValue,
    }
}

test "nested object value" {
    const input =
        \\key = {
        \\    a = {
        \\        b = value
        \\    }
        \\}
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj_a| {
            const entry_a = obj_a.getEntry("a") orelse return error.KeyNotFound;
            switch (entry_a.value_ptr.*) {
                .Object => |obj_b| {
                    const entry_b = obj_b.getEntry("b") orelse return error.KeyNotFound;
                    try doZombValueStringTest("value", entry_b.value_ptr.*);
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

// TODO: object + object concatenation

test "empty array value" {
    const input = "key = []";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 0), arr.items.len);
        },
        else => return error.UnexpectedValue,
    }
}

test "basic array value" {
    const input = "key = [ a b c ]";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 3), arr.items.len);
            try doZombValueStringTest("a", arr.items[0]);
            try doZombValueStringTest("b", arr.items[1]);
            try doZombValueStringTest("c", arr.items[2]);
        },
        else => return error.UnexpectedValue,
    }
}

test "nested array value" {
    const input =
        \\key = [
        \\    [ a b c ]
        \\]
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 1), arr.items.len);
            switch (arr.items[0]) {
                .Array => |arr_inner| {
                    try testing.expectEqual(@as(usize, 3), arr_inner.items.len);
                    try doZombValueStringTest("a", arr_inner.items[0]);
                    try doZombValueStringTest("b", arr_inner.items[1]);
                    try doZombValueStringTest("c", arr_inner.items[2]);
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

// TODO: array + array concatenation

test "array in an object" {
    const input =
        \\key = {
        \\    a = [ 1 2 3 ]
        \\}
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
            switch (entry_a.value_ptr.*) {
                .Array => |arr| {
                    try testing.expectEqual(@as(usize, 3), arr.items.len);
                    try doZombValueStringTest("1", arr.items[0]);
                    try doZombValueStringTest("2", arr.items[1]);
                    try doZombValueStringTest("3", arr.items[2]);
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

test "object in an array" {
    const input = "key = [ { a = b c = d } ]";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 1), arr.items.len);
            switch (arr.items[0]) {
                .Object => |obj| {
                    const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
                    try doZombValueStringTest("b", entry_a.value_ptr.*);
                    const entry_c = obj.getEntry("c") orelse return error.KeyNotFound;
                    try doZombValueStringTest("d", entry_c.value_ptr.*);
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

test "empty array in object" {
    const input = "key = { a = [] }";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
            switch (entry_a.value_ptr.*) {
                .Array => |arr| try testing.expectEqual(@as(usize, 0), arr.items.len),
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

test "empty object in array" {
    const input = "key = [{}]";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 1), arr.items.len);
            switch (arr.items[0]) {
                .Object => |obj| {
                    try testing.expectEqual(@as(usize, 0), obj.count());
                },
                else => return error.UnexpectedValue,
            }
        },
        else => return error.UnexpectedValue,
    }
}

// TODO: empty Zomb.map

test "macro - bare string value" {
    const input =
        \\$key = hello
        \\hi = $key
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("hello", entry.value_ptr.*);
}

test "macro - object value" {
    const input =
        \\$key = {
        \\    a = hello
        \\}
        \\hi = $key
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const entry_a = obj.getEntry("a") orelse return error.KeyNotFound;
            try doZombValueStringTest("hello", entry_a.value_ptr.*);
        },
        else => return error.UnexpectedValue,
    }
}

test "macro - array value" {
    const input =
        \\$key = [ a b c ]
        \\hi = $key
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Array => |arr| {
            try testing.expectEqual(@as(usize, 3), arr.items.len);
            try doZombValueStringTest("a", arr.items[0]);
            try doZombValueStringTest("b", arr.items[1]);
            try doZombValueStringTest("c", arr.items[2]);
        },
        else => return error.UnexpectedValue,
    }
}

test "macro - one level object accessor" {
    const input =
        \\$key = {
        \\    a = hello
        \\}
        \\hi = $key.a
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("hello", entry.value_ptr.*);
}

test "macro - one level array accessor" {
    const input =
        \\$key = [ hello goodbye okay ]
        \\hi = $key.1
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("goodbye", entry.value_ptr.*);
}

test "macro - object in object accessor" {
    const input =
        \\$key = {
        \\    a = {
        \\        b = hello } }
        \\hi = $key.a.b
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("hello", entry.value_ptr.*);
}

test "macro - array in array accessor" {
    const input =
        \\$key = [ a [ b ] ]
        \\hi = $key.1.0
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZombValueStringTest("b", entry.value_ptr.*);
}

test "macro - macro expression in macro declaration" {
    const input =
        \\$color(alpha, omega) = {
        \\    black = #000000 + %alpha
        \\    red = #ff0000 + %alpha + %omega
        \\}
        \\$colorize(scope, alpha) = {
        \\    scope = %scope
        \\    color = $color(%alpha, $color(X, X).red).black
        \\}
        \\key = $colorize("hello world", 0F)
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    switch (entry.value_ptr.*) {
        .Object => |obj| {
            const scope_entry = obj.getEntry("scope") orelse return error.KeyNotFound;
            try doZombValueStringTest("hello world", scope_entry.value_ptr.*);

            const color_entry = obj.getEntry("color") orelse return error.KeyNotFound;
            try doZombValueStringTest("#0000000F", color_entry.value_ptr.*);
        },
        else => return error.UnexpectedValue,
    }
}

// test "macro batching" {
//     const input =
//         \\$color = {
//         \\    black = #000000
//         \\    red = #ff0000
//         \\}
//         \\$colorize(scope, color, alpha) = {
//         \\    scope = %scope
//         \\    settings = { foreground = %color + %alpha }
//         \\}
//         \\
//         \\tokenColors =
//         \\    $colorize(?, $color.black, ?) % [
//         \\        [ "editor.background" 55 ]
//         \\        [ "editor.border"     66 ]
//         \\    ] +
//         \\    $colorize(?, $color.red, ?) % [
//         \\        [ "editor.foreground"      7f ]
//         \\        [ "editor.highlightBorder" ff ]
//         \\    ]
//     ;
//     const z = try parseTestInput(input);
//     defer z.deinit();
// }
