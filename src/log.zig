const std = @import("std");

const data = @import("data.zig");
const ConcatItem = data.ConcatItem;
const ConcatList = data.ConcatList;
const ZExpr = data.ZExpr;
const ZExprArg = data.ZExprArg;
const ZMacro = data.ZMacro;
const ReductionContext = data.ReductionContext;
const StackElem = data.StackElem;
const ZValue = data.ZValue;

const Parser = @import("parse.zig").Parser;

const StateMachine = @import("state_machine.zig").StateMachine;

const Token = @import("token.zig").Token;
const Tokenizer = @import("token.zig").Tokenizer;

pub const LOGGING = true;

pub fn logConcatItem(citem: ConcatItem, writer: anytype, indent: usize) std.os.WriteError!void {
    if (!LOGGING) return;
    switch (citem) {
        .Object => |obj| {
            try writer.writeAll("ConcatItem.Object = {\n");
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try writer.writeByteNTimes(' ', (indent + 1) * 2);
                try writer.print("{s} = ", .{entry.key_ptr.*});
                try logConcatList(entry.value_ptr.*, writer, indent + 1);
            }
            try writer.writeByteNTimes(' ', indent * 2);
            try writer.writeAll("}\n");
        },
        .Array => |arr| {
            try writer.writeAll("ConcatItem.Array = [\n");
            for (arr.items) |item| {
                try writer.writeByteNTimes(' ', (indent + 1) * 2);
                try logConcatList(item, writer, indent + 1);
            }
            try writer.writeByteNTimes(' ', indent * 2);
            try writer.writeAll("]\n");
        },
        .String => |s| try writer.print("ConcatItem.String = {s}\n", .{s}),
        .Parameter => |p| try writer.print("ConcatItem.Parameter = {s}\n", .{p}),
        .Expression => |e| try logZExpr(e, writer, indent),
    }
}

pub fn logConcatList(list: ConcatList, writer: anytype, indent: usize) std.os.WriteError!void {
    if (!LOGGING) return;
    try writer.writeAll("ConcatList = [\n");
    for (list.items) |citem| {
        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try logConcatItem(citem, writer, indent + 1);
    }
    try writer.writeByteNTimes(' ', indent * 2);
    try writer.writeAll("]\n");
}

pub fn logZValue(zval: ZValue, writer: anytype, indent: usize) std.os.WriteError!void {
    if (!LOGGING) return;
    switch (zval) {
        .Object => |obj| {
            try writer.writeAll("ZValue.Object = {\n");
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try writer.writeByteNTimes(' ', (indent + 1) * 2);
                try writer.print("{s} = ", .{entry.key_ptr.*});
                try logZValue(entry.value_ptr.*, writer, indent + 1);
            }
            try writer.writeByteNTimes(' ', indent * 2);
            try writer.writeAll("}\n");
        },
        .Array => |arr| {
            try writer.writeAll("ZValue.Array = [\n");
            for (arr.items) |item| {
                try writer.writeByteNTimes(' ', (indent + 1) * 2);
                try logZValue(item, writer, indent + 1);
            }
            try writer.writeByteNTimes(' ', indent * 2);
            try writer.writeAll("]\n");
        },
        .String => |str| try writer.print("ZValue.String = {s}\n", .{str.items}),
    }
}

