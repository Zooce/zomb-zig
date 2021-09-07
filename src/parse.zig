const std = @import("std");

const Tokenizer = @import("token.zig").Tokenizer;
const TokenType = @import("token.zig").TokenType;
const Token = @import("token.zig").Token;

pub const ZombValueMap = std.StringArrayHashMap(ZombValue);
pub const ZombValueArray = std.ArrayList(ZombValue);

pub const ZombValue = union(enum) {
    Object: ZombValueMap,
    Array: ZombValueArray,
    String: std.ArrayList(u8),

    fn access(self: ZombValue, accessors_: [][]const u8) anyerror!ZombValue {
        if (accessors_.len == 0) {
            return self;
        }
        switch (self) {
            .Object => |obj| {
                const acc = accessors_[0];
                const entry = obj.getEntry(acc) orelse return error.KeyNotFound;
                if (accessors_.len > 1) {
                    return entry.value_ptr.*.access(accessors_[1..]);
                } else {
                    return entry.value_ptr.*;
                }
            },
            .Array => |arr| {
                const idx = try std.fmt.parseUnsigned(usize, accessors_[0], 10);
                if (accessors_.len > 1) {
                    return arr.items[idx].access(accessors_[1..]);
                } else {
                    return arr.items[idx];
                }
            },
            .String => return error.CannotUseAccessorForString,
        }
    }
};

pub const ZombMacroExpr = struct {
    key: []const u8,
    args: ?ZombValueArray = null,
    accessors: ?std.ArrayList([]const u8) = null,
};

const ZombStackType = union(enum) {
    Value: ZombValue,
    Expr: ZombMacroExpr,
    ExprArgs: ZombValueArray,
    Key: []const u8,
};

const ZombMacroValueMap = std.StringArrayHashMap(ZombMacroValue);
const ZombMacroValueArray = std.ArrayList(ZombMacroValue);
const ZombMacroMacroExpr = struct {
    key: []const u8,
    args: ?ZombMacroValueArray = null,
    accessors: ?std.ArrayList([]const u8) = null,
};

const ZombMacroObjectValue = union(enum) {
    Object: ZombMacroValueMap,
    Parameter: []const u8,
    Expr: ZombMacroMacroExpr,
};
const ZombMacroArrayValue = union(enum) {
    Array: ZombMacroValueArray,
    Parameter: []const u8,
    Expr: ZombMacroMacroExpr,
};
const ZombMacroStringValue = union(enum) {
    String: []const u8,
    Parameter: []const u8,
    Expr: ZombMacroMacroExpr,
};
const ZombMacroMacroExprValue = union(enum) {
    Expr: ZombMacroMacroExpr,
    Parameter: []const u8,
};

const ZombMacroArg = union(enum) {
    Value: ZombValue,
    Parameter: []const u8,
};

