const std = @import("std");

const Tokenizer = @import("token.zig").Tokenizer;
const TokenType = @import("token.zig").TokenType;
const Token = @import("token.zig").Token;

pub const ZombTypeMap = std.StringArrayHashMap(ZombType);
pub const ZombTypeArray = std.ArrayList(ZombType);

pub const ZombType = union(enum) {
    Object: ZombTypeMap,
    Array: ZombTypeArray,
    String: []const u8,
    Empty: void, // just temporary
};

pub fn copyZombType(alloc_: *std.mem.Allocator, master_: ZombType) !ZombType {
    var copy: ZombType = undefined;
    switch (master_) {
        .Object => |hash_map| {
            copy = ZombType{ .Object = ZombTypeMap.init(alloc_) };
            var iter = hash_map.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                const val_copy = copyZombType(alloc_, val) catch |err| {
                    copy.deinit();
                    return err;
                };
                try copy.put(key, val_copy);
            }
        },
        .Array => |array| {
            copy = ZombType{ .Array = ZombTypeArray.init(alloc_) };
            for (array.items) |val| {
                const val_copy = copyZombType(alloc_, val) catch |err| {
                    copy.deinit();
                    return err;
                };
                try copy.append(val_copy);
            }
        },
        .String => |string| {
            copy = ZombType{ .String = string };
        },
        // .MacroExpr => |id| {
        //     copy = ZombType{ .MacroExpr = id };
        // },
    }
    return copy;
}

pub const ZombMacroExpr = struct {
    pub const Accessor = union(enum) {
        Key: []const u8,
        Index: usize,
    };

    key: []const u8,
    params: ?ZombTypeMap = null, // TODO: can this just be an array list?
    accessors: ?std.ArrayList(Accessor) = null,
};

// pub const ZombMacro = struct {
//     params: ?std.ArrayList([]const u8) = null,
//     param_map: ?std.StringArrayHashMap(std.ArrayLlist(*ZombType)) = null,
//     value: ZombType = undefined,

//     const Self = @This();

//     pub fn getValue(self: *Self, args_: ?ZombTypeMap) !ZombType {
//         if ((self.param_map != null and args_ == null)
//             or (self.param_map == null and args_ != null)
//             or (self.param_map.?.count() != args_.?.count())) {
//             return error.InvalidMacroExprParameters;
//         }
//         var value = try copyZombType(alloc_, self.value);
//         if (args_) |args| {
//             var args_iter = args.iterator();
//             while (args_iter.next()) |entry| {
//                 const arg_key = entry.key_ptr.*;
//                 const arg_value = entry.value_ptr.*;
//                 var zomb_val_ptr_list = self.param_map.?.get(arg_key);
//                 for (zomb_val_ptr_list) |*zomb_val_ptr| {
//                     zomb_val_ptr.* = arg_value;
//                 }
//             }
//         }
//         return self.value;
//     }

//     pub fn reset(self: *Self) void {
//         if (self.param_map) |param_map| {
//             var pmap_iter = param_map.iterator();
//             while (pmap_iter.next()) |entry| {
//                 var zomb_value_ptr_list = entry.value_ptr.*;
//                 for (zomb_val_ptr_list) |*zomb_val_ptr| {
//                     zomb_val_ptr.* = ZombType.PlaceHolder;
//                 }
//             }
//         }
//     }
// };

pub const Zomb = struct {
    arena: std.heap.ArenaAllocator,
    map: ZombType,

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }
};

const StackBits = u128;
const stack_shift = 3;
pub const max_stack_size = @bitSizeOf(StackBits) / stack_shift; // 42 (add more stacks if we need more?)

