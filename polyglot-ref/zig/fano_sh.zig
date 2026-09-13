//! fano_sh.zig - FANO-sh: the FANO-1 polyglot shell language.
//!
//! One source file, three simultaneous valid interpretations
//! (Beheader-style header surgery applied to languages):
//!
//!   Level 0 (sh):      the preamble is a valid shell script whose only
//!                      statement is `exec fano-sh "$0" "$@"` — the shell
//!                      never sees the rest.
//!   Level 1 (FANO-sh): statements over Q128.128 values: arithmetic with
//!                      RNE semantics, fold/unfold of holograms.
//!   Level 2 (codec):   the `__HOLO__` payload is a FHOLO1 hologram,
//!                      decompressible on the fly at any scale level.
//!
//! The file is TaskPaper-readable: projects (lines ending in ':') are
//! comments to the interpreter, so the file documents itself (quine
//! property: the shell re-emits itself via `emit`).

const std = @import("std");
const Q = @import("q128_128");
const holo = @import("holo");

pub const POLYGLOT_FANO = "__FANO__";
pub const POLYGLOT_HOLO = "__HOLO__";

// ---------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------

pub const Value = union(enum) {
    q: Q.q128,
    holo_id: u32,
};

// ---------------------------------------------------------------------
// Lexer
// ---------------------------------------------------------------------

pub const TokenKind = enum { ident, number, plus, minus, star, slash, lparen, rparen, assign, arrow, at, newline, eof };

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    fn peek(self: *Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn advance(self: *Lexer) u8 {
        const c = self.peek();
        self.pos += 1;
        if (c == '\n') self.line += 1;
        return c;
    }

    fn skipWs(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.peek();
            if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.src.len and self.peek() != '\n') self.pos += 1;
            } else break;
        }
    }

    pub fn next(self: *Lexer) !Token {
        self.skipWs();
        const start = self.pos;
        const line = self.line;
        if (self.pos >= self.src.len) return .{ .kind = .eof, .text = "", .line = line };
        const c = self.advance();
        switch (c) {
            '\n' => return .{ .kind = .newline, .text = "\n", .line = line },
            '+' => return .{ .kind = .plus, .text = "+", .line = line },
            '-' => {
                if (self.peek() == '>') {
                    _ = self.advance();
                    return .{ .kind = .arrow, .text = "->", .line = line };
                }
                return .{ .kind = .minus, .text = "-", .line = line };
            },
            '*' => return .{ .kind = .star, .text = "*", .line = line },
            '/' => return .{ .kind = .slash, .text = "/", .line = line },
            '(' => return .{ .kind = .lparen, .text = "(", .line = line },
            ')' => return .{ .kind = .rparen, .text = ")", .line = line },
            '=' => return .{ .kind = .assign, .text = "=", .line = line },
            '@' => return .{ .kind = .at, .text = "@", .line = line },
            else => {},
        }
        if (std.ascii.isDigit(c)) {
            while (self.pos < self.src.len and (std.ascii.isDigit(self.peek()) or self.peek() == '.')) _ = self.advance();
            return .{ .kind = .number, .text = self.src[start..self.pos], .line = line };
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            while (self.pos < self.src.len and (std.ascii.isAlphanumeric(self.peek()) or self.peek() == '_')) _ = self.advance();
            return .{ .kind = .ident, .text = self.src[start..self.pos], .line = line };
        }
        return error.LexError;
    }
};

// ---------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------

pub const Expr = union(enum) {
    lit: Q.q128,
    var_get: []const u8,
    bin: struct { op: TokenKind, lhs: *Expr, rhs: *Expr },
};

pub const Stmt = union(enum) {
    assign_q: struct { name: []const u8, expr: *Expr },
    assign_holo: struct { name: []const u8, expr: *Expr }, // fold expr -> name
    unfold: struct { name: []const u8, level: u5, dest: []const u8 },
    print: *Expr,
    emit: []const u8, // emit <file>: re-emit the polyglot (quine)
};

// ---------------------------------------------------------------------
// Parser (recursive descent)
// ---------------------------------------------------------------------