const ZombMacroValue = union(enum) {
    ObjectList: std.ArrayList(ZombMacroObjectValue),
    ArrayList: std.ArrayList(ZombMacroArrayValue),
    StringList: std.ArrayList(ZombMacroStringValue),
    ExprList: std.ArrayList(ZombMacroMacroExprValue),

    /// This should be converted to one of the types above upon parsing the first
    /// non-Parameter type.
    ParameterList: std.ArrayList([]const u8),

    fn toZombValue(self: ZombMacroValue, alloc_: *std.mem.Allocator, params_: ?[][]const u8, args_: ?[]ZombValue, macros_: std.StringArrayHashMap(ZombMacro)) anyerror!ZombValue {
        var value: ZombValue = undefined;
        switch (self) {
            .ObjectList => |object_list| {
                value = .{ .Object = ZombValueMap.init(alloc_) };
                errdefer value.Object.deinit();
                for (object_list.items) |macro_object| {
                    switch (macro_object) {
                        .Object => |obj| {
                            var iter = obj.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                const val = try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_);
                                try value.Object.putNoClobber(key, val);
                            }
                        },
                        .Parameter => |p| {
                            const idx = try indexOfString(params_.?, p);
                            if (args_.?.len <= idx) {
                                return error.IncompatibleParamArgs;
                            }
                            var iter = args_.?[idx].Object.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                const val = entry.value_ptr.*;
                                try value.Object.putNoClobber(key, val);
                            }
                        },
                        .Expr => |e| {
                            const args = getargs: {
                                if (e.args) |args| {
                                    var temp_args = ZombValueArray.init(alloc_);
                                    for (args.items) |arg| {
                                        try temp_args.append(try arg.toZombValue(alloc_, params_, args_, macros_));
                                    }
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(e.key) orelse return error.MacroKeyNotFound;
                            var expr_val = try macro.value.toZombValue(alloc_,
                                if (macro.params) |p| p.keys() else null,
                                if (args) |a| a.items else null,
                                macros_);
                            if (e.accessors) |accessors| {
                                // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                                expr_val = try expr_val.access(accessors.items);
                            }
                            var iter = expr_val.Object.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                const val = entry.value_ptr.*;
                                try value.Object.putNoClobber(key, val);
                            }
                        },
                    }
                }
            },
            .ArrayList => |array_list| {
                value = .{ .Array = ZombValueArray.init(alloc_) };
                errdefer value.Array.deinit();
                for (array_list.items) |macro_array| {
                    switch (macro_array) {
                        .Array => |arr| {
                            for (arr.items) |item| {
                                const val = try item.toZombValue(alloc_, params_, args_, macros_);
                                try value.Array.append(val);
                            }
                        },
                        .Parameter => |p| {
                            const idx = try indexOfString(params_.?, p);
                            if (args_.?.len <= idx) {
                                return error.IncompatibleParamArgs;
                            }
                            for (args_.?[idx].Array.items) |val| {
                                try value.Array.append(val);
                            }
                        },
                        .Expr => |e| {
                            const args = getargs: {
                                if (e.args) |args| {
                                    var temp_args = ZombValueArray.init(alloc_);
                                    for (args.items) |arg| {
                                        try temp_args.append(try arg.toZombValue(alloc_, params_, args_, macros_));
                                    }
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(e.key) orelse return error.MacroKeyNotFound;
                            var expr_val = try macro.value.toZombValue(alloc_,
                                if (macro.params) |p| p.keys() else null,
                                if (args) |a| a.items else null,
                                macros_);
                            if (e.accessors) |accessors| {
                                // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                                expr_val = try expr_val.access(accessors.items);
                            }
                            for (expr_val.Array.items) |item| {
                                try value.Array.append(item);
                            }
                        },
                    }
                }
            },
            .StringList => |string_list| {
                value = .{ .String = std.ArrayList(u8).init(alloc_) };
                errdefer value.String.deinit();
                for (string_list.items) |string| {
                    switch (string) {
                        .String => |str| try value.String.appendSlice(str),
                        .Parameter => |p| {
                            const idx = try indexOfString(params_.?, p);
                            if (args_.?.len <= idx) {
                                return error.IncompatibleParamArgs;
                            }
                            try value.String.appendSlice(args_.?[idx].String.items);
                        },
                        .Expr => |e| {
                            const args = getargs: {
                                if (e.args) |args| {
                                    var temp_args = ZombValueArray.init(alloc_);
                                    for (args.items) |arg| {
                                        try temp_args.append(try arg.toZombValue(alloc_, params_, args_, macros_));
                                    }
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(e.key) orelse return error.MacroKeyNotFound;
                            var expr_val = try macro.value.toZombValue(alloc_,
                                if (macro.params) |p| p.keys() else null,
                                if (args) |a| a.items else null,
                                macros_);
                            if (e.accessors) |accessors| {
                                // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                                expr_val = try expr_val.access(accessors.items);
                            }
                            try value.String.appendSlice(expr_val.String.items);
                        },
                    }
                }
            },
            .ParameterList => |param_list| {
                var allocated = false;
                errdefer { // TODO: is this necessary for this case?
                    if (allocated) {
                        switch (value) {
                            .Object => value.Object.deinit(),
                            .Array => value.Array.deinit(),
                            .String => value.String.deinit(),
                        }
                    }
                }
                for (param_list.items) |param, i| {
                    const idx = try indexOfString(params_.?, param);
                    const arg = args_.?[idx]; // TODO: what if this is a Parameter?
                    if (i == 0) {
                        value = arg; // TODO: is this making a copy of the arg or is it a pointer to the arg itself?
                        allocated = true;
                        continue;
                    }
                    switch (value) {
                        .Object => |*object| {
                            var iter = arg.Object.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                const val = entry.value_ptr.*;
                                try object.*.putNoClobber(key, val);
                            }
                        },
                        .Array => |*array| {
                            for (arg.Array.items) |item| {
                                try array.*.append(item);
                            }
                        },
                        .String => |*string| {
                            try string.*.appendSlice(arg.String.items);
                        },
                    }
                }
            },
            .ExprList => |expr_list| {
                var allocated = false;
                errdefer { // TODO: is this necessary for this case?
                    if (allocated) {
                        switch (value) {
                            .Object => value.Object.deinit(),
                            .Array => value.Array.deinit(),
                            .String => value.String.deinit(),
                        }
                    }
                }
                for (expr_list.items) |macro_expr, i| {
                    switch (macro_expr) {
                        .Expr => |expr| {
                            const args = getargs: {
                                if (expr.args) |args| {
                                    var temp_args = ZombValueArray.init(alloc_);
                                    for (args.items) |arg| {
                                        try temp_args.append(try arg.toZombValue(alloc_, params_, args_, macros_));
                                    }
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(expr.key) orelse return error.MacroKeyNotFound;
                            var expr_val = try macro.value.toZombValue(alloc_,
                                if (macro.params) |p| p.keys() else null,
                                if (args) |a| a.items else null,
                                macros_);
                            if (expr.accessors) |accessors| {
                                // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                                expr_val = try expr_val.access(accessors.items);
                            }
                            if (i == 0) {
                                value = expr_val;
                                allocated = true;
                                continue;
                            }
                            switch (value) {
                                .Object => |*object| {
                                    var iter = expr_val.Object.iterator();
                                    while (iter.next()) |entry| {
                                        const key = entry.key_ptr.*;
                                        const val = entry.value_ptr.*;
                                        try object.*.putNoClobber(key, val);
                                    }
                                },
                                .Array => |*array| {
                                    for (expr_val.Array.items) |item| {
                                        try array.*.append(item);
                                    }
                                },
                                .String => |*string| {
                                    try string.*.appendSlice(expr_val.String.items);
                                },
                            }
                        },
                        .Parameter => |p| {
                            const idx = try indexOfString(params_.?, p);
                            var arg = args_.?[idx];
                            if (i == 0) {
                                value = arg;
                                allocated = true;
                                continue;
                            }
                            switch (value) {
                                .Object => |*object| {
                                    var iter = arg.Object.iterator();
                                    while (iter.next()) |entry| {
                                        const key = entry.key_ptr.*;
                                        const val = entry.value_ptr.*;
                                        try object.*.putNoClobber(key, val);
                                    }
                                },
                                .Array => |*array| {
                                    for (arg.Array.items) |item| {
                                        try array.*.append(item);
                                    }
                                },
                                .String => |*string| {
                                    try string.*.appendSlice(arg.String.items);
                                },
                            }
                        },
                    }
                }
            }
        }
        return value;
    }
};

fn indexOfString(source_: [][]const u8, target_: []const u8) !usize {
    for (source_) |item, i| {
        if (std.mem.eql(u8, item, target_)) {
            return i;
        }
    }
    return error.NoIndexForString;
}

const ZombMacroStackType = union(enum) {
    List: ZombMacroValue,
    Object: ZombMacroObjectValue,
    Array: ZombMacroArrayValue,
    Expr: ZombMacroMacroExprValue,
    ExprArgs: ZombMacroValueArray,
    Key: []const u8,
    Empty: void, // the starting element -- for parsing
};

pub const ZombMacro = struct {
    /// This map is used to count the number of parameter uses in the macro value. After the macro
    /// has been fully parsed, we check to make sure each entry is greater than zero.
    params: ?std.StringArrayHashMap(u32) = null,

    /// The actual value of this macro.
    value: ZombMacroValue = undefined,

    /// A list of macro expression keys used inside this macro. Used for detecting recursion.
    macro_exprs: ?std.ArrayList([]const u8) = null,
};

pub const Zomb = struct {
    arena: std.heap.ArenaAllocator,
    map: ZombValueMap,

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
    const stack_macro_expr_args = 3;
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
        MacroExprArgs,
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

    val_value_stack: StackBits = 0,
    val_value_stack_size: u8 = 0,

    zomb_value_stack: std.ArrayList(ZombStackType) = undefined,

    macro_ptr: ?*ZombMacro = null,
    zomb_macro_value_stack: std.ArrayList(ZombMacroStackType) = undefined,
    macro_map: std.StringArrayHashMap(ZombMacro) = undefined,

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
        self.zomb_value_stack = std.ArrayList(ZombStackType).init(&self.arena.allocator);
        self.zomb_macro_value_stack = std.ArrayList(ZombMacroStackType).init(&self.arena.allocator);
        self.macro_map = std.StringArrayHashMap(ZombMacro).init(&self.arena.allocator);

        // this arena will be given to the caller so they can clean up the memory we allocate for the ZOMB types
        var out_arena = std.heap.ArenaAllocator.init(allocator_);
        errdefer out_arena.deinit();

        // add the implicit top-level object to our type stack
        try self.zomb_value_stack.append(.{ .Value = .{ .Object = ZombValueMap.init(&out_arena.allocator) } });

        // our macro stack always has an empty first element
        try self.zomb_macro_value_stack.append(ZombMacroStackType.Empty);

        var next_token = try self.tokenizer.next();
        parseloop: while (next_token) |token| {

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
                        macro_ptr.*.value = self.zomb_macro_value_stack.pop().List;
                        if (macro_ptr.*.params) |params| {
                            var iter = params.iterator();
                            while (iter.next()) |entry| {
                                if (entry.value_ptr.* == 0) {
                                    // TODO: log which parameter was not used
                                    return error.UnusedMacroParameter;
                                }
                            }
                        }
                    } else if (self.zomb_value_stack.items.len > 1) {
                        try self.stackConsumeKvPair();
                    }
                    self.state_stage = 0;
                    self.macro_ptr = null; // don't free memory - this was just a pointer to memory we're managing elsewhere
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
                //         CloseCurly       >> Object (stage 2)
                //         else             >> error
                // --------------------------------------------------
                //     1   Equals           >> Value
                //         else             >> error
                .KvPair => switch (self.state_stage) {
                    0 => switch (token.token_type) { // key
                        .String => {
                            const key = .{ .Key = try token.slice(self.input) };
                            if (self.macro_ptr) |_| {
                                try self.zomb_macro_value_stack.append(key);
                            } else {
                                try self.zomb_value_stack.append(key);
                            }
                            self.state_stage = 1;
                        },
                        .CloseCurly => { // empty object case
                            self.state = State.Object;
                            self.state_stage = 2;
                            continue :parseloop; // keep the token
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
                // pop 1   else             >> 2 (keep token)
                // --------------------------------------------
                //     2   String           >> KvPair (keep token)
                //         CloseCurly       >> stack or Decl
                //         else             >> error
                .Object => switch (self.state_stage) {
                    0 => switch (token.token_type) {
                        .OpenCurly => {
                            if (self.macro_ptr) |_| {
                                try self.zomb_macro_value_stack.append(.{ .Object = .{ .Object = ZombMacroValueMap.init(&self.arena.allocator) } });
                            } else {
                                try self.zomb_value_stack.append(.{ .Value = .{ .Object = ZombValueMap.init(&out_arena.allocator) } });
                            }
                            self.state = State.KvPair;
                            self.state_stage = 0;
                        },
                        else => return error.UnexpectedObjectStage0Token,
                    },
                    1 => { // consume kv-pair and check for another
                        if (self.macro_ptr) |_| {
                            const val = self.zomb_macro_value_stack.pop().List;
                            const key = self.zomb_macro_value_stack.pop().Key;
                            var object_ptr = try self.macroStackTop();
                            try object_ptr.*.Object.Object.put(key, val);
                        } else {
                            try self.stackConsumeKvPair();
                        }
                        self.state_stage = 2;
                        continue :parseloop; // keep the token
                    },
                    2 => switch (token.token_type) {
                        .String => {
                            self.state = State.KvPair;
                            self.state_stage = 0;
                            continue :parseloop; // keep the token
                        },
                        .CloseCurly => {
                            if (self.macro_ptr) |_| {
                                const object = self.zomb_macro_value_stack.pop().Object;
                                var list_ptr = try self.macroStackTop();
                                try list_ptr.*.List.ObjectList.append(object);
                            }
                            try self.stateStackPop(); // done with this object, consume it in the parent
                        },
                        else => return error.UnexpectedObjectStage1Token,
                    },
                    else => return error.UnexpectedObjectStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   OpenSquare       >> Value
                //         else             >> error
                // --------------------------------------------
                // pop 1   else             >> 2 (keep token)
                //---------------------------------------------
                //     2   CloseSquare      >> stack or Decl
                //         else             >> Value (keep token)
                .Array => switch (self.state_stage) {
                    0 => switch (token.token_type) { // open square
                        .OpenSquare => {
                            if (self.macro_ptr) |_| {
                                try self.zomb_macro_value_stack.append(.{ .Array = .{ .Array = ZombMacroValueArray.init(&self.arena.allocator) } });
                            } else {
                                try self.zomb_value_stack.append(.{ .Value = .{ .Array = ZombValueArray.init(&out_arena.allocator) } });
                            }
                            try self.stateStackPush(stack_value);
                        },
                        else => return error.UnexpectedArrayStage0Token,
                    },
                    1 => { // consume value and check for another
                        if (self.macro_ptr) |_| {
                            const val = self.zomb_macro_value_stack.pop();
                            var array_ptr = try self.macroStackTop();
                            try array_ptr.*.Array.Array.append(val.List);
                        } else {
                            const val = self.zomb_value_stack.pop().Value;
                            var array = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Value.Array;
                            try array.append(val);
                        }
                        self.state_stage = 2;
                        continue :parseloop; // keep the token
                    },
                    2 => switch (token.token_type) {
                        .CloseSquare => {
                            if (self.macro_ptr) |_| {
                                const array = self.zomb_macro_value_stack.pop().Array;
                                var list_ptr = try self.macroStackTop();
                                try list_ptr.*.List.ArrayList.append(array);
                            }
                            try self.stateStackPop(); // done with this array, consume it in the parent
                        },
                        else => {
                            try self.stateStackPush(stack_value); // check for another value
                            continue :parseloop; // keep the token
                        },
                    },
                    else => return error.UnexpectedArrayStage,
                },

                // this is a special state where we're finally parsing actual values - we do have transistions here, but
                // there are some relatively-complicated scenarios for them, so a state transition table doesn't really
                // do us any good
                .Value => switch (self.state_stage) {
                    0 => switch (token.token_type) { // value
                        .String, .RawString => {
                            const string_slice = try token.slice(self.input);
                            if (self.macro_ptr) |_| {
                                // top of the stack should be a String
                                var top = try self.macroStackTop();
                                switch (top.*) {
                                    .List => |*list| switch (list.*) {
                                        .StringList => |*strings| try strings.append(.{ .String = string_slice }),
                                        .ParameterList => |params| {
                                            var string_list = .{ .StringList = std.ArrayList(ZombMacroStringValue).init(&self.arena.allocator) };
                                            for (params.items) |p| try string_list.StringList.append(.{ .Parameter = p });
                                            var param_list = self.zomb_macro_value_stack.pop();
                                            param_list.List.ParameterList.deinit();
                                            try self.zomb_macro_value_stack.append(.{ .List = string_list });
                                        },
                                        else => return error.UnexpectedStringValueMacroStackType,
                                    },
                                    .Key, .Array, .ExprArgs, .Empty => {
                                        try self.zomb_macro_value_stack.append(.{ .List = .{ .StringList = std.ArrayList(ZombMacroStringValue).init(&self.arena.allocator) } });
                                        continue :parseloop; // keep the token
                                    },
                                    else => return error.UnexpectedStringValueMacroStackType,
                                }
                            } else {
                                var top = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1];
                                switch (top.*) {
                                    .Value => |*elem| switch (elem.*) {
                                        .String => |*str| try str.appendSlice(string_slice),
                                        .Array => {
                                            try self.zomb_value_stack.append(.{ .Value = .{ .String = std.ArrayList(u8).init(&out_arena.allocator) } });
                                            continue :parseloop; // keep the token
                                        },
                                        else => return error.UnexpectedStackValue,
                                    },
                                    .Key, .ExprArgs => {
                                        try self.zomb_value_stack.append(.{ .Value = .{ .String = std.ArrayList(u8).init(&out_arena.allocator) } });
                                        continue :parseloop; // keep the token
                                    },
                                    else => return error.UnexpectedStackValue,
                                }
                            }
                            self.state_stage = 1;
                        },
                        .MacroParamKey => {
                            if (self.macro_ptr) |macro_ptr| {
                                const parameter = try token.slice(self.input);
                                if (macro_ptr.*.params.?.getPtr(parameter)) |p| {
                                    p.* += 1; // count the usage of this parameter - TODO: is there a bug here? also can't we just use a boolean?
                                } else {
                                    return error.InvalidParameterUse;
                                }
                                var top = try self.macroStackTop();
                                switch (top.*) {
                                    .List => |*list| switch (list.*) { // TODO: this might need some work -- I think there's a bug here...
                                        .ObjectList => |*objects| try objects.append(.{ .Parameter = parameter }),
                                        .ArrayList => |*arrays| try arrays.append(.{ .Parameter = parameter }),
                                        .StringList => |*strings| try strings.append(.{ .Parameter = parameter }),
                                        .ExprList => |*exprs| try exprs.append(.{ .Parameter = parameter }),
                                        .ParameterList => |*params| try params.append(parameter),
                                    },
                                    .Key, .Array, .ExprArgs, .Empty => {
                                        try self.zomb_macro_value_stack.append(.{ .List = .{ .ParameterList = std.ArrayList([]const u8).init(&self.arena.allocator) } });
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
                            if (self.macro_ptr) |_| {
                                var top = try self.macroStackTop();
                                switch (top.*) {
                                    .List => |*list| switch (list.*) {
                                        .ParameterList => |params| {
                                            var expr_list = .{ .ExprList = std.ArrayList(ZombMacroMacroExprValue).init(&self.arena.allocator) };
                                            for (params.items) |p| try expr_list.ExprList.append(.{ .Parameter = p });
                                            var param_list = self.zomb_macro_value_stack.pop();
                                            param_list.List.ParameterList.deinit();
                                            try self.zomb_macro_value_stack.append(.{ .List = expr_list });
                                        },
                                        else => {},
                                    },
                                    .Key, .Array, .ExprArgs, .Empty => {
                                        try self.zomb_macro_value_stack.append(.{ .List = .{ .ExprList = std.ArrayList(ZombMacroMacroExprValue).init(&self.arena.allocator) } });
                                    },
                                    else => return error.UnexpectedMacroStackTop,
                                }
                            }
                            try self.stateStackPush(stack_macro_expr);
                            continue :parseloop; // keep the token
                        },
                        .OpenCurly => {
                            if (self.macro_ptr) |_| {
                                var top = try self.macroStackTop();
                                switch (top.*) {
                                    .List => |list_type| switch (list_type) {
                                        .ObjectList => {},
                                        .ParameterList => |params| {
                                            var object_list = .{ .ObjectList = std.ArrayList(ZombMacroObjectValue).init(&self.arena.allocator) };
                                            for (params.items) |p| try object_list.ObjectList.append(.{ .Parameter = p });
                                            var param_list = self.zomb_macro_value_stack.pop();
                                            param_list.List.ParameterList.deinit();
                                            try self.zomb_macro_value_stack.append(.{ .List = object_list });
                                        },
                                        else => return error.UnexpectedMacroStackList,
                                    },
                                    .Key, .Array, .ExprArgs, .Empty => {
                                        try self.zomb_macro_value_stack.append(.{ .List = .{ .ObjectList = std.ArrayList(ZombMacroObjectValue).init(&self.arena.allocator) } });
                                    },
                                    else => return error.UnexpectedMacroStackTop,
                                }
                            }
                            try self.stateStackPush(stack_object);
                            continue :parseloop; // keep the token
                        },
                        .OpenSquare => {
                            if (self.macro_ptr) |_| {
                                var top = try self.macroStackTop();
                                switch (top.*) {
                                    .List => |list_type| switch (list_type) {
                                        .ArrayList => {},
                                        .ParameterList => |params| {
                                            var array_list = .{ .ArrayList = std.ArrayList(ZombMacroArrayValue).init(&self.arena.allocator) };
                                            for (params.items) |p| try array_list.ArrayList.append(.{ .Parameter = p });
                                            var param_list = self.zomb_macro_value_stack.pop();
                                            param_list.List.ParameterList.deinit();
                                            try self.zomb_macro_value_stack.append(.{ .List = array_list });
                                        },
                                        else => return error.UnexpectedMacroStackList,
                                    },
                                    .Key, .Array, .ExprArgs, .Empty => {
                                        try self.zomb_macro_value_stack.append(.{ .List = .{ .ArrayList = std.ArrayList(ZombMacroArrayValue).init(&self.arena.allocator) } });
                                    },
                                    else => return error.UnexpectedMacroStackTop,
                                }
                            }
                            try self.stateStackPush(stack_array);
                            continue :parseloop; // keep the token
                        },
                        .CloseSquare => { // empty array case
                            try self.stateStackPop();
                            self.state_stage = 2;
                            continue :parseloop; // keep the token
                        },
                        else => return error.UnexpectedValueStage0Token,
                    },
                    1 => switch (token.token_type) { // plus sign OR raw string OR exit value state
                        .Plus => self.state_stage = 0,
                        .RawString => {
                            self.state_stage = 0;
                            continue :parseloop; // keep the token
                        },
                        else => {
                            try self.stateStackPop();
                            continue :parseloop; // keep the token
                        },
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
                    0 => switch (token.token_type) { // macro key
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
                        .CloseParen => {
                            if (self.macro_ptr.?.*.params.?.count() == 0) {
                                return error.EmptyMacroDeclParams;
                            }
                            self.state_stage = 3;
                        },
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
                //     0   MacroKey         >> 3
                //         else             >> error
                // --------------------------------------------
                // pop 1   -                >> 2
                // --------------------------------------------
                //     2   MacroAccessor    >> 4 (keep token)
                //         else             >> 5 (keep token)
                // --------------------------------------------
                //     3   MacroAccessor    >> 2 (keep token)
                //         OpenParen        >> MacroExprArgs (keep token)
                //         else             >> 5 (keep token)
                // --------------------------------------------
                //     4   MacroAccessor    >> -
                //         else             >> 5 (keep token)
                // --------------------------------------------
                //     5   -                >> stack (keep token)
                .MacroExpr => switch (self.state_stage) {
                    0 => switch (token.token_type) { // macro key
                        .MacroKey => {
                            if (self.macro_ptr) |_| {
                                try self.zomb_macro_value_stack.append(.{ .Expr = .{ .Expr = ZombMacroMacroExpr{ .key = try token.slice(self.input) } } });
                            } else {
                                try self.zomb_value_stack.append(.{ .Expr = ZombMacroExpr{ .key = try token.slice(self.input) } });
                            }
                            self.state_stage = 3;
                        },
                        else => return error.UnexpectedMacroExprStage0Token,
                    },
                    1 => { // consume arguments and check for accessors
                        if (self.macro_ptr) |_| {
                            var args = self.zomb_macro_value_stack.pop().ExprArgs;
                            var expr = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].Expr;
                            expr.*.Expr.args = args;
                        } else {
                            var args = self.zomb_value_stack.pop().ExprArgs;
                            var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                            expr.*.args = args;
                        }
                        self.state_stage = 2;
                        continue :parseloop;
                    },
                    2 => switch (token.token_type) { // start of macro accessor or done
                        .MacroAccessor => {
                            if (self.macro_ptr) |_| {
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
                            self.state_stage = 4;
                            continue :parseloop; // keep the token
                        },
                        else => {
                            self.state_stage = 5;
                            continue :parseloop; // keep the token
                        },
                    },
                    3 => switch (token.token_type) { // params or accessor
                        .MacroAccessor => {
                            self.state_stage = 2;
                            continue :parseloop; // keep the token
                        },
                        .OpenParen => {
                            try self.stateStackPush(stack_macro_expr_args);
                            continue :parseloop; // keep the token
                        },
                        else => {
                            self.state_stage = 5;
                            continue :parseloop; // keep the token
                        },
                    },
                    4 => switch (token.token_type) { // accessors
                        .MacroAccessor => {
                            if (self.macro_ptr) |_| {
                                var expr = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].Expr.Expr;
                                try expr.*.accessors.?.append(try token.slice(self.input));
                            } else {
                                var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                                try expr.*.accessors.?.append(try token.slice(self.input));
                            }
                        },
                        else => {
                            self.state_stage = 5;
                            continue :parseloop; // keep the token
                        },
                    },
                    5 => { // evaluate expression
                        if (self.macro_ptr) |_| {
                            var expr = self.zomb_macro_value_stack.pop().Expr;
                            var list = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].List.ExprList;
                            try list.append(expr);
                        } else {
                            var expr = self.zomb_value_stack.pop().Expr;
                            var value = try self.evaluateMacroExpr(&out_arena.allocator, expr);
                            try self.zomb_value_stack.append(.{ .Value = value });
                        }
                        try self.stateStackPop(); // consume the evaluated expr in the parent
                        continue :parseloop; // keep the token
                    },
                    else => return error.UnexpectedMacroExprStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   OpenParen        >> Value
                //         else             >> error
                // --------------------------------------------
                // pop 1   else             >> 2 (keep token)
                //---------------------------------------------
                //     2   CloseParen       >> stack (MacroExpr)
                //         else             >> Value (keep token)
                .MacroExprArgs => switch (self.state_stage) {
                    0 => switch (token.token_type) { // open paren
                        .OpenParen => {
                            if (self.macro_ptr) |_| {
                                try self.zomb_macro_value_stack.append(.{ .ExprArgs = ZombMacroValueArray.init(&self.arena.allocator) });
                            } else {
                                try self.zomb_value_stack.append(.{ .ExprArgs = ZombValueArray.init(&self.arena.allocator) });
                            }
                            try self.stateStackPush(stack_value);
                        },
                        else => return error.UnexpectedMacroExprArgsStage0Token,
                    },
                    1 => { // consume value and check for another
                        if (self.macro_ptr) |_| {
                            const val = self.zomb_macro_value_stack.pop().List;
                            var args = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].ExprArgs;
                            try args.append(val);
                        } else {
                            const val = self.zomb_value_stack.pop().Value;
                            var args = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].ExprArgs;
                            try args.append(val);
                        }
                        self.state_stage = 2;
                        continue :parseloop; // keep the token
                    },
                    2 => switch (token.token_type) {
                        .CloseParen => {
                            try self.stateStackPop(); // done with these args, consume them in the parent
                        },
                        else => {
                            try self.stateStackPush(stack_value); // check for another value
                            continue :parseloop; // keep the token
                        },
                    },
                    else => return error.UnexpectedMacroExprArgsStage,
                },
            }

            next_token = try self.tokenizer.next();
        } // end :parseloop

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
        const macro = self.macro_map.get(expr_.key) orelse return error.KeyNotFound;
        var value = try macro.value.toZombValue(alloc_,
            if (macro.params) |p| p.keys() else null,
            if (expr_.args) |a| a.items else null,
            self.macro_map);
        if (expr_.accessors) |accessors| {
            // TODO: should we be clearing out the unused value memory after we only take a piece of it?
            value = try value.access(accessors.items);
        }
        return value;
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
            stack_macro_expr_args => self.state = State.MacroExprArgs,
            stack_value => self.state = State.Value,
            else => return error.UnexpectedStackValue,
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
            stack_macro_expr_args => self.state = State.MacroExprArgs,
            stack_value => self.state = State.Value,
            else => return error.UnexpectedStackValue,
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
