const std = @import("std");

const Tokenizer = @import("token.zig").Tokenizer;
const TokenType = @import("token.zig").TokenType;
const Token = @import("token.zig").Token;

pub const ZombValue = union(enum) {
    Object: std.StringArrayHashMap(ZombValue),
    Array: std.ArrayList(ZombValue),
    String: std.ArrayList(u8),

    // fn access(self: ZombValue, alloc_: *std.mem.Allocator, accessors_: [][]const u8) anyerror!ZombValue {
    //     if (accessors_.len == 0) {
    //         return self;
    //     }
    //     var result: ZombValue = undefined;
    //     switch (self) {
    //         .Object => |obj| {
    //             const acc = accessors_[0];
    //             const entry = obj.getEntry(acc) orelse return error.KeyNotFound;
    //             if (accessors_.len > 1) {
    //                 return entry.value_ptr.*.access(accessors_[1..], alloc_);
    //             } else {
    //                 result = entry.value_ptr.*;
    //             }
    //         },
    //         .Array => |arr| {
    //             const idx = try std.fmt.parseUnsigned(usize, accessors_[0], 10);
    //             if (accessors_.len > 1) {
    //                 return arr.items[idx].access(accessors_[1..], alloc_);
    //             } else {
    //                 result = arr.items[idx];
    //             }
    //         },
    //         .String => return error.CannotUseAccessorForString,
    //     }
    //     switch (result) {
    //         .Object => |*robj| {
    //             var obj = std.StringArrayHashMap(ZombValue).init(alloc_);
    //             var iter = robj.iterator();
    //             while (iter.next()) |entry| {
    //                 const key = entry.key_ptr.*;
    //                 const val = entry.value_ptr.*;
    //             }
    //         }
    //     }
    // }

    fn copy(self: ZombValue, alloc_: *std.mem.Allocator) anyerror!ZombValue {
        var copy_val: ZombValue = undefined;
        switch (self) {
            .Object => |obj| {
                copy_val = std.StringArrayHashMap(ZombValue).init(alloc_);
                errdefer copy_val.deinit();
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const val = entry.value_ptr.*.copy(alloc_);
                    try copy_val.putNoClobber(key, val);
                }
            },
            .Array => |arr| {
                copy_val = std.ArrayList(ZombValue).init(alloc_);
                errdefer copy_val.deinit();
                for (arr.items) |item| {
                    try copy_val.append(item.copy(alloc_));
                }
            },
            .String => |str| {
                copy_val = std.ArrayList(u8).init(alloc_);
                errdefer copy_val.deinit();
                try copy_val.appendSlice(str.items);
            },
        }
        return copy_val;
    }
};

pub const ZombMacroExpr = struct {
    key: []const u8,
    args: ?std.ArrayList(ExprArgType) = null,
    accessors: ?std.ArrayList([]const u8) = null,
};

const ExprArgType = union(enum) {
    Value: ZombValue,
    BatchPlaceholder: void, // TODO: maybe this should be an index or even the paramter name
};

const ZombStackType = union(enum) {
    Value: ZombValue,
    Expr: ZombMacroExpr,
    ExprArgs: std.ArrayList(ExprArgType),
    ExprArg: ExprArgType,
    Key: []const u8,
};

const ZombMacroValueMap = std.StringArrayHashMap(ZombMacroValue);
const ZombMacroValueArray = std.ArrayList(ZombMacroValue);
const ZombMacroDeclExpr = struct {
    key: []const u8,
    args: ?std.ArrayList(DeclExprArgType) = null,
    accessors: ?std.ArrayList([]const u8) = null,
};

const DeclExprArgType = union(enum) {
    Value: ZombMacroValue,
    BatchPlaceholder: void, // TODO: maybe this should be an index or even the paramter name
};

