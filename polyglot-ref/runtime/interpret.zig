//! interpret.zig - minimal WASM interpreter (zero-dep FANO-1 fallback).
//!
//! Executes the core instruction subset emitted by Zig's wasm32-freestanding
//! backend for the Q128.128 engine: i32/i64 arithmetic, comparisons, shifts,
//! memory load/store, locals/globals, calls, and structured control flow.
//! Unsupported opcodes fail loudly. Results are bit-exact with the native
//! engine and with wasm3.

const std = @import("std");

pub const Value = union(enum) {
    i32: i32,
    i64: i64,
};

pub const FuncType = struct {
    params: []const u8,
    results: []const u8,
};

pub const Func = struct {
    type_idx: u32,
    locals: []const u8,
    code: []const u8,
};

pub const Global = struct {
    val: Value,
    mutable: bool,
};

pub const Export = struct {
    name: []const u8,
    kind: u8,
    index: u32,
};

pub const Module = struct {
    alloc: std.mem.Allocator,
    types: []FuncType,
    func_types: []u32,
    funcs: []Func,
    globals: []Global,
    exports: []Export,
    memory: []u8,
    memory_pages: u32,

    pub fn deinit(self: *Module) void {
        const a = self.alloc;
        for (self.types) |t| {
            a.free(t.params);
            a.free(t.results);
        }
        a.free(self.types);
        a.free(self.func_types);
        for (self.funcs) |f| a.free(f.locals);
        a.free(self.funcs);
        a.free(self.globals);
        for (self.exports) |e| a.free(e.name);
        a.free(self.exports);
        a.free(self.memory);
    }

    pub fn findExport(self: *const Module, name: []const u8) ?Export {
        for (self.exports) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

pub const ParseError = error{ InvalidMagic, InvalidVersion, UnsupportedSection, UnsupportedOpcode, OutOfMemory, BadFormat };

fn readU32(data: []const u8, pos: *usize) ParseError!u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (pos.* >= data.len) return error.BadFormat;
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(u32, b & 0x7F) << shift;
        if (b & 0x80 == 0) break;
        shift +%= 7;
        if (shift >= 32) return error.BadFormat;
    }
    return result;
}

fn readI64(data: []const u8, pos: *usize) ParseError!i64 {
    var result: i64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= data.len) return error.BadFormat;
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(i64, @intCast(b & 0x7F)) << @intCast(shift);
        shift +%= 7;
        if (b & 0x80 == 0) {
            if (shift < 64 and (b & 0x40) != 0) {
                result |= -(@as(i64, 1) << @intCast(shift));
            }
            break;
        }
    }
    return result;
}

fn readName(data: []const u8, pos: *usize, alloc: std.mem.Allocator) ParseError![]u8 {
    const len = try readU32(data, pos);
    if (pos.* + len > data.len) return error.BadFormat;
    const name = try alloc.dupe(u8, data[pos.* .. pos.* + len]);
    pos.* += len;
    return name;
}