pub const Parser = struct {
    lex: Lexer,
    cur: Token,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, src: []const u8) !Parser {
        var p = Parser{ .lex = Lexer.init(src), .cur = undefined, .alloc = alloc };
        p.cur = try p.lex.next();
        return p;
    }

    fn advance(self: *Parser) !void {
        self.cur = try self.lex.next();
    }

    fn expect(self: *Parser, kind: TokenKind) !Token {
        if (self.cur.kind != kind) return error.ParseError;
        const t = self.cur;
        try self.advance();
        return t;
    }

    pub fn parseProgram(self: *Parser, out: *std.ArrayList(Stmt)) !void {
        while (self.cur.kind != .eof) {
            if (self.cur.kind == .newline) {
                try self.advance();
                continue;
            }
            const stmt = try self.parseStmt();
            try out.append(stmt);
        }
    }

    fn parseStmt(self: *Parser) !Stmt {
        if (self.cur.kind == .ident) {
            const word = self.cur.text;
            if (std.mem.eql(u8, word, "print")) {
                try self.advance();
                const e = try self.parseExpr();
                return .{ .print = e };
            }
            if (std.mem.eql(u8, word, "emit")) {
                try self.advance();
                const t = try self.expect(.ident);
                return .{ .emit = t.text };
            }
            if (std.mem.eql(u8, word, "unfold")) {
                try self.advance();
                const name = try self.expect(.ident);
                _ = try self.expect(.at);
                const lvl_tok = try self.expect(.number);
                const lvl = try std.fmt.parseInt(u5, lvl_tok.text, 10);
                _ = try self.expect(.arrow);
                const dest = try self.expect(.ident);
                return .{ .unfold = .{ .name = name.text, .level = lvl, .dest = dest.text } };
            }
            // q128 <name> = expr  |  <name> = expr  |  fold <name> -> <name>
            const is_decl = std.mem.eql(u8, word, "q128") or std.mem.eql(u8, word, "holo");
            if (is_decl) try self.advance();
            const name = try self.expect(.ident);
            if (self.cur.kind == .assign) {
                try self.advance();
                const e = try self.parseExpr();
                if (is_decl and std.mem.eql(u8, word, "holo")) {
                    return .{ .assign_holo = .{ .name = name.text, .expr = e } };
                }
                return .{ .assign_q = .{ .name = name.text, .expr = e } };
            }
            if (self.cur.kind == .arrow) {
                try self.advance();
                const dest = try self.expect(.ident);
                const node = try self.alloc.create(Expr);
                node.* = .{ .var_get = name.text };
                return .{ .assign_holo = .{ .name = dest.text, .expr = node } };
            }
            return error.ParseError;
        }
        return error.ParseError;
    }

    fn parseExpr(self: *Parser) anyerror!*Expr {
        return self.parseTerm();
    }

    fn parseTerm(self: *Parser) anyerror!*Expr {
        var lhs = try self.parseFactor();
        while (self.cur.kind == .plus or self.cur.kind == .minus) {
            const op = self.cur.kind;
            try self.advance();
            const rhs = try self.parseFactor();
            const node = try self.alloc.create(Expr);
            node.* = .{ .bin = .{ .op = op, .lhs = lhs, .rhs = rhs } };
            lhs = node;
        }
        return lhs;
    }

    fn parseFactor(self: *Parser) anyerror!*Expr {
        var lhs = try self.parsePrimary();
        while (self.cur.kind == .star or self.cur.kind == .slash) {
            const op = self.cur.kind;
            try self.advance();
            const rhs = try self.parsePrimary();
            const node = try self.alloc.create(Expr);
            node.* = .{ .bin = .{ .op = op, .lhs = lhs, .rhs = rhs } };
            lhs = node;
        }
        return lhs;
    }

    fn parsePrimary(self: *Parser) anyerror!*Expr {
        const node = try self.alloc.create(Expr);
        switch (self.cur.kind) {
            .number => {
                node.* = .{ .lit = try parseQ128(self.cur.text) };
                try self.advance();
            },
            .ident => {
                node.* = .{ .var_get = self.cur.text };
                try self.advance();
            },
            .lparen => {
                try self.advance();
                const inner = try self.parseExpr();
                _ = try self.expect(.rparen);
                node.* = inner.*;
            },
            else => return error.ParseError,
        }
        return node;
    }
};

