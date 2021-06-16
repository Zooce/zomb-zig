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

pub const ZombMacroExpr = struct {
    pub const Accessor = union(enum) {
        Key: []const u8,
        Index: usize,
    };

    key: []const u8,
    params: ?ZombTypeMap = null, // TODO: can this just be an array list?
    accessors: ?std.ArrayList(Accessor) = null,
};

pub const Zomb = struct {
    arena: std.heap.ArenaAllocator,
    map: ZombType,

    pub fn deinit(self: @This()) void {
        self.arena.deinit();
    }
};

pub const max_stack_size = 64; // this is fairly reasonable (add more stacks if we need more?)

pub const Parser = struct {
    const Self = @This();

    const stack_shift = 2; // 2 bits per stack element

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

    const State = enum {
        Decl,
        MacroDecl,
        KvPair,
        Object,
        Array,
        MacroExpr,
        MacroExprParams,
    };

    allocator: *std.mem.Allocator,

    input: []const u8 = undefined,

    tokenizer: Tokenizer,

    state: State = State.Decl,

    // Each state has a set of stages in which they have different expectations of the next token.
    state_stage: u8 = 0,

    // NOTE: the following bit-stack setup is based on zig/lib/std/json.zig
    stack: u128 = 0,
    stack_size: u8 = 0,

    // macros: ZombMacroMap,
    // zomb_type_map: ZombTypeMap,
    zomb_type_stack: ZombTypeArray,
    ml_string: std.ArrayList(u8),

    macro_expr_stack: std.ArrayList(ZombMacroExpr), // stack of macro-exprs currently being parsed

    macro_decl: bool = false,

    pub fn init(input_: []const u8, alloc_: *std.mem.Allocator) Self {
        return Self{
            .allocator = alloc_,
            .input = input_,
            .tokenizer = Tokenizer.init(input_),
            .zomb_type_stack = ZombTypeArray.init(alloc_),
            .ml_string = std.ArrayList(u8).init(alloc_),
            .macro_expr_stack = std.ArrayList(ZombMacroExpr).init(alloc_),
        };
    }

    pub fn deinit(self: *Self) void {
        self.zomb_type_stack.deinit();
    }

    pub fn parse(self: *Self) !Zomb {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        // our stack has an implicit top-level object
        try self.zomb_type_stack.append(ZombType{ .Object = ZombTypeMap.init(&arena.allocator) });

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
                //         Equals           >> 4
                //         else             >> error
                // --------------------------------------------
                //     2   String           >> -
                //         CloseParen       >> 3
                //         else             >> error
                // --------------------------------------------
                //     3   Equals           >> 4
                //         else             >> error
                // --------------------------------------------
                //     4   MultiLineString  >> 5
                //         String           >> Decl
                //         MacroParamKey    >> Decl
                //         MacroKey         >> MacroExpr (keep token)
                //         OpenCurly        >> Object (keep token)
                //         OpenSquare       >> Array (keep token)
                //         else             >> error
                // --------------------------------------------
                //     5   MultiLineString  >> -
                //         else             >> Decl (keep token)
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
                        .Equals => self.state_stage = 4,
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
                        .Equals => self.state_stage = 4,
                        else => return error.UnexpectedMacroDeclStage3Token,
                    },
                    4 => switch (token.token_type) { // value
                        .MultiLineString => {
                            //try self.ml_string.appendSlice(try token.slice(self.input));

                            self.state_stage = 5;
                        },
                        .String => {
                            // const val = try token.slice(self.input);
                            // try self.stackConsumeKvPair(ZombType{ .String = val });

                            self.state = State.Decl;
                        },
                        .MacroParamKey => {
                            // TODO: this is a macro paramter being used directly as the value - kind of a weird edge
                            //       case, but whatever...? need to validate this is actually a paramter of this macro

                            // const val = try token.slice(self.input);
                            // try self.stackConsumeKvPair(ZombType{ .String = val });

                            self.state = State.Decl;
                        },
                        .MacroKey => {
                            try self.bitStackPush(stack_macro_expr);
                            continue :parseloop; // keep the token
                        },
                        .OpenCurly => {
                            try self.bitStackPush(stack_object);
                            continue :parseloop; // keep the token
                        },
                        .OpenSquare => {
                            try self.bitStackPush(stack_array);
                            continue :parseloop; // keep the token
                        },
                        else => return error.UnexpectedMacroDeclStage4Token,
                    },
                    5 => switch (token.token_type) {
                        .MultiLineString => {
                            // try self.ml_string.appendSlice(try token.slice(self.input));
                        },
                        else => {
                            // try self.stackConsumeKvPair(ZombType{ .String = self.ml_string.toOwnedSlice() });

                            self.state = State.Decl;
                            continue :parseloop; // we want to keep the current token
                        },
                    },
                    else => return error.UnexpectedMacroDeclStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------------
                //     0   String           >> 1
                //         else             >> error
                // --------------------------------------------------
                //     1   Equals           >> 2
                //         else             >> error
                // --------------------------------------------------
                //     2   MultiLineString  >> 3
                //         String           >> Object (stack) or Decl
                //         MacroParamKey    >> Object (stack) or Decl
                //         MacroKey         >> MacroExpr (keep token)
                //         OpenCurly        >> Object (keep token)
                //         OpenSquare       >> Array (keep token)
                //         else             >> error
                // --------------------------------------------------
                //     3   MultiLineString  >> -
                //         else             >> Object (stack) or Decl (keep token)
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
                        .Equals => self.state_stage = 2,
                        else => return error.UnexpectedKvPairStage1Token,
                    },
                    2 => switch (token.token_type) { // value
                        .MultiLineString => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) try self.ml_string.appendSlice(try token.slice(self.input));
                            self.state_stage = 3; // wait for more lines in stage 3
                        },
                        .String => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                const val = try token.slice(self.input);
                                try self.stackConsumeKvPair(ZombType{ .String = val });
                            }

                            try self.exitKvPair();
                        },
                        .MacroParamKey => {
                            if (!self.macro_decl) {
                                return error.MacroParamKeyUsedOutsideMacroDecl;
                            }

                            try self.exitKvPair();
                        },
                        .MacroKey => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) try self.stackConsumeKvPair(ZombType.Empty);
                            try self.bitStackPush(stack_macro_expr);
                            continue :parseloop; // keep the token
                        },
                        .OpenCurly => {
                            try self.bitStackPush(stack_object);
                            continue :parseloop; // keep the token
                        },
                        .OpenSquare => {
                            try self.bitStackPush(stack_array);
                            continue :parseloop; // keep the token
                        },
                        else => return error.UnexpectedKvPairStage2Token,
                    },
                    3 => switch (token.token_type) {
                        .MultiLineString => if (!self.macro_decl and !self.bitStackHasMacros()) {
                            try self.ml_string.appendSlice(try token.slice(self.input));
                        },
                        else => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                try self.stackConsumeKvPair(ZombType{ .String = self.ml_string.toOwnedSlice() });
                            }
                            try self.exitKvPair();
                            continue :parseloop; // keep the token
                        },
                    },
                    else => return error.UnexpectedKvPairStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   OpenCurly        >> 1
                //         else             >> error
                // --------------------------------------------
                //     1   String           >> KvPair (keep token)
                //         CloseCurly       >> stack or Decl
                //         else             >> error
                .Object => switch (self.state_stage) {
                    0 => switch (token.token_type) {
                        .OpenCurly => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                try self.zomb_type_stack.append(ZombType{ .Object = ZombTypeMap.init(&arena.allocator) });
                            }
                            self.state_stage = 1;
                        },
                        else => return error.UnexpectedObjectStage0Token,
                    },
                    1 => switch (token.token_type) {
                        .String => {
                            self.state = State.KvPair;
                            self.state_stage = 0;
                            continue :parseloop; // keep the token
                        },
                        .CloseCurly => {
                            try self.bitStackPop();
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                switch (self.bitStackPeek() orelse stack_object) {
                                    stack_object => try self.stackConsumeKvPair(self.zomb_type_stack.pop()),
                                    stack_array => try self.stackConsumeArrayValue(self.zomb_type_stack.pop()),
                                    else => return error.UnexpectedObjectBitStackPeek,
                                }
                            }
                        },
                        else => return error.UnexpectedObjectStage1Token,
                    },
                    else => return error.UnexpectedObjectStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   OpenSquare       >> 1
                //         else             >> error
                // --------------------------------------------
                //     1   String           >> -
                //         MacroParamKey    >> - (only under macro-decl)
                //         MultiLineString  >> 2
                //         MacroKey         >> MacroExpr (keep token)
                //         OpenCurly        >> Object (keep token)
                //         OpenSquare       >> Array (keep token)
                //         CloseSquare      >> stack or Decl
                //         else             >> error
                // --------------------------------------------
                //     2   MultiLineString  >> -
                //         else             >> 1 (keep token)
                .Array => switch (self.state_stage) {
                    0 => switch (token.token_type) { // open square
                        .OpenSquare => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) try self.zomb_type_stack.append(ZombType{ .Array = ZombTypeArray.init(&arena.allocator) });
                            self.state_stage = 1;
                        },
                        else => return error.UnexpectedArrayStage0Token,
                    },
                    1 => switch (token.token_type) { // value list or close square
                        .String => if (!self.macro_decl and !self.bitStackHasMacros()) {
                            const val = try token.slice(self.input);
                            try self.stackConsumeArrayValue(ZombType{ .String = val });
                        },
                        .MacroParamKey => {
                            if (!self.macro_decl) {
                                return error.MacroParamKeyUsedOutsideMacroDecl;
                            }
                        },
                        .MultiLineString => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                try self.ml_string.appendSlice(try token.slice(self.input));
                            }
                            self.state_stage = 2;
                        },
                        .MacroKey => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) try self.stackConsumeArrayValue(ZombType.Empty);
                            try self.bitStackPush(stack_macro_expr);
                            continue :parseloop; // keep the token
                        },
                        .OpenCurly => {
                            try self.bitStackPush(stack_object);
                            continue :parseloop; // keep the token
                        },
                        .OpenSquare => {
                            try self.bitStackPush(stack_array);
                            continue :parseloop; // keep the token
                        },
                        .CloseSquare => {
                            try self.bitStackPop();
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                switch (self.bitStackPeek() orelse stack_object) {
                                    stack_object => try self.stackConsumeKvPair(self.zomb_type_stack.pop()),
                                    stack_array => try self.stackConsumeArrayValue(self.zomb_type_stack.pop()),
                                    else => return error.UnexpectedTypeFromBitStackPeek,
                                }
                            }
                        },
                        else => return error.UnexpectedArrayStage1Token,
                    },
                    2 => switch (token.token_type) { // ml-string lines
                        .MultiLineString => if (!self.macro_decl and !self.bitStackHasMacros()) {
                            try self.ml_string.appendSlice(try token.slice(self.input));
                        },
                        else => {
                            if (!self.macro_decl and !self.bitStackHasMacros()) {
                                try self.stackConsumeArrayValue(ZombType{ .String = self.ml_string.toOwnedSlice() });
                            }

                            self.state_stage = 1;
                            continue :parseloop; // keep the token
                        },
                    },
                    else => return error.UnexpectedArrayStage,
                },

                // stage   expected tokens  >> next stage/state
                // --------------------------------------------
                //     0   MacroKey         >> 1
                //         else             >> error
                // --------------------------------------------
                //     1   MacroAccessor    >> 2 (keep token)
                //         OpenParen        >> MacroExprParams (keep token)
                //         else             >> stack or Decl (keep token)
                // --------------------------------------------
                //     2   MacroAccessor    >> -
                //         else             >> stack or Decl (keep token)
                .MacroExpr => switch (self.state_stage) {
                    0 => switch (token.token_type) {
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
                                expr.*.accessors = std.ArrayList(ZombMacroExpr.Accessor).init(&arena.allocator);
                            }
                            self.state_stage = 2;
                            continue :parseloop; // keep the token
                        },
                        .OpenParen => {
                            try self.bitStackPush(stack_macro_expr_params);
                            continue :parseloop; // keep the token
                        },
                        else => {
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
                            try self.bitStackPop();
                            // TODO: consume macro expr stack
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
                //         MultiLineString  >> 3
                //         MacroKey         >> MacroExpr (keep token)
                //         OpenCurly        >> Object (keep token)
                //         OpenSquare       >> Array (keep token)
                //         else             >> error
                // --------------------------------------------
                // pop 2   String           >> -
                //         MacroParamKey    >> - (only under macro-decl)
                //         MultiLineString  >> 3
                //         MacroKey         >> MacroExpr (keep token)
                //         OpenCurly        >> Object (keep token)
                //         OpenSquare       >> Array (keep token)
                //         CloseParen       >> stack or Decl
                //         else             >> error
                // --------------------------------------------
                //     3   MultiLineString  >> -
                //         else             >> 2 (keep token)

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
                        .MultiLineString => self.state_stage = 3,
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
                        .MultiLineString => self.state_stage = 3,
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
                    3 => switch (token.token_type) { // more lines of a multi-line string
                        .MultiLineString => {},
                        else => {
                            self.state_stage = 2;
                            continue :parseloop; // keep the token
                        },
                    },
                    else => return error.UnexpectedMacroExprParamsStage,
                },
            }

            token = try self.tokenizer.next();
        } // end :parseloop

        return Zomb{
            .arena = arena,
            .map = self.zomb_type_stack.pop(),
        };
    }

    fn exitKvPair(self: *Self) !void {
        if (self.bitStackPeek()) |stack_type| {
            self.state_stage = 1;
            switch (stack_type) {
                stack_object => self.state = State.Object,
                else => return error.UnexpectedKvPairExitBitStackPeek,
            }
        } else {
            self.state = State.Decl;
        }
    }

    fn stackConsumeKvPair(self: *Self, zomb_type_: ZombType) !void {
        const key = self.zomb_type_stack.pop();
        var object = &self.zomb_type_stack.items[self.zomb_type_stack.items.len - 1].Object;
        try object.put(key.String, zomb_type_);
    }

    fn stackConsumeArrayValue(self: *Self, zomb_type_: ZombType) !void {
        var array = &self.zomb_type_stack.items[self.zomb_type_stack.items.len - 1].Array;
        try array.append(zomb_type_);
    }

    fn bitStackPush(self: *Self, stack_type: u2) !void {
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
        }
    }

    fn bitStackPop(self: *Self) !void {
        if (self.stack_size == 0) {
            return error.TooManybitStackPops;
        }
        self.stack >>= stack_shift;
        self.stack_size -= 1;
        if (self.stack_size == 0) {
            self.state = State.Decl;
            return;
        }
        self.state_stage = 1;
        switch (self.stack & 0b11) {
            stack_object => self.state = State.Object,
            stack_array => self.state = State.Array,
            stack_macro_expr => self.state = State.MacroExpr,
            stack_macro_expr_params => {
                self.state = State.MacroExprParams;
                self.state_stage = 2;
            },
            else => return error.UnexpectedStackElement,
        }
    }

    fn bitStackPeek(self: Self) ?u2 {
        if (self.stack_size == 0) {
            return null;
        }
        return @intCast(u2, self.stack & 0b11);
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

test "stack logic" {
    var stack: u128 = 0;
    var stack_size: u8 = 0;
    const stack_size_limit: u8 = 64;
    const shift = 2;
    const obj = 0;
    const arr = 1;
    const mac = 2;
    const par = 3;

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