pub fn logZExpr(expr: ZExpr, writer: anytype, indent: usize) std.os.WriteError!void {
    if (!LOGGING) return;
    try writer.writeAll("ZExpr = {\n");

    try writer.writeByteNTimes(' ', (indent + 1) * 2);
    try writer.print("key = {s}\n", .{expr.key});

    try writer.writeByteNTimes(' ', (indent + 1) * 2);
    try writer.writeAll("args = ");
    if (expr.args) |args| {
        try writer.writeAll("{\n");
        var iter = args.iterator();
        while (iter.next()) |entry| {
            try writer.writeByteNTimes(' ', (indent + 2) * 2);
            try writer.print("{s} = ", .{entry.key_ptr.*});
            try logZExprArg(entry.value_ptr.*, writer, indent + 2);
        }
        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.writeAll("}\n");
    } else {
        try writer.writeAll("null\n");
    }

    try writer.writeByteNTimes(' ', (indent + 1) * 2);
    try writer.writeAll("accessors = ");
    if (expr.accessors) |accessors| {
        try writer.writeAll("[\n");
        for (accessors.items) |accessor| {
            try writer.writeByteNTimes(' ', (indent + 2) * 2);
            try writer.print("{s}\n", .{accessor});
        }
        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.writeAll("]\n");
    } else {
        try writer.writeAll("null\n");
    }

    try writer.writeByteNTimes(' ', (indent + 1) * 2);
    try writer.writeAll("batch_args_set = ");
    if (expr.batch_args_list) |batch_args_list| {
        try writer.writeAll("[\n");
        for (batch_args_list.items) |batch_args| {
            try writer.writeByteNTimes(' ', (indent + 2) * 2);
            try writer.writeAll("[\n");
            for (batch_args.items) |c_list| {
                try writer.writeByteNTimes(' ', (indent + 3) * 2);
                try logConcatList(c_list, writer, indent + 3);
            }
            try writer.writeByteNTimes(' ', (indent + 2) * 2);
            try writer.writeAll("]\n");
        }
        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.writeAll("]\n");
    } else {
        try writer.writeAll("null\n");
    }

    try writer.writeByteNTimes(' ', indent * 2);
    try writer.writeAll("}\n");
}

pub fn logZExprArg(exprArg: ZExprArg, writer: anytype, indent: usize) std.os.WriteError!void {
    if (!LOGGING) return;
    try writer.writeAll("ZExprArg.");
    switch (exprArg) {
        .CList => |list| try logConcatList(list, writer, indent),
        .BatchPlaceholder => try writer.writeAll("BatchPlaceholder\n"),
    }
}

pub fn logZMacro(zmacro: ZMacro, writer: anytype, indent: usize) std.os.WriteError!void {
    if (!LOGGING) return;
    try writer.writeAll("ZMacro = {\n");

    try writer.writeByteNTimes(' ', (indent + 1) * 2);
    try writer.writeAll("parameters = ");
    if (zmacro.parameters) |parameters| {
        try writer.writeAll("[\n");
        var iter = parameters.iterator();
        while (iter.next()) |entry| {
            try writer.writeByteNTimes(' ', (indent + 2) * 2);
            try writer.print("{s} = ", .{entry.key_ptr.*});
            if (entry.value_ptr.*) |default_value| {
                try logConcatList(default_value, writer, indent + 2);
            } else {
                try writer.writeAll("null\n");
            }
        }
        try writer.writeByteNTimes(' ', (indent + 1) * 2);
        try writer.writeAll("]\n");
    } else {
        try writer.writeAll("null\n");
    }

    try writer.writeByteNTimes(' ', (indent + 1) * 2);
    try writer.writeAll("value = ");
    try logConcatList(zmacro.value, writer, indent + 1);

    try writer.writeByteNTimes(' ', indent * 2);
    try writer.writeAll("}\n");
}

pub fn logReductionContext(ctx: ReductionContext, writer: anytype) std.os.WriteError!void {
    if (!LOGGING) return;
    try writer.writeAll("ReductionContext = {\n");

    try writer.writeAll("  expr_args = ");
    if (ctx.expr_args) |expr_args| {
        try writer.writeAll("{\n");
        var iter = expr_args.iterator();
        while (iter.next()) |entry| {
            try writer.print("    {s} = ", .{entry.key_ptr.*});
            try logConcatList(entry.value_ptr.*, writer, 3);
        }
    } else {
        try writer.writeAll("null\n");
    }

    try writer.writeAll("}\n");
}