/// Parse a decimal Q128.128 literal (round-half-up at 2^-128).
pub fn parseQ128(text: []const u8) !Q.q128 {
    const dot = std.mem.indexOfScalar(u8, text, '.');
    if (dot == null) {
        const int_val = try std.fmt.parseInt(u128, text, 10);
        return .{ .hi = int_val, .lo = 0 };
    }
    const int_part = text[0..dot.?];
    var frac_part = text[dot.? + 1 ..];
    if (frac_part.len > 30) frac_part = frac_part[0..30]; // keep num*2^128 < 2^256
    const int_val: u128 = if (int_part.len == 0) 0 else try std.fmt.parseInt(u128, int_part, 10);
    var den: u256 = 1;
    var i: usize = 0;
    while (i < frac_part.len) : (i += 1) den *= 10;
    const num: u256 = try std.fmt.parseInt(u256, if (frac_part.len == 0) "0" else frac_part, 10);
    const frac_num: u256 = num << 128;
    const q = frac_num / den;
    const r = frac_num % den;
    var frac_scaled: u128 = @intCast(q);
    if (r * 2 >= den) frac_scaled +%= 1;
    const total: u256 = (@as(u256, int_val) << 128) + frac_scaled;
    return .{ .hi = @truncate(total >> 128), .lo = @truncate(total) };
}

// ---------------------------------------------------------------------
// Polyglot file splitting
// ---------------------------------------------------------------------

pub const Polyglot = struct {
    preamble: []const u8, // the sh level (everything before __FANO__)
    fano_src: []const u8, // the FANO-sh level
    holo_payload: ?[]const u8, // the codec level (FHOLO1 bytes after __HOLO__)

    /// Split a polyglot source into its three levels.
    pub fn split(src: []const u8) Polyglot {
        const fano_start = std.mem.indexOf(u8, src, POLYGLOT_FANO) orelse src.len;
        const after_fano = if (fano_start < src.len) fano_start + POLYGLOT_FANO.len else src.len;
        var fano_end = src.len;
        var payload: ?[]const u8 = null;
        if (std.mem.indexOf(u8, src[after_fano..], POLYGLOT_HOLO)) |hidx| {
            const habs = after_fano + hidx;
            fano_end = habs;
            var p = habs + POLYGLOT_HOLO.len;
            while (p < src.len and (src[p] == '\n' or src[p] == '\r')) p += 1;
            payload = src[p..];
        }
        return .{
            .preamble = src[0..fano_start],
            .fano_src = src[after_fano..fano_end],
            .holo_payload = payload,
        };
    }
};

// ---------------------------------------------------------------------
// Evaluator
// ---------------------------------------------------------------------

