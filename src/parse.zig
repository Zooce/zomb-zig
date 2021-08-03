const std = @import("std");

const Tokenizer = @import("token.zig").Tokenizer;
const TokenType = @import("token.zig").TokenType;
const Token = @import("token.zig").Token;

pub const ZombTypeMap = std.StringArrayHashMap(ZombType);
pub const ZombTypeArray = std.ArrayList(ZombType);

pub const ZombType = union(enum) {
    Object: ZombTypeMap,
    Array: ZombTypeArray,
    String: std.ArrayList(u8),
    Empty: void, // just temporary
};

const ZombStackType = union(enum) {
    Element: ZombType,
    Key: []const u8,
};


const ZombMacroTypeMap = std.StringArrayHashMap(ZombMacroType);
const ZombMacroTypeArray = std.ArrayList(ZombMacroType);

const ZombMacroObjectValue = union(enum) {
    Object: ZombMacroTypeMap,
    Parameter: []const u8,
};
const ZombMacroArrayValue = union(enum) {
    Array: ZombMacroTypeArray,
    Parameter: []const u8,
};
const ZombMacroStringValue = union(enum) {
    String: []const u8,
    Parameter: []const u8,
};

const ZombMacroType = union(enum) {
    ObjectList: std.ArrayList(ZombMacroObjectValue),
    ArrayList: std.ArrayList(ZombMacroArrayValue),
    StringList: std.ArrayList(ZombMacroStringValue),

    /// This should be converted to one of the types above upon parsing the first
    /// non-Parameter type.
    ParameterList: std.ArrayList([]const u8),
};

const ZombMacroStackType = union(enum) {
    List: ZombMacroType,
    Object: ZombMacroObjectValue,
    Array: ZombMacroArrayValue,
    Key: []const u8,
    Empty: void, // the starting element -- for parsing
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

pub const ZombMacro = struct {
    /// This map is used to count the number of parameter uses in the macro value. After the macro
    /// has been fully parsed, we check to make sure each entry is greater than zero.
    params: ?std.StringArrayHashMap(u32) = null,

    /// The actual value of this macro.
    value: ZombMacroType = undefined,

    /// A list of macro expression keys used inside this macro. Used for detecting recursion.
    macro_exprs: ?std.ArrayList([]const u8) = null,
};

pub const Zomb = struct {
    arena: std.heap.ArenaAllocator,
    map: ZombType,

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }
};

const StackBits = u128;
const stack_shift = 4;
pub const max_stack_size = @bitSizeOf(StackBits) / stack_shift; // add more stacks if we need more?