pub const Parser = struct {
    const Self = @This();

    // stack elements
    //  HEX value combinations ref:
    //                   obj             arr             use             par
    //  obj   0x0 -> obj/obj  0x1 -> obj/arr  0x2 -> obj/use  0x3 -> -------
    //  arr   0x4 -> arr/obj  0x5 -> arr/arr  0x6 -> arr/use  0x7 -> -------
    //  use   0x8 -> -------  0x9 -> -------  0xA -> -------  0xB -> use/par
    //  par   0xC -> par/obj  0xD -> par/arr  0xE -> par/use  0xF -> -------
    const stack_object = 0;
    const stack_array = 1;
    const stack_macro_expr = 2;
    const stack_macro_expr_params = 3;
    const stack_value = 4;

    const State = enum {
        Decl,
        MacroDecl,
        KvPair,
        Object,
        Array,
        MacroExpr,
        MacroExprParams,
        Value,
    };

    const ValType = enum {
        None,
        Unknown,
        String,
        Object,
        Array,
    };

    allocator: *std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    input: []const u8 = undefined,

    tokenizer: Tokenizer,

    state: State = State.Decl,

    // Each state has a set of stages in which they have different expectations of the next token.
    state_stage: u8 = 0,

    // NOTE: the following bit-stack setup is based on zig/lib/std/json.zig
    stack: StackBits = 0,
    stack_size: u8 = 0,

    zomb_type_stack: ZombTypeArray,
    string_val: std.ArrayList(u8),

    val_type: ValType = ValType.None,

    macro_expr_stack: std.ArrayList(ZombMacroExpr), // stack of macro-exprs currently being parsed

    macro_decl: bool = false,

    pub fn init(input_: []const u8, alloc_: *std.mem.Allocator) Self {
        var arena = std.heap.ArenaAllocator.init(alloc_);
        errdefer arena.deinit();
        return Self{
            .allocator = alloc_,
            .arena = arena,
            .input = input_,
            .tokenizer = Tokenizer.init(input_),
            .zomb_type_stack = ZombTypeArray.init(&arena.allocator),
            .string_val = std.ArrayList(u8).init(&arena.allocator),
            .macro_expr_stack = std.ArrayList(ZombMacroExpr).init(&arena.allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn parse(self: *Self) !Zomb {
        var out_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer out_arena.deinit();

        // our stack has an implicit top-level object
        try self.zomb_type_stack.append(ZombType{ .Object = ZombTypeMap.init(&out_arena.allocator) });

        var token = try self.tokenizer.next(); // TODO: consider returning null when at_end_of_buffer == true
        parseloop: while (!self.tokenizer.at_end_of_buffer) {
            // NOTE: we deliberately do not get the next token at the start of this loop in cases where we want to keep
            //       the previous token -- instead, we get the next token at the end of this loop

            // ===--- for prototyping only ---===
            std.log.info(
                \\
                \\State      : {} (stage = {})
                \\Bit Stack  : 0x{X:0>32} (size = {})
                \\Type       : {} (line = {})
                \\Token      : {s}
                \\Stack Len  : {}
                \\Macro Decl : {}
                \\Macro Bits : {}
                \\
                // \\Macro Keys: {s}
                \\
                , .{
                    self.state,
                    self.state_stage,
                    self.stack,
                    self.stack_size,
                    token.token_type,
                    token.line,
                    token.slice(self.input),
                    self.zomb_type_stack.items.len,
                    self.macro_decl,
                    self.bitStackHasMacros(),
                    // self.macros.keys(),
                }
            );
            // ===----------------------------===

            // comments are ignored everywhere - make sure to get the next token as well
            if (token.token_type == TokenType.Comment) {
                token = try self.tokenizer.next();
                continue :parseloop;
            }

            switch (self.state) {
                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     -   MacroKey         >> MacroDecl
                //         String           >> KvPair
                //         else             >> error
                .Decl => {
                    self.state_stage = 0;
                    switch (token.token_type) {
                        .MacroKey => {
                            // TODO: properly implement macro decls
                            self.macro_decl = true;
                            self.state = State.MacroDecl;
                            continue :parseloop; // keep the token
                        },
                        .String => {
                            self.macro_decl = false;
                            self.state = State.KvPair;
                            continue :parseloop; // keep the token
                        },
                        else => return error.UnexpectedDeclToken,
                    }
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   MacroKey         >> 1
                //         else             >> error
                // --------------------------------------------
                //     1   OpenParen        >> 2
                //         Equals           >> Value
                //         else             >> error
                // --------------------------------------------
                //     2   String           >> -
                //         CloseParen       >> 3
                //         else             >> error
                // --------------------------------------------
                //     3   Equals           >> Value
                //         else             >> error
                .MacroDecl => switch (self.state_stage) {
                    0 => switch (token.token_type) {
                        .MacroKey => {
                            // TODO: implement
                            self.state_stage = 1;
                        },
                        else => return error.UnexpectedMacroDeclState0Token,
                    },
                    1 => switch (token.token_type) { // parameters or equals
                        .OpenParen => {
                            // TODO: do paramter list setup
                            self.state_stage = 2;
                        },
                        .Equals => try self.bitStackPush(stack_value),
                        else => return error.UnexpectedMacroDeclStage1Token,
                    },
                    2 => switch (token.token_type) { // parameters
                        .String => {
                            // TODO: process/save this paramter to the paramter list
                        },
                        .CloseParen => self.state_stage = 3,
                        else => return error.UnexpectedMacroDeclStage2Token,
                    },
                    3 => switch (token.token_type) { // equals (after parameters)
                        .Equals => try self.bitStackPush(stack_value),
                        else => return error.UnexpectedMacroDeclStage3Token,
                    },
                    // 4 => switch (token.token_type) { // value
                    //     .String => {
                    //         // const val = try token.slice(self.input);
                    //         // try self.stackConsumeKvPair(ZombType{ .String = val });

                    //         self.state = State.Decl;
                    //     },
                    //     .MacroParamKey => {
                    //         // TODO: this is a macro paramter being used directly as the value - kind of a weird edge
                    //         //       case, but whatever...? need to validate this is actually a paramter of this macro

                    //         // const val = try token.slice(self.input);
                    //         // try self.stackConsumeKvPair(ZombType{ .String = val });

                    //         self.state = State.Decl;
                    //     },
                    //     .MacroKey => {
                    //         try self.bitStackPush(stack_macro_expr);
                    //         continue :parseloop; // keep the token
                    //     },
                    //     .OpenCurly => {
                    //         try self.bitStackPush(stack_object);
                    //         continue :parseloop; // keep the token
                    //     },
                    //     .OpenSquare => {
                    //         try self.bitStackPush(stack_array);
                    //         continue :parseloop; // keep the token
                    //     },
                    //     else => return error.UnexpectedMacroDeclStage4Token,
                    // },
                    else => return error.UnexpectedMacroDeclStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------------
                //     0   String           >> 1
                //         else             >> error
                // --------------------------------------------------
                //     1   Equals           >> Value
                //         else             >> error
                .KvPair => switch (self.state_stage) {
                    0 => switch (token.token_type) { // key
                        .String => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                const key = try token.slice(self.input);
                                try self.zomb_type_stack.append(ZombType{ .String = key });
                            }
                            self.state_stage = 1;
                        },
                        else => return error.UnexpectedKvPairStage0Token,
                    },
                    1 => switch (token.token_type) { // equals
                        .Equals => self.bitStackPush(stack_value),
                        else => return error.UnexpectedKvPairStage1Token,
                    },
                    else => return error.UnexpectedKvPairStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   OpenCurly        >> 1
                //         else             >> error
                // --------------------------------------------
                // pop 1   String           >> KvPair (keep token)
                //         CloseCurly       >> stack or Decl
                //         else             >> error
                .Object => switch (self.state_stage) {
                    0 => switch (token.token_type) {
                        .OpenCurly => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                try self.zomb_type_stack.append(ZombType{ .Object = ZombTypeMap.init(&out_arena.allocator) });
                            }
                            self.state = State.KvPair;
                            self.state_stage = 0;
                        },
                        else => return error.UnexpectedObjectStage0Token,
                    },
                    1 => { // consume kv-pair and check for another
                        if (!self.macro_decl and !self.bitStackHasMacros()) {
                            try self.stackConsumeKvPair(self.zomb_type_stack.pop());
                        }
                        switch (token.token_type) {
                            .String => {
                                self.state = State.KvPair;
                                self.state_stage = 0;
                                continue :parseloop; // keep the token
                            },
                            .CloseCurly => try self.bitStackPop(), // done with this object, consume it in the parent
                            else => return error.UnexpectedObjectStage1Token,
                        }
                    },
                    else => return error.UnexpectedObjectStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   OpenSquare       >> Value
                //         else             >> error
                // --------------------------------------------
                // pop 1   CloseSquare      >> stack or Decl
                //         else             >> Value
                .Array => switch (self.state_stage) {
                    0 => switch (token.token_type) { // open square
                        .OpenSquare => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                try self.zomb_type_stack.append(ZombType{ .Array = ZombTypeArray.init(&out_arena.allocator) });
                            }
                            try self.bitStackPush(stack_value);
                        },
                        else => return error.UnexpectedArrayStage0Token,
                    },
                    1 => { // consume value and check for another
                        if (!self.macro_decl and !self.bitStackHasMacros()) {
                            try self.stackConsumeArrayValue(self.zomb_type_stack.pop());
                        }
                        switch (token.token_type) {
                            .CloseSquare => try self.bitStackPop(), // done with this array, consume it in the parent
                            else => try self.bitStackPush(stack_value), // check for another value
                        }
                    },
                    else => return error.UnexpectedArrayStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   MacroKey         >> 1
                //         else             >> error
                // --------------------------------------------
                // pop 1   MacroAccessor    >> 2 (keep token)
                //         OpenParen        >> MacroExprParams (keep token)
                //         else             >> stack or Decl (keep token)
                // --------------------------------------------
                //     2   MacroAccessor    >> -
                //         else             >> stack or Decl (keep token)
                .MacroExpr => switch (self.state_stage) {
                    0 => switch (token.token_type) { // macro key
                        .MacroKey => {
                            try self.macro_expr_stack.append(ZombMacroExpr{ .key = try token.slice(self.input) });
                            self.state_stage = 1;
                        },
                        else => return error.UnexpectedMacroExprStage0Token,
                    },
                    1 => switch (token.token_type) { // params or accessor
                        .MacroAccessor => {
                            var expr = &self.macro_expr_stack.items[self.macro_expr_stack.items.len - 1];
                            if (expr.*.accessors == null) {
                                expr.*.accessors = std.ArrayList(ZombMacroExpr.Accessor).init(&out_arena.allocator);
                            }
                            self.state_stage = 2;
                            continue :parseloop; // keep the token
                        },
                        .OpenParen => {
                            try self.bitStackPush(stack_macro_expr_params);
                            continue :parseloop; // keep the token
                        },
                        else => {
                            // TODO: evaluate the expression and push the value onto the zomb_type_map
                            try self.bitStackPop();
                            continue :parseloop; // keep the token
                        },
                    },
                    2 => switch (token.token_type) { // accessors
                        .MacroAccessor => {
                            var expr = &self.macro_expr_stack.items[self.macro_expr_stack.items.len - 1];
                            try expr.*.accessors.?.append(ZombMacroExpr.Accessor{ .Key = try token.slice(self.input) });
                        },
                        else => {
                            // TODO: evaluate the expression and push the value onto the zomb_type_map
                            try self.bitStackPop();
                            continue :parseloop; // keep the token
                        },
                    },
                    else => return error.UnexpectedMacroExprStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   OpenParen        >> 1
                //         else             >> error
                // --------------------------------------------
                //     1   String           >> 2
                //         MacroParamKey    >> 2 (only under macro-decl)
                //         MacroKey         >> MacroExpr (keep token)
                //         OpenCurly        >> Object (keep token)
                //         OpenSquare       >> Array (keep token)
                //         else             >> error
                // --------------------------------------------
                // pop 2   String           >> -
                //         MacroParamKey    >> - (only under macro-decl)
                //         MacroKey         >> MacroExpr (keep token)
                //         OpenCurly        >> Object (keep token)
                //         OpenSquare       >> Array (keep token)
                //         CloseParen       >> stack or Decl
                //         else             >> error

                // TODO: how do we handle these?
                .MacroExprParams => switch (self.state_stage) {
                    0 => switch (token.token_type) { // open paren
                        .OpenParen => {
                            // TODO: set up the paramters data structure
                            self.state_stage = 1;
                        },
                        else => return error.UnexpectedMacroExprParamsStage0Token,
                    },
                    1 => switch (token.token_type) { // we require at least one parameter if we're here
                        .String => self.state_stage = 2,
                        .MacroParamKey => {
                            if (!self.macro_decl) {
                                return error.MacroParamKeyUsedOutsideMacroDecl;
                            }
                            self.state_stage = 2;
                        },
                        .MacroKey => {
                            try self.bitStackPush(stack_macro_expr);
                            continue :parseloop;
                        },
                        .OpenCurly => {
                            try self.bitStackPush(stack_object);
                            continue :parseloop;
                        },
                        .OpenSquare => {
                            try self.bitStackPush(stack_array);
                            continue :parseloop;
                        },
                        else => return error.UnexpectedMacroExprParamsStage1Token,
                    },
                    2 => switch (token.token_type) { // more than one parameter
                        .String, => {},
                        .MacroParamKey => {
                            if (!self.macro_decl) {
                                return error.MacroParamKeyUsedOutsideMacroDecl;
                            }
                        },
                        .MacroKey => {
                            try self.bitStackPush(stack_macro_expr);
                            continue :parseloop;
                        },
                        .OpenCurly => {
                            try self.bitStackPush(stack_object);
                            continue :parseloop;
                        },
                        .OpenSquare => {
                            try self.bitStackPush(stack_array);
                            continue :parseloop;
                        },
                        .CloseParen => try self.bitStackPop(),
                        else => return error.UnexpectedMacroExprParamsStage2Token,
                    },
                    else => return error.UnexpectedMacroExprParamsStage,
                },

                // TODO: add state transition table
                .Value => switch(self.state_stage) {
                    0 => switch(token.token_type) { // value
                        .String => {
                            try self.checkValType(ValType.String);
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                try self.string_val.appendSlice(try token.slice(self.input));
                            }
                            self.state_stage = 1;
                        },
                        .MacroParamKey => {
                            if (!self.macro_decl) {
                                return error.MacroParamKeyUsedOutsideMacroDecl;
                            }

                            // TODO ...
                        },
                        .MacroKey => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                try self.stackConsumeKvPair(ZombType.Empty);
                            }
                            try self.bitStackPush(stack_macro_expr);
                            continue :parseloop; // keep the token
                        },
                        .OpenCurly => {
                            try self.checkValType(ValType.Object);
                            try self.bitStackPush(stack_object);
                            continue :parseloop; // keep the token
                        },
                        .OpenSquare => {
                            try self.checkValType(ValType.Array);
                            try self.bitStackPush(stack_array);
                            continue :parseloop; // keep the token
                        },
                        else => return error.UnexpectedValueStage0Token,
                    },
                    1 => switch(token.token_type) { // plus sign OR exit value state
                        .Plus => self.state_stage = 0,
                        else => {
                            if (self.val_type == ValType.String) {
                                try self.zomb_type_stack.append(ZombType{ .String = self.string_val.toOwnedSlice() });
                            }
                            try self.bitStackPop();
                        },
                    },
                    else => return error.UnexpectedValueStage,
                },
            }

            token = try self.tokenizer.next();
        } // end :parseloop

        return Zomb{
            .arena = out_arena,
            .map = self.zomb_type_stack.pop(),
        };
    }

    fn checkValType(self: *Self, val_type_: ValType) !void {
        if (self.val_type == val_type_) return;
        switch (self.val_type) {
            .None => self.val_type = val_type_,
            .Unknown => {},
            else => return error.IncompatibleValueTypeEncountered,
        }
    }

    //===============================
    // ZombType Consumption Functions

    fn stackConsumeKvPair(self: *Self, zomb_type_: ZombType) !void {
        const key = self.zomb_type_stack.pop();
        var object = &self.zomb_type_stack.items[self.zomb_type_stack.items.len - 1].Object;
        try object.put(key.String, zomb_type_);
    }

    fn stackConsumeArrayValue(self: *Self, zomb_type_: ZombType) !void {
        var array = &self.zomb_type_stack.items[self.zomb_type_stack.items.len - 1].Array;
        try array.append(zomb_type_);
    }

    //====================
    // Bit Stack Functions

    fn bitStackPush(self: *Self, stack_type: u3) !void {
        if (self.stack_size > max_stack_size) {
            return error.TooManyBitStackPushes;
        }
        self.stack <<= stack_shift;
        self.stack |= stack_type;
        self.stack_size += 1;
        self.state_stage = 0;
        switch (stack_type) {
            stack_object => self.state = State.Object,
            stack_array => self.state = State.Array,
            stack_macro_expr => self.state = State.MacroExpr,
            stack_macro_expr_params => self.state = State.MacroExprParams,
            stack_value => self.state = State.Value,
            else => return error.UnexpectedStackElement,
        }
    }

    fn bitStackPop(self: *Self) !void {
        if (self.stack_size == 0) {
            return error.TooManyBitStackPops;
        }
        self.stack >>= stack_shift;
        self.stack_size -= 1;
        if (self.stack_size == 0) {
            self.state = State.Decl;
            return;
        }
        self.state_stage = 1;
        switch (self.stack & 0b111) {
            stack_object => self.state = State.Object,
            stack_array => self.state = State.Array,
            stack_macro_expr => self.state = State.MacroExpr,
            stack_macro_expr_params => {
                self.state = State.MacroExprParams;
                self.state_stage = 2;
            },
            stack_value => {
                self.state = State.Value;
                self.state_stage = 0;
            },
            else => return error.UnexpectedStackElement,
        }
    }

    fn bitStackPeek(self: Self) ?u3 {
        if (self.stack_size == 0) {
            return null;
        }
        return @intCast(u2, self.stack & 0b111);
    }

    fn bitStackHasMacros(self: Self) bool {
        return (self.stack & 0x2222_2222_2222_2222_2222_2222_2222_2222) > 0;
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