const ZombMacroObjectValue = union(enum) {
    Object: ZombMacroValueMap,
    Parameter: []const u8,
    Expr: ZombMacroDeclExpr,
};
const ZombMacroArrayValue = union(enum) {
    Array: ZombMacroValueArray,
    Parameter: []const u8,
    Expr: ZombMacroDeclExpr,
};
const ZombMacroStringValue = union(enum) {
    String: []const u8,
    Parameter: []const u8,
    Expr: ZombMacroDeclExpr,
};
const ZombMacroDeclExprValue = union(enum) {
    Expr: ZombMacroDeclExpr,
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
    ExprList: std.ArrayList(ZombMacroDeclExprValue),

    /// This should be converted to one of the types above upon parsing the first
    /// non-Parameter type.
    ParameterList: std.ArrayList([]const u8),

    // TODO: change args_ to ?
    fn toZombValue(self: ZombMacroValue, alloc_: *std.mem.Allocator, params_: ?[][]const u8, args_: ?[]ExprArgType, macros_: std.StringArrayHashMap(ZombMacro), accessors_: ?[][]const u8) anyerror!ZombValue {
        const has_accessors = accessors_ != null and accessors_.?.len > 0;
        var value: ZombValue = undefined;
        switch (self) {
            .ObjectList => |object_list| {
                if (!has_accessors) {
                    // if we have accessors, there's no need to allocate memory for this entire object because we only
                    // want a part of it, so we'll allocate only the memory needed for the part we want to access
                    value = .{ .Object = std.StringArrayHashMap(ZombValue).init(alloc_) };
                }
                errdefer {
                    if (!has_accessors) {
                        value.Object.deinit();
                    }
                }
                for (object_list.items) |macro_object| {
                    switch (macro_object) {
                        .Object => |obj| {
                            var iter = obj.iterator();
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                if (has_accessors) {
                                    if (!std.mem.eql(u8, accessors_.?[0], key)) {
                                        continue;
                                    }
                                    if (accessors_.?.len > 1) {
                                        return try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                    } else {
                                        return try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, null);
                                    }
                                }
                                // if we're here, then it means we have no accessors and we want the entire object
                                const val = try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, null);
                                try value.Object.putNoClobber(key, val);
                            }
                        },
                        .Parameter => |p| {
                            if (has_accessors) {
                                // accessing keys on macro parameter arguments is forbidden - skip checking these
                                // TODO: log a warning that we are skipping access of parameter argument keys
                                continue;
                            }
                            const idx = try indexOfString(params_.?, p);
                            if (args_.?.len <= idx) {
                                return error.IncompatibleParamArgs;
                            }
                            var iter = args_.?[idx].Value.Object.iterator(); // TODO: what if this index is a batch placeholder ?
                            while (iter.next()) |entry| {
                                const key = entry.key_ptr.*;
                                const val = entry.value_ptr.*;
                                try value.Object.putNoClobber(key, val);
                            }
                        },
                        .Expr => |e| {
                            const args = getargs: {
                                if (has_accessors) {
                                    // since we have accessors and access on parameter arguments is forbidden, we won't need the arguments
                                    // TODO: log a warning that we are not considering expression args since we have accessors
                                    break :getargs null;
                                }
                                if (e.args) |args| {
                                    var temp_args = std.ArrayList(ExprArgType).init(alloc_);
                                    for (args.items) |arg| {
                                        switch (arg) {
                                            .Value => |v| {
                                                try temp_args.append(try v.toZombValue(alloc_, params_, args_, macros_, null));
                                            },
                                            .BatchPlaceholder => return error.NotImplementedYet,
                                        }
                                    }
                                    // TODO: this memory needs to be cleaned up somewhere
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(e.key) orelse return error.MacroKeyNotFound;
                            if (has_accessors) {
                                // we need to evaluate this expression (we're expecting an object) and then we need to
                                // find the key for the accessor we're looking for
                                var temp_arena = std.heap.ArenaAllocator.init(alloc_);
                                defer temp_arena.deinit();
                                const expr_val = try macro.value.toZombValue(&temp_arena.allocator,
                                    if (macro.params) |p| p.keys() else null,
                                    null, // remember, we don't allow accessors on args, so we don't need this
                                    macros_,
                                    if (e.accessors) |acc| acc.items else null);
                                // if (e.accessors) |accessors| {
                                //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                                //     expr_val = try expr_val.access(accessors.items);
                                // }
                                var iter = expr_val.Object.iterator();
                                while (iter.next()) |entry| {
                                    const key = entry.key_ptr.*;
                                    if (!std.mem.eql(u8, accessors_.?[0], key)) {
                                        continue;
                                    }
                                    return entry.value_ptr.*.copy(alloc_);
                                }
                            } else {
                                var expr_val = try macro.value.toZombValue(alloc_,
                                    if (macro.params) |p| p.keys() else null,
                                    if (args) |a| a.items else null,
                                    macros_,
                                    if (e.accessors) |acc| acc.items else null);
                                var iter = expr_val.Object.iterator();
                                while (iter.next()) |entry| {
                                    const key = entry.key_ptr.*;
                                    const val = entry.value_ptr.*;
                                    try value.Object.putNoClobber(key, val);
                                }
                            }
                        },
                    }
                }
            },
            .ArrayList => |array_list| {
                if (!has_accessors) {
                    value = .{ .Array = std.ArrayList(ZombValue).init(alloc_) };
                }
                errdefer {
                    if (!has_accessors) {
                        value.Array.deinit();
                    }
                }
                const index: usize = idxblk: {
                    if (has_accessors) {
                        break :idxblk try std.fmt.parseUnsigned(usize, accessors_.?[0], 10);
                    }
                    break :idxblk 0;
                };
                var size: usize = 0;
                for (array_list.items) |macro_array| {
                    switch (macro_array) {
                        .Array => |arr| {
                            if (has_accessors) {
                                size += arr.len;
                                if (index >= size) {
                                    continue;
                                }
                                if (accessors_.?.len > 1) {
                                    return try arr.items[index].toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                } else {
                                    return try arr.items[index].toZombValue(alloc_, params_, args_, macros_, null);
                                }
                            }
                            // if we're here, then we have no accessors and we just want the entire array
                            for (arr.items) |item| {
                                const val = try item.toZombValue(alloc_, params_, args_, macros_, null);
                                try value.Array.append(val);
                            }
                        },
                        .Parameter => |p| {
                            if (has_accessors) {
                                // accessing keys on macro parameter arguments is forbidden - skip checking these
                                // TODO: log a warning that we are skipping access of parameter argument keys
                                continue;
                            }
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
                                if (has_accessors) {
                                    // since we have accessors and access on parameter arguments is forbidden, we won't need the arguments
                                    // TODO: log a warning that we are not considering expression args since we have accessors
                                    break :getargs null;
                                }
                                if (e.args) |args| {
                                    var temp_args = std.ArrayList(ExprArgType).init(alloc_);
                                    for (args.items) |arg| {
                                        switch (arg) {
                                            .Value => |v| {
                                                try temp_args.append(try v.toZombValue(alloc_, params_, args_, macros_, null));
                                            },
                                            .BatchPlaceholder => return error.NotImplementedYet,
                                        }
                                    }
                                    // TODO: this memory needs to be cleaned up somewhere
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(e.key) orelse return error.MacroKeyNotFound;
                            if (has_accessors) {
                                var temp_arena = std.heap.ArenaAllocator.init(alloc_);
                                defer temp_arena.deinit();
                                const expr_val = try macro.value.toZombValue(&temp_arena.allocator,
                                    if (macro.params) |p| p.keys() else null,
                                    null, // remember, we don't allow accessors on args, so we don't need this
                                    macros_,
                                    if (e.accessors) |acc| acc.items else null);
                                size += expr_val.Array.len;
                                if (index >= size) {
                                    continue;
                                }
                                if (accessors_.?.len > 1) {
                                    return try expr_val.Array.items[index].toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                } else {
                                    return try expr_val.Array.items[index].toZombValue(alloc_, params_, args_, macros_, null);
                                }
                            }

                            var expr_val = try macro.value.toZombValue(alloc_,
                                if (macro.params) |p| p.keys() else null,
                                if (args) |a| a.items else null,
                                macros_,
                                if (e.accessors) |acc| acc.items else null);
                            // if (e.accessors) |accessors| {
                            //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                            //     expr_val = try expr_val.access(accessors.items);
                            // }
                            for (expr_val.Array.items) |item| {
                                try value.Array.append(item);
                            }
                        },
                    }
                }
            },
            .StringList => |string_list| {
                if (has_accessors) {
                    return error.CannotUseAccessorForString;
                }
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
                                    var temp_args = std.ArrayList(ExprArgType).init(alloc_);
                                    for (args.items) |arg| {
                                        switch (arg) {
                                            .Value => |v| {
                                                try temp_args.append(try v.toZombValue(alloc_, params_, args_, macros_, null));
                                            },
                                            .BatchPlaceholder => return error.NotImplementedYet,
                                        }
                                    }
                                    // TODO: this memory needs to be cleaned up somewhere
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(e.key) orelse return error.MacroKeyNotFound;
                            var expr_val = try macro.value.toZombValue(alloc_,
                                if (macro.params) |p| p.keys() else null,
                                if (args) |a| a.items else null,
                                macros_,
                                if (e.accessors) |acc| acc.items else null);
                            // if (e.accessors) |accessors| {
                            //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                            //     expr_val = try expr_val.access(accessors.items);
                            // }
                            try value.String.appendSlice(expr_val.String.items);
                        },
                    }
                }
            },
            .ParameterList => |param_list| {
                if (has_accessors) {
                    return error.CannotUseAccessorForParameter;
                }
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
                var size: usize = 0; // in case this expr list is evaluated to an array
                for (expr_list.items) |macro_expr, i| {
                    switch (macro_expr) {
                        .Expr => |expr| {
                            const args = getargs: {
                                if (has_accessors) {
                                    // since we have accessors and access on parameter arguments is forbidden, we won't need the arguments
                                    // TODO: log a warning that we are not considering expression args since we have accessors
                                    break :getargs null;
                                }
                                if (expr.args) |args| {
                                    var temp_args = std.ArrayList(ExprArgType).init(alloc_);
                                    for (args.items) |arg| {
                                        switch (arg) {
                                            .Value => |v| {
                                                try temp_args.append(try v.toZombValue(alloc_, params_, args_, macros_, null));
                                            },
                                            .BatchPlaceholder => return error.NotImplementedYet,
                                        }
                                    }
                                    // TODO: this memory needs to be cleaned up somewhere
                                    break :getargs temp_args;
                                } else {
                                    break :getargs null;
                                }
                            };
                            const macro = macros_.get(expr.key) orelse return error.MacroKeyNotFound;
                            if (has_accessors) {
                                // we need to evaluate this expression (we're expecting an object) and then we need to
                                // find the key for the accessor we're looking for
                                var temp_arena = std.heap.ArenaAllocator.init(alloc_);
                                defer temp_arena.deinit();
                                var expr_val = try macro.value.toZombValue(alloc_,
                                    if (macro.params) |p| p.keys() else null,
                                    null, // remember, we don't allow accessors on args, so we don't need this
                                    macros_,
                                    if (expr.accessors) |acc| acc.items else null);
                                // if (expr.accessors) |accessors| {
                                //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
                                //     expr_val = try expr_val.access(accessors.items);
                                // }
                                if (i == 0) {
                                    value = expr_val;
                                    allocated = true;
                                    continue;
                                }
                                switch (expr_val) {
                                    .Object => |object| {
                                        var iter = object.Object.iterator();
                                        while (iter.next()) |entry| {
                                            const key = entry.key_ptr.*;
                                            if (!std.mem.eql(u8, accessors_.?[0], key)) {
                                                continue;
                                            }
                                            if (accessors_.?.len > 1) {
                                                return try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                            } else {
                                                return try entry.value_ptr.*.toZombValue(alloc_, params_, args_, macros_, null);
                                            }
                                        }
                                    },
                                    .Array => |array| {
                                        size += array.items.len;
                                        const index = try std.fmt.parseUnsigned(usize, accessors_.?[0], 10);
                                        if (index >= size) {
                                            continue;
                                        }
                                        if (accessors_.?.len > 1) {
                                            return try array.items[index].toZombValue(alloc_, params_, args_, macros_, accessors_.?[1..]);
                                        } else {
                                            return try array.items[index].toZombValue(alloc_, params_, args_, macros_, null);
                                        }
                                    },
                                    .String => return error.CannotUseAccessorForString,
                                }
                            }
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
                            if (has_accessors) {
                                // accessing keys on macro parameter arguments is forbidden - skip checking these
                                // TODO: log a warning that we are skipping access of parameter argument keys
                                continue;
                            }
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
    Expr: ZombMacroDeclExprValue,
    ExprArgs: std.ArrayList(DeclExprArgType),
    ExprArg: DeclExprArgType,
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
    map: std.StringArrayHashMap(ZombValue),

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
        try self.zomb_value_stack.append(.{ .Value = .{ .Object = std.StringArrayHashMap(ZombValue).init(&out_arena.allocator) } });

        // our macro stack always has an empty first element
        try self.zomb_macro_value_stack.append(ZombMacroStackType.Empty);

        var next_token = try self.tokenizer.next();
        var token_slice: []const u8 = undefined;
        parseloop: while (next_token) |token| {  // TODO: need to loop until we think we're done -- not based on the next token because there's still useful stuff we can do in this loop
            self.DEBUG_ME(token);

            // comments are ignored everywhere - make sure to get the next token as well
            if (token.token_type == TokenType.Comment) {
                next_token = try self.tokenizer.next();
                continue :parseloop;
            }

            token_slice = try token.slice(self.input);

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
                            const key = .{ .Key = token_slice };
                            if (self.macro_ptr) |_| {
                                try self.zomb_macro_value_stack.append(key);
                            } else {
                                try self.zomb_value_stack.append(key);
                            }
                            // try self.stack.append(.{ .Key = token_slice });
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
                                try self.zomb_value_stack.append(.{ .Value = .{ .Object = std.StringArrayHashMap(ZombValue).init(&out_arena.allocator) } });
                            }
                            // try self.stack.append(.{ .Val = .{ .Obj = std.StringArrayHashMap(ValueParts).init(&self.arena.allocator) } });
                            self.state = State.KvPair;
                            self.state_stage = 0;
                        },
                        else => return error.UnexpectedObjectStage0Token,
                    },
                    1 => { // consume kv-pair
                        // const val = self.stack.pop().List;
                        // const key = self.stack.pop().Key;
                        // var obj_ptr = &self.stack.items[self.stack.items.len - 1];
                        if (self.macro_ptr) |_| {
                            // obj_ptr.*.Obj.put(key, val);
                            const val = self.zomb_macro_value_stack.pop().List;
                            const key = self.zomb_macro_value_stack.pop().Key;
                            var object_ptr = try self.macroStackTop();
                            try object_ptr.*.Object.Object.put(key, val);
                        } else {
                            // create ... ah...the dual allocator thing is difficult...maybe just give the caller the macros as well and use the `out_arena` for everything?
                            // var obj = std.StringArrayHashMap(ZombValue).init(&out_arena.allocator);
                            // try obj.put(key, val.toZombValue());
                            try self.stackConsumeKvPair();
                        }
                        self.state_stage = 2;
                        continue :parseloop; // keep the token
                    },
                    2 => switch (token.token_type) { // another kv-pair or end of object
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
                                try self.zomb_value_stack.append(.{ .Value = .{ .Array = std.ArrayList(ZombValue).init(&out_arena.allocator) } });
                            }
                            try self.stateStackPush(stack_value);
                        },
                        else => return error.UnexpectedArrayStage0Token,
                    },
                    1 => { // consume value
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
                    2 => switch (token.token_type) { // another value or end of array
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

                // this is a special state where we're finally parsing actual values - we do have transitions here, but
                // there are some relatively-complicated scenarios for them, so a state transition table doesn't really
                // do us any good
                .Value => switch (self.state_stage) {
                    0 => switch (token.token_type) { // value
                        .String, .RawString => {
                            if (self.macro_ptr) |_| {
                                // top of the stack should be a String
                                var top = try self.macroStackTop();
                                switch (top.*) {
                                    .List => |*list| switch (list.*) {
                                        .StringList => |*strings| try strings.append(.{ .String = token_slice }),
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
                                        .String => |*str| try str.appendSlice(token_slice),
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
                                if (macro_ptr.*.params.?.getPtr(token_slice)) |p| {
                                    p.* += 1; // count the usage of this parameter - TODO: is there a bug here? also can't we just use a boolean?
                                } else {
                                    return error.InvalidParameterUse;
                                }
                                var top = try self.macroStackTop();
                                switch (top.*) {
                                    .List => |*list| switch (list.*) { // TODO: this might need some work -- I think there's a bug here...
                                        .ObjectList => |*objects| try objects.append(.{ .Parameter = token_slice }),
                                        .ArrayList => |*arrays| try arrays.append(.{ .Parameter = token_slice }),
                                        .StringList => |*strings| try strings.append(.{ .Parameter = token_slice }),
                                        .ExprList => |*exprs| try exprs.append(.{ .Parameter = token_slice }),
                                        .ParameterList => |*params| try params.append(token_slice),
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
                                            var expr_list = .{ .ExprList = std.ArrayList(ZombMacroDeclExprValue).init(&self.arena.allocator) };
                                            for (params.items) |p| try expr_list.ExprList.append(.{ .Parameter = p });
                                            var param_list = self.zomb_macro_value_stack.pop();
                                            param_list.List.ParameterList.deinit();
                                            try self.zomb_macro_value_stack.append(.{ .List = expr_list });
                                        },
                                        else => {},
                                    },
                                    .Key, .Array, .ExprArgs, .Empty => {
                                        try self.zomb_macro_value_stack.append(.{ .List = .{ .ExprList = std.ArrayList(ZombMacroDeclExprValue).init(&self.arena.allocator) } });
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
                            var res = try self.macro_map.getOrPut(token_slice);
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
                            var res = try self.macro_ptr.?.*.params.?.getOrPut(token_slice);
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
                                try self.zomb_macro_value_stack.append(.{ .Expr = .{ .Expr = ZombMacroDeclExpr{ .key = token_slice } } });
                            } else {
                                try self.zomb_value_stack.append(.{ .Expr = ZombMacroExpr{ .key = token_slice } });
                            }
                            self.state_stage = 3;
                        },
                        else => return error.UnexpectedMacroExprStage0Token,
                    },
                    1 => { // consume arguments and check for accessors
                        // var isBatch = false;
                        if (self.macro_ptr) |_| {
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
                                try expr.*.accessors.?.append(token_slice);
                            } else {
                                var expr = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].Expr;
                                try expr.*.accessors.?.append(token_slice);
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
                    // TODO: add new stages for handling macro batching
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
                                try self.zomb_macro_value_stack.append(.{ .ExprArgs = std.ArrayList(DeclExprArgType).init(&self.arena.allocator) });
                            } else {
                                try self.zomb_value_stack.append(.{ .ExprArgs = std.ArrayList(ExprArgType).init(&self.arena.allocator) });
                            }
                            try self.stateStackPush(stack_value);
                        },
                        else => return error.UnexpectedMacroExprArgsStage0Token,
                    },
                    1 => { // consume value and check for another
                        if (self.macro_ptr) |_| {
                            const val = self.zomb_macro_value_stack.pop().ExprArg;
                            var args = &self.zomb_macro_value_stack.items[self.zomb_macro_value_stack.items.len - 1].ExprArgs;
                            try args.append(val);
                        } else {
                            const arg = self.zomb_value_stack.pop().ExprArg;
                            var args = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1].ExprArgs;
                            try args.append(arg);
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

    /// Process the current token based on the current state, transition to the
    /// next state, and update the current token if necessary.
    ///
    /// NOTE: Any time you see a `return` in this function, it means we do not
    ///       want to transition to the next state and we also want to keep the
    ///       current token.
    fn step(self: *Self) !void {
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
                // TODO: try NOT to have this "lagging" consume
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
                self.macro_ptr = null; // don't free memory - this was just a pointer to memory we're managing elsewhere
                keep_token = true;
            },
            .ObjectBegin => {
                if (self.token.?.token_type == .OpenCurly) {
                    if (self.macro_ptr) |_| {
                        try self.zomb_macro_value_stack.append(.{ .Object = .{ .Object = ZombMacroValueMap.init(&self.arena.allocator) } });
                    } else {
                        try self.zomb_value_stack.append(.{ .Value = .{ .Object = std.StringArrayHashMap(ZombValue).init(&out_arena.allocator) } });
                    }
                }
            },
            .Key => if (self.token.?.token_type == .String) {
                const key = .{ .Key = token_slice };
                if (self.macro_ptr) |_| {
                    try self.zomb_macro_value_stack.append(key);
                } else {
                    try self.zomb_value_stack.append(key);
                }
            },
            .Equals => {}, // TODO: remove this since we don't need to do anything here?
            .ObjectConsume => {
                // const val = self.stack.pop().List;
                // const key = self.stack.pop().Key;
                // var obj_ptr = &self.stack.items[self.stack.items.len - 1];
                if (self.macro_ptr) |_| {
                    // obj_ptr.*.Obj.put(key, val);
                    const val = self.zomb_macro_value_stack.pop().List;
                    const key = self.zomb_macro_value_stack.pop().Key;
                    var object_ptr = try self.macroStackTop();
                    try object_ptr.*.Object.Object.put(key, val);
                } else {
                    // create ... ah...the dual allocator thing is difficult...maybe just give the caller the macros as well and use the `out_arena` for everything?
                    // var obj = std.StringArrayHashMap(ZombValue).init(&out_arena.allocator);
                    // try obj.put(key, val.toZombValue());
                    try self.stackConsumeKvPair();
                }
                keep_token = true;
            }
            .ObjectEnd => switch (self.token.?.token_type) {
                .String => keep_token = true,
                .CloseCurly => if (self.macro_ptr) |_| {
                    const object = self.zomb_macro_value_stack.pop().Object;
                    var list_ptr = try self.macroStackTop();
                    try list_ptr.*.List.ObjectList.append(object);
                },
                else => {},
            }
            // TODO: Array states
            .Value => switch (self.token.?.token_type) {
                .String, .RawString => {
                    if (self.macro_ptr) |_| {
                        // top of the stack should be a String
                        var top = try self.macroStackTop();
                        switch (top.*) {
                            .List => |*list| switch (list.*) {
                                .StringList => |*strings| try strings.append(.{ .String = token_slice }),
                                .ParameterList => |params| {
                                    // create a new string list
                                    var string_list = .{ .StringList = std.ArrayList(ZombMacroStringValue).init(&self.arena.allocator) };
                                    // copy the params to the new string list and get rid of the old param list
                                    for (params.items) |p| try string_list.StringList.append(.{ .Parameter = p });
                                    var param_list = self.zomb_macro_value_stack.pop();
                                    param_list.List.ParameterList.deinit();
                                    // save the new string list
                                    try self.zomb_macro_value_stack.append(.{ .List = string_list });
                                    return;
                                },
                                else => return error.UnexpectedStringValueMacroStackType,
                            },
                            .Key, .Array, .ExprArgs, .Empty => {
                                try self.zomb_macro_value_stack.append(.{ .List = .{ .StringList = std.ArrayList(ZombMacroStringValue).init(&self.arena.allocator) } });
                                return;
                            },
                            else => return error.UnexpectedStringValueMacroStackType,
                        }
                    } else {
                        var top = &self.zomb_value_stack.items[self.zomb_value_stack.items.len - 1];
                        switch (top.*) {
                            .Value => |*elem| switch (elem.*) {
                                .String => |*str| try str.appendSlice(token_slice),
                                .Array => {
                                    try self.zomb_value_stack.append(.{ .Value = .{ .String = std.ArrayList(u8).init(&out_arena.allocator) } });
                                    return;
                                },
                                else => return error.UnexpectedStackValue,
                            },
                            .Key, .ExprArgs => {
                                try self.zomb_value_stack.append(.{ .Value = .{ .String = std.ArrayList(u8).init(&out_arena.allocator) } });
                                return;
                            },
                            else => return error.UnexpectedStackValue,
                        }
                    }
                },
                .MacroParamKey => {
                    if (self.macro_ptr) |macro_ptr| {
                        if (macro_ptr.*.params.?.getPtr(token_slice)) |p| {
                            p.* += 1; // count the usage of this parameter - TODO: is there a bug here? also can't we just use a boolean?
                        } else {
                            return error.InvalidParameterUse;
                        }
                        var top = try self.macroStackTop();
                        switch (top.*) {
                            .List => |*list| switch (list.*) { // TODO: this might need some work -- I think there's a bug here...
                                .ObjectList => |*objects| try objects.append(.{ .Parameter = token_slice }),
                                .ArrayList => |*arrays| try arrays.append(.{ .Parameter = token_slice }),
                                .StringList => |*strings| try strings.append(.{ .Parameter = token_slice }),
                                .ExprList => |*exprs| try exprs.append(.{ .Parameter = token_slice }),
                                .ParameterList => |*params| try params.append(token_slice),
                            },
                            .Key, .Array, .ExprArgs, .Empty => {
                                try self.zomb_macro_value_stack.append(.{ .List = .{ .ParameterList = std.ArrayList([]const u8).init(&self.arena.allocator) } });
                                return;
                            },
                            else => return error.UnexpectedMacroParamKeyValueMacroStackType,
                        }
                    } else {
                        return error.MacroParamKeyUsedOutsideMacroDecl;
                    }
                },
                .MacroKey => {
                    if (self.macro_ptr) |_| {
                        var top = try self.macroStackTop();
                        switch (top.*) {
                            .List => |*list| switch (list.*) {
                                .ParameterList => |params| {
                                    var expr_list = .{ .ExprList = std.ArrayList(ZombMacroDeclExprValue).init(&self.arena.allocator) };
                                    for (params.items) |p| try expr_list.ExprList.append(.{ .Parameter = p });
                                    var param_list = self.zomb_macro_value_stack.pop();
                                    param_list.List.ParameterList.deinit();
                                    try self.zomb_macro_value_stack.append(.{ .List = expr_list });
                                },
                                else => {},
                            },
                            .Key, .Array, .ExprArgs, .Empty => {
                                try self.zomb_macro_value_stack.append(.{ .List = .{ .ExprList = std.ArrayList(ZombMacroDeclExprValue).init(&self.arena.allocator) } });
                            },
                            else => return error.UnexpectedMacroStackTop,
                        }
                    }
                    keep_token = true;
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
                    keep_token = true;
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
                    keep_token = true;
                },
                .CloseSquare => keep_token = true,
            }
            .ValueConcat => switch (self.token.?.token_type) {
                .Plus => {},
                else => keep_token = true,
            },
            else => return error.UnexpectedState;
        }
        // transition to the next state
        try self.state_machine.transition(self.token.?);
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
        const macro = self.macro_map.get(expr_.key) orelse return error.KeyNotFound;
        var value = try macro.value.toZombValue(alloc_,
            if (macro.params) |p| p.keys() else null,
            if (expr_.args) |a| a.items else null,
            self.macro_map,
            if (expr_.accessors) |acc| acc.items else null);
        // if (expr_.accessors) |accessors| {
        //     // TODO: should we be clearing out the unused value memory after we only take a piece of it?
        //     value = try value.access(accessors.items);
        // }
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

    /// This is for prototyping only - do not commit this!
    fn DEBUG_ME(self: Self, token: Token) void {
        if (true) {
            return;
        }
        std.log.err(
            \\
            \\State       : {} (stage = {})
            \\State Stack : 0x{X:0>32} (size = {})
            \\Type        : {} (line = {})
            \\Token       : {s}
            \\Stack Len   : {}
        , .{
            self.state,
            self.state_stage,
            self.stack,
            self.stack_size,
            token.token_type,
            token.line,
            token.slice(self.input),
            self.zomb_value_stack.items.len,
        });
        if (self.macro_ptr) |_| {
            std.log.err("Macro Value Stack:", .{});
            for (self.zomb_macro_value_stack.items) |item| switch (item) {
                .List => |list| switch (list) {
                    .ObjectList => |obj_list| std.log.err("ObjectList (len = {})", .{obj_list.items.len}),
                    .ArrayList => |arr_list| std.log.err("ArrayList (len = {})", .{arr_list.items.len}),
                    .StringList => |str_list| std.log.err("StringList (len = {})", .{str_list.items.len}),
                    .ExprList => |expr_list| std.log.err("ExprList (len = {})", .{expr_list.items.len}),
                    .ParameterList => |param_list| std.log.err("ParameterList (len = {})", .{param_list.items.len}),
                },
                .Object => |obj| switch (obj) {
                    .Object => |o| std.log.err("Object (len = {})", .{o.count()}),
                    .Parameter => |p| std.log.err("Parameter (obj) ({s})", .{p}),
                    .Expr => |e| std.log.err("Expr (obj) (key = {s})", .{e.key}),
                },
                .Array => |arr| switch (arr) {
                    .Array => |a| std.log.err("Array (len = {})", .{a.items.len}),
                    .Parameter => |p| std.log.err("Parameter (arr) ({s})", .{p}),
                    .Expr => |e| std.log.err("Expr (arr) (key = {s})", .{e.key}),
                },
                .Expr => |expr| switch (expr) {
                    .Expr => |e| std.log.err("Expr (obj) (key = {s})", .{e.key}),
                    .Parameter => |p| std.log.err("Parameter (expr) ({s})", .{p}),
                },
                .ExprArgs => |x| std.log.err("ExprArgs (len = {})", .{x.items.len}),
                .Key => |k| std.log.err("Key ({s})", .{k}),
                .Empty => std.log.err("Empty", .{}),
            };
        } else {
            std.log.err("Value Stack:", .{});
            for (self.zomb_value_stack.items) |item| switch (item) {
                .Value => |elem| switch (elem) {
                    .Object => |obj| std.log.err("Object (len = {})", .{obj.count()}),
                    .Array => |arr| std.log.err("Array (len = {})", .{arr.items.len}),
                    .String => |str| std.log.err("String ({s})", .{str.items}),
                },
                .Key => |key| std.log.err("Key ({s})", .{key}),
                .Expr => |e| std.log.err("Expr (key = {s})", .{e.key}),
                .ExprArgs => |x| std.log.err("ExprArgs (len = {})", .{x.items.len}),
            };
        }
        std.log.err("\n\n", .{});
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