pub const Parser = struct {
    const Self = @This();

    // stack elements
    const stack_object = 0;
    const stack_array = 1;
    const stack_macro_expr = 2;
    const stack_macro_expr_params = 3;
    const stack_value = 4;

    const val_type_object = 0;
    const val_type_array = 1;
    const val_type_string = 2;

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

    arena: std.heap.ArenaAllocator,

    input: []const u8 = undefined,

    tokenizer: Tokenizer,

    state: State = State.Decl,

    // Each state has a set of stages in which they have different expectations of the next token.
    state_stage: u8 = 0,

    // NOTE: the following bit-stack setup is based on zig/lib/std/json.zig
    stack: StackBits = 0,
    stack_size: u8 = 0,

    val_type_stack: StackBits = 0,
    val_type_stack_size: u8 = 0,

    zomb_type_stack: std.ArrayList(ZombStackType) = undefined,

    macro_ptr: ?*ZombMacro = null,
    zomb_macro_type_stack: std.ArrayList(ZombMacroStackType) = undefined,
    macro_map: std.StringArrayHashMap(ZombMacro) = undefined,
    macro_expr_stack: std.ArrayList(ZombMacroExpr) = undefined, // stack of macro-exprs currently being parsed

    macro_expr_ptr: ?*ZombMacroExpr = null,

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
        self.zomb_type_stack = std.ArrayList(ZombStackType).init(&self.arena.allocator);
        self.zomb_macro_type_stack = std.ArrayList(ZombMacroStackType).init(&self.arena.allocator);
        self.macro_map = std.StringArrayHashMap(ZombMacro).init(&self.arena.allocator);
        self.macro_expr_stack = std.ArrayList(ZombMacroExpr).init(&self.arena.allocator);

        var out_arena = std.heap.ArenaAllocator.init(allocator_);
        errdefer out_arena.deinit();

        // our stack has an implicit top-level object
        try self.zomb_type_stack.append(.{ .Element = .{ .Object = ZombTypeMap.init(&out_arena.allocator) } });

        // our macro stack always has an empty first element
        try self.zomb_macro_type_stack.append(ZombMacroStackType.Empty);

        var next_token = try self.tokenizer.next(); // TODO: consider returning null when at_end_of_buffer == true
        parseloop: while (next_token) |token| {
            // NOTE: we deliberately do not get the next token at the start of this loop in cases where we want to keep
            //       the previous token -- instead, we get the next token at the end of this loop

            // ===--- for prototyping only ---===
            std.log.info(
                \\
                \\State       : {} (stage = {})
                \\State Stack : 0x{X:0>32} (size = {})
                \\Type        : {} (line = {})
                \\Token       : {s}
                \\Stack Len   : {}
                // \\Macro Decl  : {}
                // \\Macro Bits  : {}
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
                    // self.macro_decl,
                    // self.stateStackHasMacros(),
                    // self.macros.keys(),
                }
            );
            // ===----------------------------===

            // comments are ignored everywhere - make sure to get the next token as well
            if (token.token_type == TokenType.Comment) {
                next_token = try self.tokenizer.next();
                continue :parseloop;
            }

            switch (self.state) {
                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     -   MacroKey         >> MacroDecl
                //         String           >> KvPair
                //         else             >> error
                .Decl => {
                    if (self.macro_ptr) |macro_ptr| {
                        macro_ptr.*.value = self.zomb_macro_type_stack.pop().List;
                        if (macro_ptr.*.params) |params| {
                            var iter = params.iterator();
                            while (iter.next()) |entry| {
                                if (entry.value_ptr.* == 0) {
                                    // TODO: log which parameter was not used
                                    return error.UnusedMacroParameter;
                                }
                            }
                        }
                    } else if (self.zomb_type_stack.items.len > 1) {
                        try self.stackConsumeKvPair();
                    }
                    self.state_stage = 0;
                    self.macro_ptr = null;
                    switch (token.token_type) {
                        .MacroKey => {
                            self.state = State.MacroDecl;
                            continue :parseloop; // keep the token
                        },
                        .String => {
                            self.state = State.KvPair;
                            continue :parseloop; // keep the token
                        },
                        else => return error.UnexpectedDeclToken,
                    }
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
                            const key = .{ .Key = try token.slice(self.input) };
                            if (self.macro_ptr) |_| {
                                try self.zomb_macro_type_stack.append(key);
                            } else {
                                try self.zomb_type_stack.append(key);
                            }
                            self.state_stage = 1;
                        },
                        else => return error.UnexpectedKvPairStage0Token,
                    },
                    1 => switch (token.token_type) { // equals
                        .Equals => try self.stateStackPush(stack_value),
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
                            if (self.macro_ptr) |_| {
                                try self.zomb_macro_type_stack.append(.{ .Object = .{ .Object = ZombMacroTypeMap.init(&self.arena.allocator) } });
                            } else {
                                try self.zomb_type_stack.append(.{ .Element = .{ .Object = ZombTypeMap.init(&out_arena.allocator) } });
                            }
                            self.state = State.KvPair;
                            self.state_stage = 0;
                        },
                        else => return error.UnexpectedObjectStage0Token,
                    },
                    1 => { // consume kv-pair and check for another
                        if (self.macro_ptr) |_| {
                            try self.stackConsumeMacroKvPair();
                        } else {
                            try self.stackConsumeKvPair();
                        }
                        switch (token.token_type) {
                            .String => {
                                self.state = State.KvPair;
                                self.state_stage = 0;
                                continue :parseloop; // keep the token
                            },
                            .CloseCurly => {
                                if (self.macro_ptr) |_| {
                                    const object = self.zomb_macro_type_stack.pop().Object;
                                    if (self.macroStackTop()) |stack_type| {
                                        try stack_type.List.ObjectList.append(object);
                                    } else {
                                        return error.MacroStackEmpty;
                                    }
                                }
                                try self.stateStackPop(); // done with this object, consume it in the parent
                            },
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
                            if (self.macro_ptr) |_| {
                                try self.zomb_macro_type_stack.append(.{ .Array = .{ .Array = ZombMacroTypeArray.init(&self.arena.allocator) } });
                            } else {
                                try self.zomb_type_stack.append(.{ .Element = .{ .Array = ZombTypeArray.init(&out_arena.allocator) } });
                            }
                            try self.stateStackPush(stack_value);
                        },
                        else => return error.UnexpectedArrayStage0Token,
                    },
                    1 => { // consume value and check for another
                        if (self.macro_ptr) |_| {
                            try self.stackConsumeMacroArrayValue();
                        } else {
                            try self.stackConsumeArrayValue();
                        }
                        switch (token.token_type) {
                            .CloseSquare => {
                                if (self.macro_ptr) |_| {
                                    const array = self.zomb_macro_type_stack.pop().Array;
                                    if (self.macroStackTop()) |stack_type| {
                                        try stack_type.List.ArrayList.append(array);
                                    } else {
                                        return error.MacroStackEmpty;
                                    }
                                }
                                try self.stateStackPop(); // done with this array, consume it in the parent
                            },
                            else => try self.stateStackPush(stack_value), // check for another value
                        }
                    },
                    else => return error.UnexpectedArrayStage,
                },

                // TODO: add state transition table
                .Value => switch(self.state_stage) {
                    0 => switch(token.token_type) { // value
                        .String, .RawString => {
                            const string_slice = try token.slice(self.input);
                            if (self.macro_ptr) |_| {
                                // top of the stack should be a String
                                var top = self.macroStackTop() orelse return error.MacroStackEmpty;
                                switch (top.*) {
                                    .List => |*list| switch (list.*) {
                                        .StringList => |*strings| try strings.append(.{ .String = string_slice }),
                                        .ParameterList => |params| {
                                            var string_list = .{ .StringList = std.ArrayList(ZombMacroStringValue).init(&self.arena.allocator) };
                                            for (params.items) |p| try string_list.StringList.append(.{ .Parameter = p });
                                            var param_list = self.zomb_macro_type_stack.pop();
                                            param_list.List.ParameterList.deinit();
                                            try self.zomb_macro_type_stack.append(.{ .List = string_list });
                                        },
                                        else => return error.UnexpectedStringValueMacroStackType,
                                    },
                                    .Key, .Array, .Empty => {
                                        try self.zomb_macro_type_stack.append(.{ .List =
                                            .{ .StringList = std.ArrayList(ZombMacroStringValue).init(&self.arena.allocator) }
                                        });
                                        continue :parseloop; // keep the token
                                    },
                                    else => return error.UnexpectedStringValueMacroStackType,
                                }
                            } else {
                                var top = &self.zomb_type_stack.items[self.zomb_type_stack.items.len - 1];
                                switch (top.*) {
                                    .Element => |*elem| switch (elem.*) {
                                        .String => |*str| try str.appendSlice(string_slice),
                                        else => return error.UnexpectedStackElement,
                                    },
                                    .Key => {
                                        try self.zomb_type_stack.append(.{ .Element = .{ .String = std.ArrayList(u8).init(&out_arena.allocator) } });
                                        continue :parseloop; // keep the token
                                    },
                                }
                            }
                            self.state_stage = 1;
                        },
                        .MacroParamKey => {
                            if (self.macro_ptr) |macro_ptr| {
                                const parameter = try token.slice(self.input);
                                if (macro_ptr.*.params) |params| {
                                    if (params.getPtr(parameter)) |p| {
                                        p.* += 1;
                                    } else {
                                        return error.InvalidParameterUse;
                                    }
                                }
                                var top = self.macroStackTop() orelse return error.MacroStackEmpty;
                                switch (top.*) {
                                    .List => |*list| switch (list.*) { // TODO: this might need some work -- I think there's a bug here...
                                        .ObjectList => |*objects| try objects.append(.{ .Parameter = parameter }),
                                        .ArrayList => |*arrays| try arrays.append(.{ .Parameter = parameter }),
                                        .StringList => |*strings| try strings.append(.{ .Parameter = parameter }),
                                        .ParameterList => |*params| try params.append(parameter),
                                    },
                                    .Key, .Array, .Empty => {
                                        try self.zomb_macro_type_stack.append(.{ .List =
                                            .{ .ParameterList = std.ArrayList([]const u8).init(&self.arena.allocator) }
                                        });
                                        continue :parseloop; // keep the token
                                    },
                                    else => return error.UnexpectedMacroParamKeyValueMacroStackType,
                                }
                            } else {
                                return error.MacroParamKeyUsedOutsideMacroDecl;
                            }
                            self.state_stage = 1;
                        },
                        .MacroKey => {
                            try self.stateStackPush(stack_macro_expr);
                            continue :parseloop; // keep the token
                        },
                        .OpenCurly => {
                            if (self.macro_ptr) |_| {
                                var top = self.macroStackTop() orelse return error.MacroStackEmpty;
                                switch (top.*) {
                                    .List => |list_type| switch (list_type) {
                                        .ObjectList => {},
                                        .ParameterList => |params| {
                                            var object_list = .{ .ObjectList = std.ArrayList(ZombMacroObjectValue).init(&self.arena.allocator) };
                                            for (params.items) |p| try object_list.ObjectList.append(.{ .Parameter = p });
                                            var param_list = self.zomb_macro_type_stack.pop();
                                            param_list.List.ParameterList.deinit();
                                            try self.zomb_macro_type_stack.append(.{ .List = object_list });
                                        },
                                        else => return error.UnexpectedMacroStackList,
                                    },
                                    .Key, .Array, .Empty => {
                                        try self.zomb_macro_type_stack.append(.{ .List =
                                            .{ .ObjectList = std.ArrayList(ZombMacroObjectValue).init(&self.arena.allocator) }
                                        });
                                    },
                                    else => return error.UnexpectedMacroStackTop,
                                }
                            }
                            try self.stateStackPush(stack_object);
                            continue :parseloop; // keep the token
                        },
                        .OpenSquare => {
                            if (self.macro_ptr) |_| {
                                var top = self.macroStackTop() orelse return error.MacroStackEmpty;
                                switch (top.*) {
                                    .List => |list_type| switch (list_type) {
                                        .ArrayList => {},
                                        .ParameterList => |params| {
                                            var array_list = .{ .ArrayList = std.ArrayList(ZombMacroArrayValue).init(&self.arena.allocator) };
                                            for (params.items) |p| try array_list.ArrayList.append(.{ .Parameter = p });
                                            var param_list = self.zomb_macro_type_stack.pop();
                                            param_list.List.ParameterList.deinit();
                                            try self.zomb_macro_type_stack.append(.{ .List = array_list });
                                        },
                                        else => return error.UnexpectedMacroStackList,
                                    },
                                    .Key, .Array, .Empty => {
                                        try self.zomb_macro_type_stack.append(.{ .List =
                                            .{ .ArrayList = std.ArrayList(ZombMacroArrayValue).init(&self.arena.allocator) }
                                        });
                                    },
                                    else => return error.UnexpectedMacroStackTop,
                                }
                            }
                            try self.stateStackPush(stack_array);
                            continue :parseloop; // keep the token
                        },
                        else => return error.UnexpectedValueStage0Token,
                    },
                    1 => switch(token.token_type) { // plus sign OR raw string OR exit value state
                        .Plus => self.state_stage = 0,
                        .RawString => {
                            self.state_stage = 0;
                            continue :parseloop; // keep the token
                        },
                        else => try self.stateStackPop(),
                    },
                    else => return error.UnexpectedValueStage,
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
                            var res = try self.macro_map.getOrPut(try token.slice(self.input));
                            if (res.found_existing) return error.DuplicateMacroName;
                            res.value_ptr.* = ZombMacro{};
                            self.macro_ptr = res.value_ptr;
                            self.state_stage = 1;
                        },
                        else => return error.UnexpectedMacroDeclState0Token,
                    },
                    1 => switch (token.token_type) { // parameters or equals
                        .OpenParen => {
                            self.macro_ptr.?.*.params = std.StringArrayHashMap(u32).init(&self.arena.allocator);
                            self.state_stage = 2;
                        },
                        .Equals => try self.stateStackPush(stack_value),
                        else => return error.UnexpectedMacroDeclStage1Token,
                    },
                    2 => switch (token.token_type) { // parameters
                        .String => {
                            var res = try self.macro_ptr.?.*.params.?.getOrPut(try token.slice(self.input));
                            if (res.found_existing) return error.DuplicateMacroParamName;
                            res.value_ptr.* = 0;
                        },
                        .CloseParen => self.state_stage = 3,
                        else => return error.UnexpectedMacroDeclStage2Token,
                    },
                    3 => switch (token.token_type) { // equals (after parameters)
                        .Equals => try self.stateStackPush(stack_value),
                        else => return error.UnexpectedMacroDeclStage3Token,
                    },
                    else => return error.UnexpectedMacroDeclStage,
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
                            try self.stateStackPush(stack_macro_expr_params);
                            continue :parseloop; // keep the token
                        },
                        else => {
                            // TODO: evaluate the expression and push the value onto the zomb_type_map
                            try self.stateStackPop();
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
                            try self.stateStackPop();
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
                            if (self.macro_ptr == null) {
                                return error.MacroParamKeyUsedOutsideMacroDecl;
                            }
                            self.state_stage = 2;
                        },
                        .MacroKey => {
                            try self.stateStackPush(stack_macro_expr);
                            continue :parseloop;
                        },
                        .OpenCurly => {
                            try self.stateStackPush(stack_object);
                            continue :parseloop;
                        },
                        .OpenSquare => {
                            try self.stateStackPush(stack_array);
                            continue :parseloop;
                        },
                        else => return error.UnexpectedMacroExprParamsStage1Token,
                    },
                    2 => switch (token.token_type) { // more than one parameter
                        .String, => {},
                        .MacroParamKey => {
                            if (self.macro_ptr == null) {
                                return error.MacroParamKeyUsedOutsideMacroDecl;
                            }
                        },
                        .MacroKey => {
                            try self.stateStackPush(stack_macro_expr);
                            continue :parseloop;
                        },
                        .OpenCurly => {
                            try self.stateStackPush(stack_object);
                            continue :parseloop;
                        },
                        .OpenSquare => {
                            try self.stateStackPush(stack_array);
                            continue :parseloop;
                        },
                        .CloseParen => try self.stateStackPop(),
                        else => return error.UnexpectedMacroExprParamsStage2Token,
                    },
                    else => return error.UnexpectedMacroExprParamsStage,
                },
            }

            next_token = try self.tokenizer.next();
        } // end :parseloop

        if (self.zomb_type_stack.items.len > 1) {
            try self.stackConsumeKvPair();
        }
        return Zomb{
            .arena = out_arena,
            .map = self.zomb_type_stack.pop().Element,
        };
    }

    fn macroStackTop(self: Self) ?*ZombMacroStackType {
        const len = self.zomb_macro_type_stack.items.len;
        if (len == 0) {
            return null;
        }
        return &self.zomb_macro_type_stack.items[len - 1];
    }

    //===============================
    // ZombType Consumption Functions

    fn stackConsumeKvPair(self: *Self) !void {
        const val = self.zomb_type_stack.pop().Element;
        const key = self.zomb_type_stack.pop().Key;
        var object = &self.zomb_type_stack.items[self.zomb_type_stack.items.len - 1].Element.Object;
        try object.put(key, val);
    }

    fn stackConsumeArrayValue(self: *Self) !void {
        const val = self.zomb_type_stack.pop().Element;
        var array = &self.zomb_type_stack.items[self.zomb_type_stack.items.len - 1].Element.Array;
        try array.append(val);
    }

    fn stackConsumeMacroKvPair(self: *Self) !void {
        const val = self.zomb_macro_type_stack.pop();
        const key = self.zomb_macro_type_stack.pop();
        if (self.macroStackTop()) |stack_type| {
            var object = stack_type.Object;
            try object.Object.put(key.Key, val.List);
        } else {
            return error.MacroStackEmpty;
        }
    }

    fn stackConsumeMacroArrayValue(self: *Self) !void {
        const val = self.zomb_macro_type_stack.pop();
        if (self.macroStackTop()) |stack_type| {
            var array = stack_type.Array;
            try array.Array.append(val.List);
        }
    }

    //======================
    // State Stack Functions

    fn stateStackPush(self: *Self, stack_type: u4) !void {
        if (self.stack_size > max_stack_size) {
            return error.TooManyStateStackPushes;
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

    fn stateStackPop(self: *Self) !void {
        if (self.stack_size == 0) {
            return error.TooManyStateStackPops;
        }
        self.stack >>= stack_shift;
        self.stack_size -= 1;
        if (self.stack_size == 0) {
            self.state = State.Decl;
            return;
        }
        self.state_stage = 1;
        switch (self.stack & 0b1111) {
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

    fn stateStackPeek(self: Self) ?u4 {
        if (self.stack_size == 0) {
            return null;
        }
        return @intCast(u2, self.stack & 0b1111);
    }

    fn stateStackHasMacros(self: Self) bool {
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

test "kvpair - bare string value" {
    const input = "key = value";
    var zparser = Parser.init(input, testing.allocator);
    defer zparser.deinit();

    const z = try zparser.parse(testing.allocator);
    defer z.deinit();

    const entry = z.map.Object.getEntry("key");
    try testing.expect(entry != null);
    try testing.expectEqualStrings("key", entry.?.key_ptr.*);
    switch (entry.?.value_ptr.*) {
        .String => |str| try testing.expectEqualStrings("value", str.items),
        else => return error.UnexpectedValue,
    }
}

test "kvpair - quoted string value" {
    const input = "key = \"value\"";
    var zparser = Parser.init(input, testing.allocator);
    defer zparser.deinit();

    const z = try zparser.parse(testing.allocator);
    defer z.deinit();

    const entry = z.map.Object.getEntry("key");
    try testing.expect(entry != null);
    try testing.expectEqualStrings("key", entry.?.key_ptr.*);
    switch (entry.?.value_ptr.*) {
        .String => |str| try testing.expectEqualStrings("value", str.items),
        else => return error.UnexpectedValue,
    }
}

test "kvpair - one line raw string value" {
    const input = "key = \\\\value";
    var zparser = Parser.init(input, testing.allocator);
    defer zparser.deinit();

    const z = try zparser.parse(testing.allocator);
    defer z.deinit();

    const entry = z.map.Object.getEntry("key");
    try testing.expect(entry != null);
    try testing.expectEqualStrings("key", entry.?.key_ptr.*);
    switch (entry.?.value_ptr.*) {
        .String => |str| try testing.expectEqualStrings("value", str.items),
        else => return error.UnexpectedValue,
    }
}

test "kvpair - two line raw string value" {
    const input =
        \\key = \\one
        \\      \\two
        ;
    var zparser = Parser.init(input, testing.allocator);
    defer zparser.deinit();

    const z = try zparser.parse(testing.allocator);
    defer z.deinit();

    const entry = z.map.Object.getEntry("key");
    try testing.expect(entry != null);
    try testing.expectEqualStrings("key", entry.?.key_ptr.*);
    switch (entry.?.value_ptr.*) {
        .String => |str| try testing.expectEqualStrings("one\ntwo", str.items),
        else => return error.UnexpectedValue,
    }
}