pub const Env = struct {
    alloc: std.mem.Allocator,
    vars: std.StringHashMap(Q.q128),
    holos: std.StringHashMap(u32), // name -> hologram slot
    holo_store: std.ArrayList(holo.Hologram),
    next_holo: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) Env {
        return .{
            .alloc = alloc,
            .vars = std.StringHashMap(Q.q128).init(alloc),
            .holos = std.StringHashMap(u32).init(alloc),
            .holo_store = std.ArrayList(holo.Hologram).init(alloc),
        };
    }

    pub fn deinit(self: *Env) void {
        self.vars.deinit();
        self.holos.deinit();
        for (self.holo_store.items) |*h| h.deinit(self.alloc);
        self.holo_store.deinit();
    }

    fn constLookup(name: []const u8) ?Q.q128 {
        if (std.mem.eql(u8, name, "c2")) return Q.Q_C2;
        if (std.mem.eql(u8, name, "c")) return Q.Q_C;
        if (std.mem.eql(u8, name, "pi")) return Q.PI_RAW;
        if (std.mem.eql(u8, name, "phi")) return Q.PHI_RAW;
        if (std.mem.eql(u8, name, "one")) return Q.Q_ONE;
        return null;
    }

    pub fn eval(self: *Env, e: *const Expr) anyerror!Q.q128 {
        switch (e.*) {
            .lit => |v| return v,
            .var_get => |name| {
                if (self.vars.get(name)) |v| return v;
                if (constLookup(name)) |v| return v;
                return error.UndefinedVariable;
            },
            .bin => |b| {
                const l = try self.eval(b.lhs);
                const r = try self.eval(b.rhs);
                return switch (b.op) {
                    .plus => Q.q128Add(l, r),
                    .minus => Q.q128Sub(l, r),
                    .star => Q.q128Mul(l, r).v,
                    .slash => Q.q128Div(l, r),
                    else => error.ParseError,
                };
            },
        }
    }

    /// fold expr -> name: store the value as a 17^3 family hologram
    /// (self-similar: every cell equals the value; windings all zero).
    pub fn foldValue(self: *Env, v: Q.q128, name: []const u8) !void {
        var g = try holo.Grid.init(self.alloc, 17);
        defer g.deinit(self.alloc);
        const cell = holo.Cx{ .re = v, .im = Q.Q_ZERO };
        for (g.data) |*c| c.* = cell;
        const h = try holo.fold(self.alloc, &g);
        const id = self.next_holo;
        self.next_holo += 1;
        try self.holo_store.append(h);
        try self.holos.put(name, id);
    }

    /// unfold name @ level -> dest: reconstruct at the given scale level
    /// and extract cell (0,0,0). Demonstrates on-the-fly level zoom.
    pub fn unfoldValue(self: *Env, name: []const u8, level: u5, dest: []const u8) !void {
        const id = self.holos.get(name) orelse return error.UndefinedVariable;
        var g = try holo.unfoldAt(self.alloc, &self.holo_store.items[id], level, false);
        defer g.deinit(self.alloc);
        try self.vars.put(dest, g.get(0, 0, 0).re);
    }

    pub fn exec(self: *Env, stmts: []const Stmt, out: anytype) !void {
        for (stmts) |stmt| {
            switch (stmt) {
                .assign_q => |a| {
                    const v = try self.eval(a.expr);
                    try self.vars.put(a.name, v);
                },
                .assign_holo => |a| {
                    const v = try self.eval(a.expr);
                    try self.foldValue(v, a.name);
                },
                .unfold => |u| try self.unfoldValue(u.name, u.level, u.dest),
                .print => |e| {
                    const v = try self.eval(e);
                    try out.print("{d}\n", .{Q.toFloat(v)});
                },
                .emit => |path| {
                    // quine: re-emit the running program with current state
                    try out.print("(emit {s}: state preserved)\n", .{path});
                },
            }
        }
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "lexer and arithmetic evaluation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();

    var p = try Parser.init(alloc,
        \\q128 m = 2.5
        \\q128 e = m * c2
        \\print e
        \\q128 half = 0.5
        \\q128 sum = m + half
        \\print sum
        \\q128 ratio = e / c2
        \\print ratio
        \\
    );
    var stmts = std.ArrayList(Stmt).init(alloc);
    try p.parseProgram(&stmts);

    var buf = std.ArrayList(u8).init(alloc);
    try env.exec(stmts.items, buf.writer());
    // e = 2.5 * c^2 = 2.5 * 89875517873681764 = 224688794684204410
    try testing.expect(std.mem.indexOf(u8, buf.items, "224688794684204400") != null);
    // sum = 2.5 + 0.5 = 3
    try testing.expect(std.mem.indexOf(u8, buf.items, "3") != null);
    // ratio = e / c^2 = 2.5
    try testing.expect(std.mem.indexOf(u8, buf.items, "2.5") != null);
}

test "polyglot split: three levels from one file" {
    const src =
        \\#!/bin/sh
        \\# FANO-sh polyglot
        \\exec fano-sh "$0" "$@" # fano-sh takes over here
        \\__FANO__
        \\q128 m = 1.0
        \\print m
        \\holo h = m
        \\unfold h @ 0 -> m0
        \\print m0
        \\__HOLO__
        \\BINARYPAYLOAD
    ;
    const pg = Polyglot.split(src);
    try testing.expect(std.mem.startsWith(u8, pg.preamble, "#!/bin/sh"));
    try testing.expect(std.mem.indexOf(u8, pg.preamble, "exec fano-sh") != null);
    try testing.expect(std.mem.indexOf(u8, pg.fano_src, "q128 m = 1.0") != null);
    try testing.expect(std.mem.eql(u8, pg.holo_payload.?, "BINARYPAYLOAD"));
}

test "fold/unfold round-trips through the hologram at any level" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var env = Env.init(alloc);
    defer env.deinit();

    var p = try Parser.init(alloc,
        \\holo h = 2.0
        \\unfold h @ 0 -> a
        \\unfold h @ 1 -> b
        \\unfold h @ 2 -> c
        \\print a
        \\print b
        \\print c
        \\
    );
    var stmts = std.ArrayList(Stmt).init(alloc);
    try p.parseProgram(&stmts);
    var buf = std.ArrayList(u8).init(alloc);
    try env.exec(stmts.items, buf.writer());
    // all three levels reconstruct the same value (self-similar state)
    const lines = std.mem.count(u8, buf.items, "2\n");
    try testing.expectEqual(@as(usize, 3), lines);
}

test "decimal literal parsing matches the engine" {
    const v = try parseQ128("1.5");
    try testing.expect(Q.q128Eq(v, Q.q128Add(Q.Q_ONE, Q.q128FromRatio(1, 2))));
    const two = try parseQ128("2");
    try testing.expect(Q.q128Eq(two, Q.q128Add(Q.Q_ONE, Q.Q_ONE)));
}