/// Parse a WASM binary into a Module.
pub fn parse(alloc: std.mem.Allocator, data: []const u8) ParseError!Module {
    if (data.len < 8 or !std.mem.eql(u8, data[0..4], "\x00asm")) return error.InvalidMagic;
    const version = std.mem.readInt(u32, data[4..8], .little);
    if (version != 1) return error.InvalidVersion;

    var types = std.ArrayList(FuncType).init(alloc);
    var func_types = std.ArrayList(u32).init(alloc);
    var funcs = std.ArrayList(Func).init(alloc);
    var globals = std.ArrayList(Global).init(alloc);
    var exports = std.ArrayList(Export).init(alloc);
    var memory: []u8 = &.{};
    var memory_pages: u32 = 0;

    errdefer {
        for (types.items) |t| {
            alloc.free(t.params);
            alloc.free(t.results);
        }
        types.deinit();
        func_types.deinit();
        for (funcs.items) |f| alloc.free(f.locals);
        funcs.deinit();
        globals.deinit();
        for (exports.items) |e| alloc.free(e.name);
        exports.deinit();
        if (memory.len > 0) alloc.free(memory);
    }

    var pos: usize = 8;
    while (pos < data.len) {
        const sec_id = data[pos];
        pos += 1;
        const sec_size = try readU32(data, &pos);
        const sec_end = pos + sec_size;
        switch (sec_id) {
            1 => { // type section
                const n = try readU32(data, &pos);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    if (data[pos] != 0x60) return error.BadFormat;
                    pos += 1;
                    const np = try readU32(data, &pos);
                    const params = try alloc.dupe(u8, data[pos .. pos + np]);
                    pos += np;
                    const nr = try readU32(data, &pos);
                    const results = try alloc.dupe(u8, data[pos .. pos + nr]);
                    pos += nr;
                    try types.append(.{ .params = params, .results = results });
                }
            },
            3 => { // function section
                const n = try readU32(data, &pos);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    try func_types.append(try readU32(data, &pos));
                }
            },
            5 => { // memory section
                const n = try readU32(data, &pos);
                if (n != 1) return error.BadFormat;
                const flags = try readU32(data, &pos);
                const initial = try readU32(data, &pos);
                memory_pages = initial;
                const bytes = @as(usize, initial) * 65536;
                memory = try alloc.alloc(u8, bytes);
                @memset(memory, 0);
                if (flags & 1 != 0) _ = try readU32(data, &pos); // max
            },
            6 => { // global section
                const n = try readU32(data, &pos);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const vt = try readU32(data, &pos);
                    const mutable = data[pos] == 1;
                    pos += 1;
                    const init = try evalConstExpr(data, &pos);
                    if (vt == 0x7F) {
                        try globals.append(.{ .val = .{ .i32 = @bitCast(init.i32) }, .mutable = mutable });
                    } else if (vt == 0x7E) {
                        try globals.append(.{ .val = .{ .i64 = init.i64 }, .mutable = mutable });
                    } else return error.BadFormat;
                }
            },
            7 => { // export section
                const n = try readU32(data, &pos);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const name = try readName(data, &pos, alloc);
                    const kind = data[pos];
                    pos += 1;
                    const index = try readU32(data, &pos);
                    try exports.append(.{ .name = name, .kind = kind, .index = index });
                }
            },
            10 => { // code section
                const n = try readU32(data, &pos);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const body_size = try readU32(data, &pos);
                    const body_end = pos + body_size;
                    const nlocals = try readU32(data, &pos);
                    var locals = std.ArrayList(u8).init(alloc);
                    var l: u32 = 0;
                    while (l < nlocals) : (l += 1) {
                        const cnt = try readU32(data, &pos);
                        const vt = try readU32(data, &pos);
                        var c: u32 = 0;
                        while (c < cnt) : (c += 1) try locals.append(@intCast(vt));
                    }
                    const code = data[pos..body_end];
                    pos = body_end;
                    try funcs.append(.{ .type_idx = func_types.items[i], .locals = try locals.toOwnedSlice(), .code = code });
                }
            },
            else => {
                // Skip unknown sections (custom, data, etc.)
                pos = sec_end;
            },
        }
        pos = sec_end;
    }

    return .{
        .alloc = alloc,
        .types = try types.toOwnedSlice(),
        .func_types = try func_types.toOwnedSlice(),
        .funcs = try funcs.toOwnedSlice(),
        .globals = try globals.toOwnedSlice(),
        .exports = try exports.toOwnedSlice(),
        .memory = memory,
        .memory_pages = memory_pages,
    };
}

fn evalConstExpr(data: []const u8, pos: *usize) ParseError!Value {
    const op = data[pos.*];
    pos.* += 1;
    var v: Value = undefined;
    switch (op) {
        0x41 => v = .{ .i32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(try readI64(data, pos)))))) },
        0x42 => v = .{ .i64 = try readI64(data, pos) },
        else => return error.UnsupportedOpcode,
    }
    if (data[pos.*] != 0x0B) return error.BadFormat;
    pos.* += 1;
    return v;
}

