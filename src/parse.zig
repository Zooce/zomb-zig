const std = @import("std");

const util = @import("util.zig");

const Tokenizer = @import("token.zig").Tokenizer;
const Token = @import("token.zig").Token;
const StateMachine = @import("state_machine.zig").StateMachine;

const ZValue = @import("data.zig").ZValue;
const ZExpr = @import("data.zig").ZExpr;
const ZExprArg = @import("data.zig").ZExprArg;
const ConcatItem = @import("data.zig").ConcatItem;
const ConcatList = @import("data.zig").ConcatList;
const ZMacro = @import("data.zig").ZMacro;
const StackElem = @import("data.zig").StackElem;
const reduce = @import("data.zig").reduce;

const MacroValidator = struct {
    const Self = @This();

    current_param: ?[]const u8 = null,
    param_counts: ?std.StringArrayHashMap(usize) = null,

    pub fn deinit(self: *Self) void {
        if (self.param_counts) |*counts| {
            counts.deinit();
        }
        self.param_counts = null;
    }

    pub fn validate(self: Self) !void {
        if (self.param_counts) |param_counts| {
            var iter = param_counts.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* == 0) {
                    return error.UnusedMacroParamter;
                }
            }
        }
    }
};

pub const Zomb = struct {
    arena: std.heap.ArenaAllocator,
    map: std.StringArrayHashMap(ZValue),

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
    stack: std.ArrayList(StackElem) = undefined,
    macro_validator: ?MacroValidator = null,
    macros: std.StringArrayHashMap(ZMacro) = undefined,
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

    fn consumeAtTopLevel(self: *Self, allocator_: *std.mem.Allocator) !void {
        if (self.macro_validator) |*macro_validator| {
            // std.debug.print("...consuming macro declaration...\n", .{});
            defer macro_validator.deinit();
            try macro_validator.validate();
            const c_list = self.stack.pop().CList;
            const params = self.stack.pop().ParamMap;
            const key = self.stack.pop().Key;
            try self.macros.putNoClobber(key, .{ .parameters = params, .value = c_list });
        }
        if (self.stack.items.len > 1) {
            // std.debug.print("...consuming top-level object...\n", .{});
            const c_list = self.stack.pop().CList;
            defer c_list.deinit();
            const key = self.stack.pop().Key;
            var top_level_obj = &self.stack.items[self.stack.items.len - 1].TopLevelObject;
            var value: ZValue = undefined;
            _ = try reduce(allocator_, c_list, &value, true, null, .{ .macros = self.macros });
            try top_level_obj.putNoClobber(key, value);
        }
    }

    pub fn parse(self: *Self, allocator_: *std.mem.Allocator) !Zomb {
        // initialize some temporary memory we need for parsing
        self.stack = std.ArrayList(StackElem).init(&self.arena.allocator);
        self.macros = std.StringArrayHashMap(ZMacro).init(&self.arena.allocator);

        // this arena will be given to the caller so they can clean up the memory we allocate for the ZOMB types
        var out_arena = std.heap.ArenaAllocator.init(allocator_);
        errdefer out_arena.deinit();

        // add the implicit top-level object to our type stack
        try self.stack.append(.{ .TopLevelObject = std.StringArrayHashMap(ZValue).init(&out_arena.allocator) });

        errdefer {
            if (self.token) |token| {
                std.debug.print("Last Token = {}\n", .{token});
            }
        }

        var count: usize = 0;
        var done = false;
        while (!done) {
            count += 1;
            try self.log(count, "Pre-Step");
            try self.step();
            if (self.state_machine.state == .Decl) {
                try self.log(count, "Pre-Decl Consume");
                try self.consumeAtTopLevel(&out_arena.allocator);
            }
            done = self.token == null and self.stack.items.len == 1;
        }

        return Zomb{
            .arena = out_arena,
            .map = self.stack.pop().TopLevelObject,
        };
    }

    /// Process the current token based on the current state, transition to the
    /// next state, and update the current token if necessary.
    pub fn step(self: *Self) !void {
        if (self.token == null) {
            self.token = try self.tokenizer.next();
        }
        // comments are ignored everywhere - make sure to get the next token as well
        if (self.token != null and self.token.?.token_type == .Comment) {
            self.token = try self.tokenizer.next();
            return;
        }

        // states where stack consumption occurs do not need a token, and in the case that we're at
        // the end of the file, this processing still needs to be handled, so we do so now
        switch (self.state_machine.state) {
            .ValueConcat => {
                // consume the value we just parsed
                const c_item = self.stack.pop().CItem;
                var c_list = &self.stack.items[self.stack.items.len - 1].CList;
                try c_list.*.append(c_item);
            },
            .ConsumeObjectEntry => {
                const c_list = self.stack.pop().CList;
                errdefer c_list.deinit();
                const key = self.stack.pop().Key;
                var obj = &self.stack.items[self.stack.items.len - 1].CItem.Object;
                try obj.*.putNoClobber(key, c_list);
            },
            .ConsumeArrayItem => {
                const c_list = self.stack.pop().CList;
                errdefer c_list.deinit();
                var arr = &self.stack.items[self.stack.items.len - 1].CItem.Array;
                try arr.*.append(c_list);
            },
            .ConsumeMacroDeclParam => {
                const param = self.stack.pop().MacroDeclParam;
                var param_map = &self.stack.items[self.stack.items.len - 1].ParamMap;
                try param_map.*.?.putNoClobber(param, null);
            },
            .ConsumeMacroDeclDefaultParam => {
                const param_default = self.stack.pop().CList;
                const param = self.stack.pop().MacroDeclParam;
                var param_map = &self.stack.items[self.stack.items.len - 1].ParamMap;
                try param_map.*.?.putNoClobber(param, param_default);
            },
            .ConsumeMacroExprArgsOrBatchList => {
                const top = self.stack.pop();
                var expr = &self.stack.items[self.stack.items.len - 1].CItem.Expression;
                switch (top) {
                    .ExprArgList => |expr_arg_list| {
                        defer expr_arg_list.deinit();
                        try expr.*.setArgs(&self.arena.allocator, expr_arg_list, self.macros);
                    },
                    .BSet => |batch_set| {
                        expr.*.batch_args_list = batch_set;
                    },
                    else => return error.UnexpectedStackElemDuringMacroExprArgsOrBatchListConsumption,
                }
            },
            .ConsumeMacroExprBatchArgsList => {
                const batch = self.stack.pop().BSet;
                var expr = &self.stack.items[self.stack.items.len - 1].CItem.Expression;
                expr.*.batch_args_list = batch;
            },
            .ConsumeMacroExprArg => {
                const arg = self.stack.pop();
                var expr_args = &self.stack.items[self.stack.items.len - 1].ExprArgList;
                switch (arg) {
                    .CList => |c_list| {
                        errdefer c_list.deinit();
                        try expr_args.*.append(.{ .CList = c_list });
                    },
                    .Placeholder => try expr_args.*.append(.BatchPlaceholder),
                    else => return error.UnexpectedStackElemDuringMacroExprArgConsumption,
                }
            },
            .ConsumeMacroExprBatchArgs => {
                const batch_args = self.stack.pop().CItem.Array;
                var batch = &self.stack.items[self.stack.items.len - 1].BSet;
                try batch.*.append(batch_args);
            },
            else => {},
        }

        // to continue on, we must have a token
        if (self.token == null) {
            try self.state_machine.transition(.None);
            return;
        }

        // get the token slice for convenience
        const token_slice = try self.token.?.slice(self.input);
        var keep_token = false;
        // process the current token based on our current state
        switch (self.state_machine.state) {
            .Decl => {
                self.macro_validator = null;
                keep_token = true;
            },
            .Equals => {}, // handled in .ValueEnter
            .ValueEnter => {
                // don't add the CList for an empty array or a batch placeholder
                if (self.token.?.token_type != .CloseSquare and self.token.?.token_type != .Question) {
                    try self.stack.append(.{ .CList = ConcatList.init(&self.arena.allocator) });
                }
                keep_token = true;
            },
            .Value => {
                switch (self.token.?.token_type) {
                    .String, .RawString => try self.stack.append(.{ .CItem = .{ .String = token_slice } }),
                    .MacroParamKey => {
                        if (self.macro_validator) |*macro_validator| {
                            if (macro_validator.current_param != null) {
                                return error.UseOfParameterAsDefaultValue;
                            }
                            if (macro_validator.param_counts.?.getPtr(token_slice)) |p| {
                                p.* += 1; // count the usage of this parameter
                            } else {
                                return error.InvalidParameterUse;
                            }
                            try self.stack.append(.{ .CItem = .{ .Parameter = token_slice } });
                        } else {
                            return error.MacroParamKeyUsedOutsideMacroDecl;
                        }
                    },
                    .Question => try self.stack.append(.Placeholder),
                    .MacroKey, .OpenCurly, .OpenSquare, .CloseSquare => keep_token = true,
                    else => {},
                }
            },
            .ValueConcat => if (self.token.?.token_type != .Plus) {
                keep_token = true;
            },

            // Objects
            .ObjectBegin => {
                try self.stack.append(.{ .CItem = .{ .Object = std.StringArrayHashMap(ConcatList).init(&self.arena.allocator) } });
            },
            .Key => switch (self.token.?.token_type) {
                .String => try self.stack.append(.{ .Key = token_slice }),
                else => keep_token = true,
            },
            .ConsumeObjectEntry => keep_token = true,
            .ObjectEnd => if (self.token.?.token_type == .String) {
                keep_token = true;
            },

            // Arrays
            .ArrayBegin => {
                try self.stack.append(.{ .CItem = .{ .Array = std.ArrayList(ConcatList).init(&self.arena.allocator) } });
            },
            .ConsumeArrayItem => {
                keep_token = true;
            },
            .ArrayEnd => if (self.token.?.token_type != .CloseSquare) {
                keep_token = true;
            },

            // Macro Declaration
            .MacroDeclKey => {
                if (self.macros.contains(token_slice)) {
                    return error.DuplicateMacroName;
                }
                try self.stack.append(.{ .Key =  token_slice });
                self.macro_validator = MacroValidator{};
            },
            .MacroDeclOptionalParams => switch (self.token.?.token_type) {
                .OpenParen => {
                    try self.stack.append(.{ .ParamMap = std.StringArrayHashMap(?ConcatList).init(&self.arena.allocator) });
                    self.macro_validator.?.param_counts = std.StringArrayHashMap(usize).init(&self.arena.allocator);
                },
                else => try self.stack.append(.{ .ParamMap = null }),
            },
            .MacroDeclParam => switch (self.token.?.token_type) {
                .String => {
                    try self.stack.append(.{ .MacroDeclParam = token_slice });
                    try self.macro_validator.?.param_counts.?.putNoClobber(token_slice, 0);
                    self.macro_validator.?.current_param = token_slice;
                },
                .CloseParen => keep_token = true,
                else => {},
            },
            .MacroDeclParamOptionalDefaultValue => switch (self.token.?.token_type) {
                .String, .CloseParen => {
                    self.macro_validator.?.current_param = null;
                    keep_token = true;
                },
                else => {},
            },
            .ConsumeMacroDeclParam, .ConsumeMacroDeclDefaultParam => keep_token = true,
            .MacroDeclParamsEnd => {
                self.macro_validator.?.current_param = null;
                if (self.token.?.token_type == .CloseParen) {
                    if (self.macro_validator.?.param_counts.?.count() == 0) {
                        return error.EmptyMacroDeclParams;
                    }
                }
            },

            // Macro Expression
            .MacroExprKey => {
                if (!self.macros.contains(token_slice)) {
                    return error.MacroNotYetDeclared;
                }
                try self.stack.append(.{ .CItem = .{ .Expression = .{ .key = token_slice } } });
            },
            .MacroExprOptionalArgsOrAccessors, .MacroExprOptionalAccessors => {
                if (self.token.?.token_type == .MacroAccessor) {
                    var expr = &self.stack.items[self.stack.items.len - 1].CItem.Expression;
                    expr.*.accessors = std.ArrayList([]const u8).init(&self.arena.allocator);
                }
                keep_token = true;
            },
            .ConsumeMacroExprArgsOrBatchList => {
                keep_token = true;
            },
            .MacroExprAccessors => switch (self.token.?.token_type) {
                .MacroAccessor => {
                    var expr = &self.stack.items[self.stack.items.len - 1].CItem.Expression;
                    try expr.*.accessors.?.append(token_slice);
                },
                else => keep_token = true,
            },
            .MacroExprOptionalBatch => if (self.token.?.token_type != .Percent) {
                keep_token = true;
            },
            .ConsumeMacroExprBatchArgsList => {
                keep_token = true;
            },

            // Macro Expression Arguments
            .MacroExprArgsBegin => {
                try self.stack.append(.{ .ExprArgList = std.ArrayList(ZExprArg).init(&self.arena.allocator) });
            },
            .ConsumeMacroExprArg => {
                keep_token = true;
            },
            .MacroExprArgsEnd => if (self.token.?.token_type != .CloseParen) {
                keep_token = true;
            },

            // Macro Expression Batch Arguments
            .MacroExprBatchListBegin => {
                try self.stack.append(.{ .BSet = std.ArrayList(std.ArrayList(ConcatList)).init(&self.arena.allocator) });
            },
            .MacroExprBatchArgsBegin => keep_token = true,
            .ConsumeMacroExprBatchArgs => {
                keep_token = true;
            },
            .MacroExprBatchListEnd => if (self.token.?.token_type != .CloseSquare) {
                keep_token = true;
            },
        }
        // transition to the next state
        try self.state_machine.transition(self.token.?.token_type);
        // get a new token if necessary - we must do this _after_ the state machine transition
        if (!keep_token) {
            if (util.DEBUG) std.debug.print("getting new token...\n", .{});
            self.token = try self.tokenizer.next();
        }
    }

    // TODO: This is for prototyping only -- remove before release
    pub fn log(self: Self, count_: usize, tag_: []const u8) !void {
        if (!util.DEBUG) return;
        const held = std.debug.getStderrMutex().acquire();
        defer held.release();
        const stderr = std.io.getStdErr().writer();
        try stderr.print(
            \\
            \\=====[[ {s} {} ]]=====
            \\
            , .{ tag_, count_ }
        );
        if (self.token) |token| {
            try token.log(stderr, self.input);
        } else {
            try stderr.writeAll("----[Token]----\nnull\n");
        }
        // try self.tokenizer.log(stderr);
        try self.state_machine.log(stderr);

        try stderr.writeAll("----[Macros]----\n");
        var iter = self.macros.iterator();
        while (iter.next()) |entry| {
            try stderr.print("{s} = {struct}", .{entry.key_ptr.*, entry.value_ptr.*});
        }

        try stderr.writeAll("----[Parse Stack]----\n");
        for (self.stack.items) |stack_elem| {
            try stderr.print("{union}", .{stack_elem});
        }

        try stderr.writeAll("\n");
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
    if (util.DEBUG) {
        std.debug.print(
            \\
            \\----[Test Input]----
            \\{s}
            \\
            , .{ input_ }
        );
    }
    var parser = Parser.init(input_, testing.allocator);
    defer parser.deinit();

    return try parser.parse(testing.allocator);
}

fn doZValueStringTest(expected_: []const u8, actual_: ZValue) !void {
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
    try doZValueStringTest("value", entry.value_ptr.*);
}

test "empty quoted string value" {
    const input = "key = \"\"";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZValueStringTest("", entry.value_ptr.*);
}

test "quoted string value" {
    const input = "key = \"value\"";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZValueStringTest("value", entry.value_ptr.*);
}

test "empty raw string value" {
    const input = "key = \\\\";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZValueStringTest("", entry.value_ptr.*);
}

test "one line raw string value" {
    const input = "key = \\\\value";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZValueStringTest("value", entry.value_ptr.*);
}

test "two line raw string value" {
    const input =
        \\key = \\one
        \\      \\two
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZValueStringTest("one\ntwo", entry.value_ptr.*);
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
    try doZValueStringTest("one\n\ntwo", entry.value_ptr.*);
}

test "bare string concatenation" {
    const input = "key = one + two + three";
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZValueStringTest("onetwothree", entry.value_ptr.*);
}

test "quoted string concatenation" {
    const input =
        \\key = "one " + "two " + "three"
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZValueStringTest("one two three", entry.value_ptr.*);
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
    try doZValueStringTest("part one\npart two", entry.value_ptr.*);
}

test "general string concatenation" {
    const input =
        \\key = bare_string + "quoted string" + \\raw
        \\                                      \\string
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("key") orelse return error.KeyNotFound;
    try doZValueStringTest("bare_stringquoted stringraw\nstring", entry.value_ptr.*);
}

test "quoted key" {
    const input =
        \\"quoted key" = value
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("quoted key") orelse return error.KeyNotFound;
    try doZValueStringTest("value", entry.value_ptr.*);
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
            try doZValueStringTest("hello", entry_a.value_ptr.*);

            const entry_b = obj.getEntry("b") orelse return error.KeyNotFound;
            try doZValueStringTest("goodbye", entry_b.value_ptr.*);
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
                    try doZValueStringTest("value", entry_b.value_ptr.*);
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
            try doZValueStringTest("a", arr.items[0]);
            try doZValueStringTest("b", arr.items[1]);
            try doZValueStringTest("c", arr.items[2]);
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
                    try doZValueStringTest("a", arr_inner.items[0]);
                    try doZValueStringTest("b", arr_inner.items[1]);
                    try doZValueStringTest("c", arr_inner.items[2]);
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
                    try doZValueStringTest("1", arr.items[0]);
                    try doZValueStringTest("2", arr.items[1]);
                    try doZValueStringTest("3", arr.items[2]);
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
                    try doZValueStringTest("b", entry_a.value_ptr.*);
                    const entry_c = obj.getEntry("c") orelse return error.KeyNotFound;
                    try doZValueStringTest("d", entry_c.value_ptr.*);
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
    try doZValueStringTest("hello", entry.value_ptr.*);
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
            try doZValueStringTest("hello", entry_a.value_ptr.*);
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
            try doZValueStringTest("a", arr.items[0]);
            try doZValueStringTest("b", arr.items[1]);
            try doZValueStringTest("c", arr.items[2]);
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
    try doZValueStringTest("hello", entry.value_ptr.*);
}

test "macro - one level array accessor" {
    const input =
        \\$key = [ hello goodbye okay ]
        \\hi = $key.1
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZValueStringTest("goodbye", entry.value_ptr.*);
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
    try doZValueStringTest("hello", entry.value_ptr.*);
}

test "macro - array in array accessor" {
    const input =
        \\$key = [ a [ b ] ]
        \\hi = $key.1.0
    ;
    const z = try parseTestInput(input);
    defer z.deinit();

    const entry = z.map.getEntry("hi") orelse return error.KeyNotFound;
    try doZValueStringTest("b", entry.value_ptr.*);
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
            try doZValueStringTest("hello world", scope_entry.value_ptr.*);

            const color_entry = obj.getEntry("color") orelse return error.KeyNotFound;
            try doZValueStringTest("#0000000F", color_entry.value_ptr.*);
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