pub fn logStackElem(elem: StackElem, writer: anytype, indent: usize) std.os.WriteError!void {
    if (!LOGGING) return;
    switch (elem) {
        .TopLevelObject => |obj| {
            const o = ZValue{ .Object = obj };
            try logZValue(o, writer, indent);
        },
        .Key => |k| try writer.print("Key = {s}\n", .{k}),
        .CList => |l| {
            try logConcatList(l, writer, indent);
        },
        .CItem => |c| try logConcatItem(c, writer, indent),
        .Placeholder => try writer.writeAll("Placeholder\n"),
        .ExprArgList => |elist| {
            try writer.writeAll("ExprArgList = [\n");
            for (elist.items) |eitem| {
                try writer.writeByteNTimes(' ', (indent + 1) * 2);
                try logZExprArg(eitem, writer, indent + 1);
            }
            try writer.writeAll("]\n");
        },
        .BSet => |bset| {
            try writer.writeAll("BSet = [\n");
            for (bset.items) |arr| {
                try writer.writeByteNTimes(' ', (indent + 1) * 2);
                try writer.writeAll("[\n");
                for (arr.items) |item| {
                    try writer.writeByteNTimes(' ', (indent + 2) * 2);
                    try logConcatList(item, writer, indent + 2);
                }
                try writer.writeByteNTimes(' ', (indent + 1) * 2);
                try writer.writeAll("]\n");
            }
            try writer.writeAll("]\n");
        },
        .ParamMap => |pm| {
            if (pm) |map| {
                try writer.writeAll("ParamMap = {\n");
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    try writer.writeByteNTimes(' ', (indent + 1) * 2);
                    try writer.print("{s} = ", .{entry.key_ptr.*});
                    if (entry.value_ptr.*) |c_list| {
                        try logConcatList(c_list, writer, indent + 1);
                    } else {
                        try writer.writeAll("null\n");
                    }
                }
                try writer.writeAll("}\n");
            } else {
                try writer.writeAll("ParamMap = null\n");
            }
        },
        .MacroDeclParam => |p| try writer.print("MacroDeclParam = {s}\n", .{p}),
    }
}

pub fn logToken(token: Token, writer_: anytype, input_: []const u8) anyerror!void {
    if (!LOGGING) return;
    try writer_.print(
        \\----[Token]----
        \\Type  = {}
        \\Value = {s}
        \\Line  = {}
        \\Valid = {}
        \\
        , .{
            token.token_type,
            try token.slice(input_),
            token.line,
            token.is_valid,
        }
    );
}

pub fn logTokenizer(tokenizer: Tokenizer, writer_: anytype) std.os.WriteError!void {
    if (!LOGGING) return;
    try writer_.print(
        \\----[Tokenizer]----
        \\State = {}
        \\Stage = {}
        \\Line = {}
        \\End = {}
        \\
        , .{
            tokenizer.state,
            tokenizer.state_stage,
            tokenizer.current_line,
            tokenizer.at_end_of_buffer,
        }
    );
}

pub fn logStateMachine(machine: StateMachine, writer_: anytype) std.os.WriteError!void {
    try writer_.print(
        \\----[State Machine]----
        \\State = {}
        \\Stack = 0x{X:0>32}
        \\Size  = {}
        \\
        , .{ machine.state, machine.stack, machine.stack_size }
    );
}

pub fn logParser(parser: Parser, count_: usize, tag_: []const u8) !void {
    if (!LOGGING) return;
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    const stderr = std.io.getStdErr().writer();
    try stderr.print(
        \\
        \\=====[[ {s} {} ]]=====
        \\
        , .{ tag_, count_ }
    );
    if (parser.token) |token| {
        try logToken(token, stderr, parser.input);
    } else {
        try stderr.writeAll("----[Token]----\nnull\n");
    }
    // try logTokenizer(parser.tokenizer, stderr);
    try logStateMachine(parser.state_machine, stderr);

    try stderr.writeAll("----[Macros]----\n");
    var iter = parser.macros.iterator();
    while (iter.next()) |entry| {
        try stderr.print("{s} = {struct}", .{entry.key_ptr.*, entry.value_ptr.*});
    }

    try stderr.writeAll("----[Parse Stack]----\n");
    for (parser.stack.items) |stack_elem| {
        try stderr.print("{union}", .{stack_elem});
    }

    try stderr.writeAll("\n");
}