// ---------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------

pub const Runtime = struct {
    alloc: std.mem.Allocator,
    module: *Module,
    stack: std.ArrayList(Value),
    frames: std.ArrayList(Frame),
    controls: std.ArrayList(Control),
    call_depth: u32,

    const Frame = struct {
        func_idx: usize,
        pc: usize,
        locals: []Value,
        controls_base: usize,
    };

    const Control = struct {
        const Kind = enum { block, loop, if_ };
        kind: Kind,
        start_pc: usize,
        end_pc: usize,
        stack_height: usize, // value-stack length at block entry
        // For loops, br targets start_pc; for block/if, br targets end_pc.
    };

    pub fn init(alloc: std.mem.Allocator, module: *Module) Runtime {
        return .{
            .alloc = alloc,
            .module = module,
            .stack = std.ArrayList(Value).init(alloc),
            .frames = std.ArrayList(Frame).init(alloc),
            .controls = std.ArrayList(Control).init(alloc),
            .call_depth = 0,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.stack.deinit();
        self.frames.deinit();
        self.controls.deinit();
    }

    fn push(self: *Runtime, v: Value) ParseError!void {
        try self.stack.append(v);
    }

    fn pop(self: *Runtime) ParseError!Value {
        if (self.stack.items.len == 0) return error.BadFormat;
        return self.stack.pop();
    }

    fn popI64(self: *Runtime) ParseError!i64 {
        const v = try self.pop();
        return switch (v) {
            .i64 => |x| x,
            .i32 => |x| @as(i64, x),
        };
    }

    fn popI32(self: *Runtime) ParseError!i32 {
        const v = try self.pop();
        return switch (v) {
            .i32 => |x| x,
            .i64 => |x| @bitCast(@as(u32, @truncate(@as(u64, @bitCast(x))))),
        };
    }

    fn getLocal(self: *Runtime, idx: u32) ParseError!Value {
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (idx >= frame.locals.len) return error.BadFormat;
        return frame.locals[idx];
    }

    fn setLocal(self: *Runtime, idx: u32, v: Value) ParseError!void {
        const frame = &self.frames.items[self.frames.items.len - 1];
        if (idx >= frame.locals.len) return error.BadFormat;
        frame.locals[idx] = v;
    }

    /// Advance pc past the immediates of the instruction at pc.
    fn nextPc(code: []const u8, pc: usize) ParseError!usize {
        const op = code[pc];
        var p = pc + 1;
        switch (op) {
            0x02, 0x03, 0x04 => { // block/loop/if: block type
                if (code[p] == 0x40) {
                    p += 1;
                } else {
                    _ = try readU32(code, &p);
                }
            },
            0x10, 0x11 => { // call / call_indirect
                _ = try readU32(code, &p);
                if (op == 0x11) _ = try readU32(code, &p);
            },
            0x41, 0x42 => _ = try readI64(code, &p),
            0x43 => p += 4,
            0x44 => p += 8,
            0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26 => _ = try readU32(code, &p),
            0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E => {
                _ = try readU32(code, &p);
                _ = try readU32(code, &p);
            },
            0x0C, 0x0D => _ = try readU32(code, &p),
            0x05 => { // br_table
                const n = try readU32(code, &p);
                var i: u32 = 0;
                while (i <= n) : (i += 1) _ = try readU32(code, &p);
            },
            0x1C => _ = try readU32(code, &p), // typed select
            0x3F, 0x40 => p += 1, // memory.size/grow: reserved byte
            0xFC => {
                _ = try readU32(code, &p);
                _ = try readU32(code, &p);
            },
            else => {},
        }
        return p;
    }

    /// Scan forward from pc to find the matching end of the block starting at pc.
    fn findBlockEnd(code: []const u8, start: usize) ParseError!usize {
        var depth: usize = 0;
        var pc = start;
        while (pc < code.len) {
            const op = code[pc];
            if (op == 0x02 or op == 0x03 or op == 0x04) depth += 1;
            if (op == 0x0B) {
                depth -= 1;
                if (depth == 0) return pc;
            }
            pc = try nextPc(code, pc);
        }
        return error.BadFormat;
    }

    /// Find the else (0x05) at depth 0 between start and end, or null.
    fn findElse(code: []const u8, start: usize, end: usize) ParseError!?usize {
        var depth: usize = 0;
        var pc = start;
        while (pc < end) {
            const op = code[pc];
            if (op == 0x02 or op == 0x03 or op == 0x04) depth += 1;
            if (op == 0x0B) {
                if (depth == 0) return null;
                depth -= 1;
            }
            if (op == 0x05 and depth == 0) return pc;
            pc = try nextPc(code, pc);
        }
        return null;
    }

    /// Call a function by index with args already on the stack.
    fn callFunc(self: *Runtime, func_idx: u32) ParseError!void {
        if (self.call_depth > 4096) return error.BadFormat;
        self.call_depth += 1;
        defer self.call_depth -= 1;
        const m = self.module;
        if (func_idx >= m.funcs.len) return error.BadFormat;
        const func = m.funcs[func_idx];
        const ft = m.types[func.type_idx];
        // pop params, push frame
        const nparams = ft.params.len;
        var params = std.ArrayList(Value).init(self.alloc);
        defer params.deinit();
        var i: usize = 0;
        while (i < nparams) : (i += 1) {
            try params.append(try self.pop());
        }
        // locals = params reversed (WASM pops last arg first) + declared locals
        var locals = std.ArrayList(Value).init(self.alloc);
        defer locals.deinit();
        var j: usize = 0;
        while (j < nparams) : (j += 1) {
            try locals.append(params.items[nparams - 1 - j]);
        }
        for (func.locals) |lt| {
            try locals.append(switch (lt) {
                0x7F => .{ .i32 = 0 },
                0x7E => .{ .i64 = 0 },
                else => return error.BadFormat,
            });
        }
        try self.frames.append(.{ .func_idx = func_idx, .pc = 0, .locals = try locals.toOwnedSlice(), .controls_base = self.controls.items.len });
        const controls_base = self.controls.items.len;
        defer {
            const fr = self.frames.pop();
            self.alloc.free(fr.locals);
            // drop any control frames the callee left behind (early return)
            while (self.controls.items.len > controls_base) _ = self.controls.pop();
        }
        try self.execBody(func.code);
    }

    fn execBody(self: *Runtime, code: []const u8) ParseError!void {
        const m = self.module;
        var pc: usize = 0;
        while (pc < code.len) {
            const op = code[pc];
            pc += 1;
            switch (op) {
                0x00 => return error.UnsupportedOpcode, // unreachable
                0x01 => {}, // nop
                0x02, 0x03, 0x04 => { // block / loop / if
                    const kind: Control.Kind = if (op == 0x02) .block else if (op == 0x03) .loop else .if_;
                    const op_start = pc - 1; // position of the block opcode
                    if (code[pc] == 0x40) {
                        pc += 1;
                    } else {
                        _ = try readU32(code, &pc);
                    }
                    const end_pc = try findBlockEnd(code, op_start);
                    if (op == 0x04) { // if: condition on stack
                        const cond = try self.popI32();
                        if (cond == 0) {
                            if (try findElse(code, pc, end_pc)) |fe| {
                                // execute the else branch; frame pushed below
                                pc = fe + 1;
                                try self.controls.append(.{ .kind = .if_, .start_pc = pc, .end_pc = end_pc, .stack_height = self.stack.items.len });
                            } else {
                                pc = end_pc + 1; // skip the end, no frame
                            }
                            continue;
                        }
                    }
                    try self.controls.append(.{ .kind = kind, .start_pc = pc, .end_pc = end_pc, .stack_height = self.stack.items.len });
                },
                0x05 => { // else
                    const c = &self.controls.items[self.controls.items.len - 1];
                    pc = c.end_pc;
                },
                0x0B => { // end
                    if (self.controls.items.len > 0) {
                        _ = self.controls.pop();
                    }
                },
                0x0C => { // br
                    const depth = try readU32(code, &pc);
                    const target = try self.brTarget(depth);
                    if (target == null) return; // returned from function
                    pc = target.?;
                },
                0x0D => { // br_if
                    const depth = try readU32(code, &pc);
                    const cond = try self.popI32();
                    if (cond != 0) {
                        const target = try self.brTarget(depth);
                        if (target == null) return;
                        pc = target.?;
                    }
                },
                0x0F => return, // return
                0x10 => { // call
                    const idx = try readU32(code, &pc);
                    try self.callFunc(idx);
                },
                0x11 => return error.UnsupportedOpcode, // call_indirect
                0x1A => _ = try self.pop(), // drop
                0x1B => { // select (no type immediate)
                    const cond = try self.popI32();
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(if (cond != 0) a else b);
                },
                0x1C => { // select t (typed)
                    _ = try readU32(code, &pc);
                    const cond = try self.popI32();
                    const b = try self.pop();
                    const a = try self.pop();
                    try self.push(if (cond != 0) a else b);
                },
                0x20 => { // local.get
                    const idx = try readU32(code, &pc);
                    try self.push(try self.getLocal(idx));
                },
                0x21 => { // local.set
                    const idx = try readU32(code, &pc);
                    try self.setLocal(idx, try self.pop());
                },
                0x22 => { // local.tee
                    const idx = try readU32(code, &pc);
                    const v = try self.pop();
                    try self.setLocal(idx, v);
                    try self.push(v);
                },
                0x23 => { // global.get
                    const idx = try readU32(code, &pc);
                    if (idx >= m.globals.len) return error.BadFormat;
                    try self.push(m.globals[idx].val);
                },
                0x24 => { // global.set
                    const idx = try readU32(code, &pc);
                    if (idx >= m.globals.len or !m.globals[idx].mutable) return error.BadFormat;
                    m.globals[idx].val = try self.pop();
                },
                0x29 => { // i64.load
                    const aln = try readU32(code, &pc);
                    const offset = try readU32(code, &pc);
                    _ = aln;
                    const addr = @as(usize, @intCast(try self.popI32())) + offset;
                    if (addr + 8 > m.memory.len) return error.BadFormat;
                    var buf: [8]u8 = undefined;
                    @memcpy(&buf, m.memory[addr .. addr + 8]);
                    const loaded = std.mem.readInt(u64, &buf, .little);
                    try self.push(.{ .i64 = @bitCast(loaded) });
                },
                0x2D => { // i32.load8_u
                    const aln = try readU32(code, &pc);
                    const offset = try readU32(code, &pc);
                    _ = aln;
                    const addr = @as(usize, @intCast(try self.popI32())) + offset;
                    if (addr >= m.memory.len) return error.BadFormat;
                    try self.push(.{ .i32 = m.memory[addr] });
                },
                0x36 => { // i32.store
                    const aln = try readU32(code, &pc);
                    const offset = try readU32(code, &pc);
                    _ = aln;
                    const v = try self.popI32();
                    const addr = @as(usize, @intCast(try self.popI32())) + offset;
                    if (addr + 4 > m.memory.len) return error.BadFormat;
                    var buf: [4]u8 = undefined;
                    std.mem.writeInt(u32, &buf, @bitCast(v), .little);
                    @memcpy(m.memory[addr .. addr + 4], &buf);
                },
                0x37 => { // i64.store
                    const aln = try readU32(code, &pc);
                    const offset = try readU32(code, &pc);
                    _ = aln;
                    const v = try self.popI64();
                    const addr = @as(usize, @intCast(try self.popI32())) + offset;
                    if (addr + 8 > m.memory.len) return error.BadFormat;
                    var buf: [8]u8 = undefined;
                    std.mem.writeInt(u64, &buf, @bitCast(v), .little);
                    @memcpy(m.memory[addr .. addr + 8], &buf);
                },
                0x3A => { // i32.store8
                    const aln = try readU32(code, &pc);
                    const offset = try readU32(code, &pc);
                    _ = aln;
                    const v = try self.popI32();
                    const addr = @as(usize, @intCast(try self.popI32())) + offset;
                    if (addr >= m.memory.len) return error.BadFormat;
                    m.memory[addr] = @truncate(@as(u32, @bitCast(v)));
                },
                0x3F => { // memory.size
                    _ = try readU32(code, &pc); // reserved 0x00
                    try self.push(.{ .i32 = @intCast(m.memory_pages) });
                },
                0x40 => { // memory.grow
                    _ = try readU32(code, &pc); // reserved 0x00
                    const delta = try self.popI32();
                    const old_pages: i32 = @intCast(m.memory_pages);
                    const new_pages = old_pages + delta;
                    if (new_pages < 0 or new_pages > 65536) {
                        try self.push(.{ .i32 = -1 });
                    } else {
                        const new_bytes = @as(usize, @intCast(new_pages)) * 65536;
                        const new_mem = try self.alloc.alloc(u8, new_bytes);
                        @memcpy(new_mem[0..m.memory.len], m.memory);
                        @memset(new_mem[m.memory.len..], 0);
                        self.alloc.free(m.memory);
                        m.memory = new_mem;
                        m.memory_pages = @intCast(new_pages);
                        try self.push(.{ .i32 = old_pages });
                    }
                },
                0x41 => { // i32.const
                    const v = try readI64(code, &pc);
                    try self.push(.{ .i32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(v))))) });
                },
                0x42 => { // i64.const
                    try self.push(.{ .i64 = try readI64(code, &pc) });
                },
                0x45 => { // i32.eqz
                    const v = try self.popI32();
                    try self.push(.{ .i32 = if (v == 0) 1 else 0 });
                },
                0x49 => { // i32.lt_u
                    const b = try self.popI32();
                    const a = try self.popI32();
                    try self.push(.{ .i32 = if (@as(u32, @bitCast(a)) < @as(u32, @bitCast(b))) 1 else 0 });
                },
                0x4B => { // i32.gt_u
                    const b = try self.popI32();
                    const a = try self.popI32();
                    try self.push(.{ .i32 = if (@as(u32, @bitCast(a)) > @as(u32, @bitCast(b))) 1 else 0 });
                },
                0x4C => { // i32.le_s
                    const b = try self.popI32();
                    const a = try self.popI32();
                    try self.push(.{ .i32 = if (a <= b) 1 else 0 });
                },
                0x50 => { // i64.eqz
                    const v = try self.popI64();
                    try self.push(.{ .i32 = if (v == 0) 1 else 0 });
                },
                0x51 => { // i64.eq
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (a == b) 1 else 0 });
                },
                0x52 => { // i64.ne
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (a != b) 1 else 0 });
                },
                0x53 => { // i64.lt_s
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (a < b) 1 else 0 });
                },
                0x54 => { // i64.lt_u
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (@as(u64, @bitCast(a)) < @as(u64, @bitCast(b))) 1 else 0 });
                },
                0x55 => { // i64.gt_s
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (a > b) 1 else 0 });
                },
                0x56 => { // i64.gt_u
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (@as(u64, @bitCast(a)) > @as(u64, @bitCast(b))) 1 else 0 });
                },
                0x57 => { // i64.le_s
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (a <= b) 1 else 0 });
                },
                0x58 => { // i64.le_u
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (@as(u64, @bitCast(a)) <= @as(u64, @bitCast(b))) 1 else 0 });
                },
                0x59 => { // i64.ge_s
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (a >= b) 1 else 0 });
                },
                0x5A => { // i64.ge_u
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i32 = if (@as(u64, @bitCast(a)) >= @as(u64, @bitCast(b))) 1 else 0 });
                },
                0x6A => { // i32.add
                    const b = try self.popI32();
                    const a = try self.popI32();
                    try self.push(.{ .i32 = a +% b });
                },
                0x6B => { // i32.sub
                    const b = try self.popI32();
                    const a = try self.popI32();
                    try self.push(.{ .i32 = a -% b });
                },
                0x6C => { // i32.mul
                    const b = try self.popI32();
                    const a = try self.popI32();
                    try self.push(.{ .i32 = a *% b });
                },
                0x6D => { // i32.div_s
                    const b = try self.popI32();
                    const a = try self.popI32();
                    if (b == 0) return error.BadFormat;
                    if (a == std.math.minInt(i32) and b == -1) return error.BadFormat;
                    try self.push(.{ .i32 = @divTrunc(a, b) });
                },
                0x6E => { // i32.div_u
                    const b = try self.popI32();
                    const a = try self.popI32();
                    if (b == 0) return error.BadFormat;
                    try self.push(.{ .i32 = @bitCast(@divTrunc(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)))) });
                },
                0x6F => { // i32.rem_s
                    const b = try self.popI32();
                    const a = try self.popI32();
                    if (b == 0) return error.BadFormat;
                    if (a == std.math.minInt(i32) and b == -1) {
                        try self.push(.{ .i32 = 0 });
                    } else {
                        try self.push(.{ .i32 = @rem(a, b) });
                    }
                },
                0x70 => { // i32.rem_u
                    const b = try self.popI32();
                    const a = try self.popI32();
                    if (b == 0) return error.BadFormat;
                    try self.push(.{ .i32 = @bitCast(@rem(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)))) });
                },
                0x71 => { // i32.and
                    const b = try self.popI32();
                    const a = try self.popI32();
                    try self.push(.{ .i32 = a & b });
                },
                0x72 => { // i32.or
                    const b = try self.popI32();
                    const a = try self.popI32();
                    try self.push(.{ .i32 = a | b });
                },
                0x76 => { // i32.shr_u
                    const b = try self.popI32();
                    const a = try self.popI32();
                    try self.push(.{ .i32 = @bitCast(@as(u32, @bitCast(a)) >> @intCast(@as(u5, @truncate(@as(u32, @bitCast(b)))))) });
                },
                0x7C => { // i64.add
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i64 = a +% b });
                },
                0x7D => { // i64.sub
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i64 = a -% b });
                },
                0x7E => { // i64.mul
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i64 = a *% b });
                },
                0x7F => { // i64.div_s
                    const b = try self.popI64();
                    const a = try self.popI64();
                    if (b == 0) return error.BadFormat;
                    if (a == std.math.minInt(i64) and b == -1) return error.BadFormat;
                    try self.push(.{ .i64 = @divTrunc(a, b) });
                },
                0x80 => { // i64.div_u
                    const b = try self.popI64();
                    const a = try self.popI64();
                    if (b == 0) return error.BadFormat;
                    try self.push(.{ .i64 = @bitCast(@divTrunc(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)))) });
                },
                0x81 => { // i64.rem_s
                    const b = try self.popI64();
                    const a = try self.popI64();
                    if (b == 0) return error.BadFormat;
                    if (a == std.math.minInt(i64) and b == -1) {
                        try self.push(.{ .i64 = 0 });
                    } else {
                        try self.push(.{ .i64 = @rem(a, b) });
                    }
                },
                0x82 => { // i64.rem_u
                    const b = try self.popI64();
                    const a = try self.popI64();
                    if (b == 0) return error.BadFormat;
                    try self.push(.{ .i64 = @bitCast(@rem(@as(u64, @bitCast(a)), @as(u64, @bitCast(b)))) });
                },
                0x83 => { // i64.and
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i64 = a & b });
                },
                0x84 => { // i64.or
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i64 = a | b });
                },
                0x85 => { // i64.xor
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i64 = a ^ b });
                },
                0x86 => { // i64.shl
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i64 = @bitCast(@as(u64, @bitCast(a)) << @intCast(@as(u6, @truncate(@as(u64, @bitCast(b)))))) });
                },
                0x88 => { // i64.shr_u
                    const b = try self.popI64();
                    const a = try self.popI64();
                    try self.push(.{ .i64 = @bitCast(@as(u64, @bitCast(a)) >> @intCast(@as(u6, @truncate(@as(u64, @bitCast(b)))))) });
                },
                0xAD => { // i64.extend_i32_u
                    const v = try self.popI32();
                    try self.push(.{ .i64 = @bitCast(@as(u64, @as(u32, @bitCast(v)))) });
                },
                else => {
                    std.debug.print("unsupported opcode 0x{X:0>2} at pc {d}\n", .{ op, pc - 1 });
                    return error.UnsupportedOpcode;
                },
            }
        }
    }

    /// Resolve a br depth: pop the target frame and all inner frames, and
    /// return the pc to continue at (null if it exits the function).
    /// depth is relative to the current function's control frames, not the
    /// global control stack (which may include outer call frames).
    fn brTarget(self: *Runtime, depth: u32) ParseError!?usize {
        const frame = &self.frames.items[self.frames.items.len - 1];
        const base = frame.controls_base;
        const n = self.controls.items.len - base; // frames in current function
        if (depth >= n) return null; // exits function
        const c = self.controls.items[base + n - 1 - depth];
        const keep = base + n - 1 - depth; // absolute index of target frame
        // trim the value stack to the target's entry height (+ results)
        const target_height = c.stack_height;
        switch (c.kind) {
            .loop => {
                // keep the loop frame itself, drop inner frames
                while (self.controls.items.len > keep + 1) _ = self.controls.pop();
                // keep the branch operands (loop params) — trim to entry height
                while (self.stack.items.len > target_height) _ = self.stack.pop();
                return c.start_pc;
            },
            .block, .if_ => {
                // drop the target frame and all inner frames
                while (self.controls.items.len > keep) _ = self.controls.pop();
                while (self.stack.items.len > target_height) _ = self.stack.pop();
                return c.end_pc + 1; // skip past the end opcode
            },
        }
    }

    /// Call an exported function by name. Args are pushed in order.
    pub fn callExport(self: *Runtime, name: []const u8, args: []const Value) ParseError![]Value {
        const e = self.module.findExport(name) orelse return error.BadFormat;
        if (e.kind != 0) return error.BadFormat; // must be a function
        // push args in natural order (arg0 deepest, matching internal calls)
        for (args) |a| try self.push(a);
        try self.callFunc(e.index);
        const ft = self.module.types[self.module.funcs[e.index].type_idx];
        const nres = ft.results.len;
        var results = std.ArrayList(Value).init(self.alloc);
        defer results.deinit();
        var r: usize = 0;
        while (r < nres) : (r += 1) {
            try results.append(try self.pop());
        }
        // reverse results
        var rev = std.ArrayList(Value).init(self.alloc);
        defer rev.deinit();
        var j: usize = results.items.len;
        while (j > 0) {
            j -= 1;
            try rev.append(results.items[j]);
        }
        return rev.toOwnedSlice();
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "parse rejects bad magic" {
    var m: Module = undefined;
    _ = &m;
    try testing.expectError(error.InvalidMagic, parse(testing.allocator, "NOPE"));
}

test "leb128 decoding" {
    var pos: usize = 0;
    const data = [_]u8{ 0x86, 0x80, 0x80, 0x80, 0x00 };
    const v = try readU32(&data, &pos);
    try testing.expectEqual(@as(u32, 6), v);
    try testing.expectEqual(@as(usize, 5), pos);
}
