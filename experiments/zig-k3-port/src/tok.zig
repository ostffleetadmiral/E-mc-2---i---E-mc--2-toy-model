//! tok.zig - byte-level BPE tokenizer (cl100k / o200k / tiktoken families).
//!
//! Ported from third_party/tok.h: a faithful reimplementation of HuggingFace
//! tokenizer.json semantics — BPE with ignore_merges, byte_fallback=false,
//! regex Split pre-tokenizer + ByteLevel(add_prefix_space=false), added tokens
//! atomic in both directions.
//!
//! Kimi K3 ships no tokenizer.json; src/tok_loader.zig populates this struct
//! directly from tiktoken.model + tokenizer_config.json (tok_load is ported
//! too, for parity and tools). The three documented load-time invariants live
//! there; the encode/decode invariants live here:
//!   - the vocab key is the BYTE-LEVEL string (byte2str), never raw bytes;
//!   - rankbpe=1 means merges come from lowest vocab id of the concatenation,
//!     exactly tiktoken's byte_pair_encode;
//!   - the pre-tokenizer alternatives are tried IN ORDER; an earlier match
//!     wins even where a later alternative would match longer.

const std = @import("std");
const uni = @import("tok_unicode.zig");
const json = @import("json");

const Allocator = std.mem.Allocator;

pub const Special = struct { str: []const u8, id: i32 };

pub const Tok = struct {
    arena_impl: std.heap.ArenaAllocator,
    scratch_impl: std.heap.ArenaAllocator,
    vocab: std.StringHashMap(i32), // byte-level string -> id
    merges: std.StringHashMap(i32), // "left\0right" -> rank (unused when rankbpe)
    id2str: [][]const u8, // id -> byte-level string; added tokens map to their literal content
    id_added: []bool, // emitted literally (all added tokens)
    id_special: []bool, // "special": true subset — control tokens, never response content
    sp: []Special, // added tokens sorted by descending length
    byte2cp: [256]u32,
    byte2cp_len: [256]u8,
    byte2str: [256][4]u8,
    cp2byte: [1024]i16,
    o200k: bool = false, // pre-tokenizer family: false = cl100k
    kimi: bool = false, // Kimi (K3): o200k + leading \p{Han} rule, Han out of letter classes
    rankbpe: bool = false, // no merges list: merge the pair whose concatenation has lowest vocab id

    pub fn init(backing: Allocator) !*Tok {
        const t = try backing.create(Tok);
        t.* = .{
            .arena_impl = std.heap.ArenaAllocator.init(backing),
            .scratch_impl = std.heap.ArenaAllocator.init(backing),
            .vocab = undefined,
            .merges = undefined,
            .id2str = &.{},
            .id_added = &.{},
            .id_special = &.{},
            .sp = &.{},
            .byte2cp = undefined,
            .byte2cp_len = undefined,
            .byte2str = undefined,
            .cp2byte = undefined,
        };
        t.vocab = std.StringHashMap(i32).init(t.arena());
        t.merges = std.StringHashMap(i32).init(t.arena());
        return t;
    }

    pub fn arena(self: *Tok) Allocator {
        return self.arena_impl.allocator();
    }

    pub fn scratch(self: *Tok) Allocator {
        return self.scratch_impl.allocator();
    }

    /// Long-lived backing allocator the arena was built on — for objects that
    /// must outlive the Tokenizer itself (none currently; kept for callers).
    pub fn deinit(self: *Tok, backing: Allocator) void {
        self.arena_impl.deinit();
        self.scratch_impl.deinit();
        backing.destroy(self);
    }

    // ---------------- UTF-8 (identical semantics to C u8_next/u8_put) -------
    /// Next codepoint; invalid sequences decode as ONE byte, matching the C
    /// fallback that keeps byte-level round-trips total.
    pub fn u8Next(s: []const u8, i: usize) struct { cp: u32, len: usize } {
        const c = s[i];
        if (c < 0x80) return .{ .cp = c, .len = 1 };
        if ((c >> 5) == 0x6 and i + 1 < s.len)
            return .{ .cp = (@as(u32, c & 0x1F) << 6) | (s[i + 1] & 0x3F), .len = 2 };
        if ((c >> 4) == 0xE and i + 2 < s.len)
            return .{ .cp = (@as(u32, c & 0x0F) << 12) | (@as(u32, s[i + 1] & 0x3F) << 6) | (s[i + 2] & 0x3F), .len = 3 };
        if ((c >> 3) == 0x1E and i + 3 < s.len)
            return .{ .cp = (@as(u32, c & 0x07) << 18) | (@as(u32, s[i + 1] & 0x3F) << 12) | (@as(u32, s[i + 2] & 0x3F) << 6) | (s[i + 3] & 0x3F), .len = 4 };
        return .{ .cp = c, .len = 1 }; // invalid byte: single unit
    }

    fn u8Put(o: *[4]u8, cp: u32) u8 {
        if (cp < 0x80) {
            o[0] = @intCast(cp);
            return 1;
        }
        if (cp < 0x800) {
            o[0] = 0xC0 | @as(u8, @intCast(cp >> 6));
            o[1] = 0x80 | @as(u8, @intCast(cp & 0x3F));
            return 2;
        }
        if (cp < 0x10000) {
            o[0] = 0xE0 | @as(u8, @intCast(cp >> 12));
            o[1] = 0x80 | @as(u8, @intCast((cp >> 6) & 0x3F));
            o[2] = 0x80 | @as(u8, @intCast(cp & 0x3F));
            return 3;
        }
        o[0] = 0xF0 | @as(u8, @intCast(cp >> 18));
        o[1] = 0x80 | @as(u8, @intCast((cp >> 12) & 0x3F));
        o[2] = 0x80 | @as(u8, @intCast((cp >> 6) & 0x3F));
        o[3] = 0x80 | @as(u8, @intCast(cp & 0x3F));
        return 4;
    }

    // ---------- the GPT-2/ByteLevel byte <-> unicode map --------------------
    pub fn buildBytemap(t: *Tok) void {
        for (&t.cp2byte) |*c| c.* = -1;
        var isdir = [_]bool{false} ** 256;
        for (33..127) |b| isdir[b] = true;
        for (161..173) |b| isdir[b] = true;
        for (174..256) |b| isdir[b] = true;
        var n: u32 = 0;
        for (0..256) |b| {
            const cp: u32 = if (isdir[b]) @intCast(b) else 256 + n;
            if (!isdir[b]) n += 1;
            t.byte2cp[b] = cp;
            t.byte2cp_len[b] = u8Put(&t.byte2str[b], cp);
            if (cp < 1024) t.cp2byte[cp] = @intCast(b);
        }
    }

    // ---------- BPE over one piece -----------------------------------------
    // piece bytes [a,b) -> ids appended to out (bounded by out.len).
    fn bpePiece(t: *Tok, p: []const u8, a: usize, b: usize, out: []i32, no: *usize) !void {
        const a8 = t.scratch();
        // byte-level string: <= 2 bytes per input byte
        var s = try a8.alloc(u8, 2 * (b - a) + 1);
        var sl: usize = 0;
        for (p[a..b]) |bb| {
            @memcpy(s[sl .. sl + t.byte2cp_len[bb]], t.byte2str[bb][0..t.byte2cp_len[bb]]);
            sl += t.byte2cp_len[bb];
        }
        s = s[0..sl];
        // ignore_merges: whole piece is itself a token -> emit directly
        if (t.vocab.get(s)) |whole| {
            if (no.* < out.len) {
                out[no.*] = whole;
                no.* += 1;
            }
            return;
        }
        // initial symbols = codepoints of the byte-level string
        const ns_cap = sl + 1;
        const soff = try a8.alloc(usize, ns_cap);
        const slen = try a8.alloc(usize, ns_cap);
        var ns: usize = 0;
        var i: usize = 0;
        while (i < sl) {
            const nxt = u8Next(s, i);
            soff[ns] = i;
            slen[ns] = nxt.len;
            ns += 1;
            i += nxt.len;
        }
        const kbuf = try a8.alloc(u8, 2 * sl + 2);
        while (true) {
            var best: i32 = std.math.maxInt(i32);
            var bp: i32 = -1;
            var j: usize = 0;
            while (j + 1 < ns) : (j += 1) {
                const ll = slen[j];
                const rl = slen[j + 1];
                var rk: i32 = -1;
                if (t.rankbpe) {
                    // tiktoken: rank of the CONCATENATION (contiguous in s)
                    if (t.vocab.get(s[soff[j] .. soff[j] + ll + rl])) |r| rk = r;
                } else {
                    @memcpy(kbuf[0..ll], s[soff[j] .. soff[j] + ll]);
                    kbuf[ll] = 0;
                    @memcpy(kbuf[ll + 1 .. ll + 1 + rl], s[soff[j + 1] .. soff[j + 1] + rl]);
                    if (t.merges.get(kbuf[0 .. ll + 1 + rl])) |r| rk = r;
                }
                if (rk >= 0 and rk < best) {
                    best = rk;
                    bp = @intCast(j);
                }
            }
            if (bp < 0) break;
            const bpu: usize = @intCast(bp);
            slen[bpu] = soff[bpu + 1] + slen[bpu + 1] - soff[bpu];
            var j2 = bpu + 1;
            while (j2 < ns - 1) : (j2 += 1) {
                soff[j2] = soff[j2 + 1];
                slen[j2] = slen[j2 + 1];
            }
            ns -= 1;
        }
        for (0..ns) |j| {
            if (t.vocab.get(s[soff[j] .. soff[j] + slen[j]])) |id| {
                if (no.* < out.len) {
                    out[no.*] = id;
                    no.* += 1;
                }
            }
        }
    }

    // ---------- pre-tokenizers --------------------------------------------
    fn isNL(c: u32) bool {
        return c == '\r' or c == '\n';
    }
    fn low(c: u32) u32 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }

    /// Decode the byte span into codepoints plus byte offsets (shared by the
    /// three pre-tokenizers). Returned slices live in the scratch arena.
    fn decodeSpan(t: *Tok, p: []const u8, a: usize, b: usize) !struct { cp: []u32, off: []usize, n: usize } {
        const a8 = t.scratch();
        const cp = try a8.alloc(u32, (b - a) + 1);
        const off = try a8.alloc(usize, (b - a) + 2);
        var n: usize = 0;
        var i = a;
        while (i < b) {
            const nxt = u8Next(p, i);
            off[n] = i;
            cp[n] = nxt.cp;
            n += 1;
            i += nxt.len;
        }
        off[n] = b;
        return .{ .cp = cp, .off = off, .n = n };
    }

    /// cl100k pattern. Alternatives in order; the order is the spec.
    fn pretokChunk(t: *Tok, p: []const u8, a: usize, b: usize, out: []i32, no: *usize) !void {
        if (b <= a) return;
        const span = try t.decodeSpan(p, a, b);
        const cp, const off, const n = .{ span.cp, span.off, span.n };
        var i: usize = 0;
        while (i < n) {
            const start = i;
            const c = cp[i];
            // 1) (?i:'s|'t|'re|'ve|'m|'ll|'d)
            if (c == '\'' and i + 1 < n) {
                const d = low(cp[i + 1]);
                if (i + 2 < n) {
                    const d2 = low(cp[i + 2]);
                    if ((d == 'r' and d2 == 'e') or (d == 'v' and d2 == 'e') or (d == 'l' and d2 == 'l')) {
                        i += 3;
                        try t.bpePiece(p, off[start], off[i], out, no);
                        continue;
                    }
                }
                if (d == 's' or d == 't' or d == 'm' or d == 'd') {
                    i += 2;
                    try t.bpePiece(p, off[start], off[i], out, no);
                    continue;
                }
            }
            // 2) [^\r\n\p{L}\p{N}]? \p{L}+
            {
                var j: ?usize = i;
                if (!uni.is_L(c) and !isNL(c) and !uni.is_N(c)) {
                    if (i + 1 < n and uni.is_L(cp[i + 1])) j = i + 1 else j = null;
                }
                if (j) |jj| {
                    if (uni.is_L(cp[jj])) {
                        var ju = jj;
                        while (ju < n and uni.is_L(cp[ju])) ju += 1;
                        i = ju;
                        try t.bpePiece(p, off[start], off[i], out, no);
                        continue;
                    }
                }
            }
            // 3) \p{N}{1,3}
            if (uni.is_N(c)) {
                var j = i;
                var k: usize = 0;
                while (j < n and uni.is_N(cp[j]) and k < 3) {
                    j += 1;
                    k += 1;
                }
                i = j;
                try t.bpePiece(p, off[start], off[i], out, no);
                continue;
            }
            // 4) ' ?[^\s\p{L}\p{N}]+[\r\n]*'
            {
                var j = i;
                if (c == ' ' and j + 1 < n and !uni.is_S(cp[j + 1]) and !uni.is_L(cp[j + 1]) and !uni.is_N(cp[j + 1])) j += 1;
                if (j < n and !uni.is_S(cp[j]) and !uni.is_L(cp[j]) and !uni.is_N(cp[j])) {
                    while (j < n and !uni.is_S(cp[j]) and !uni.is_L(cp[j]) and !uni.is_N(cp[j])) j += 1;
                    while (j < n and isNL(cp[j])) j += 1;
                    i = j;
                    try t.bpePiece(p, off[start], off[i], out, no);
                    continue;
                }
            }
            // 5) \s*[\r\n]+  then  6) \s+(?!\S)
            {
                var r = i;
                while (r < n and uni.is_S(cp[r])) r += 1;
                if (r > i) {
                    var last: i64 = -1;
                    for (i..r) |j| {
                        if (isNL(cp[j])) last = @intCast(j);
                    }
                    if (last >= 0) {
                        i = @intCast(last + 1);
                        try t.bpePiece(p, off[start], off[i], out, no);
                        continue;
                    }
                    var end: usize = if (r < n) r - 1 else r;
                    if (end <= i) end = i + 1;
                    i = end;
                    try t.bpePiece(p, off[start], off[i], out, no);
                    continue;
                }
            }
            i += 1; // backstop
            try t.bpePiece(p, off[start], off[i], out, no);
        }
    }

    /// o200k/Kimi shared helpers.
    fn o2S1(c: u32) bool {
        return uni.is_U(c) or uni.is_X(c);
    }
    fn o2S2(c: u32) bool {
        return uni.is_X(c) or (uni.is_L(c) and !uni.is_U(c));
    }
    fn kmS1(c: u32) bool {
        return (uni.is_U(c) or uni.is_X(c)) and !uni.is_Han(c);
    }
    fn kmS2(c: u32) bool {
        return (uni.is_X(c) or (uni.is_L(c) and !uni.is_U(c))) and !uni.is_Han(c);
    }

    fn o2Contraction(cp: []const u32, n: usize, k: usize) usize {
        if (k < n and cp[k] == '\'' and k + 1 < n) {
            const d = low(cp[k + 1]);
            if (k + 2 < n) {
                const e = low(cp[k + 2]);
                if ((d == 'r' and e == 'e') or (d == 'v' and e == 'e') or (d == 'l' and e == 'l')) return k + 3;
            }
            if (d == 's' or d == 't' or d == 'm' or d == 'd') return k + 2;
        }
        return k;
    }

    /// End (cp index) of branch A|B match at i, or -1. `s1`/`s2` select the
    /// class pair (o200k vs Kimi's Han-masked variants).
    fn lettersEnd(cp: []const u32, n: usize, i: usize, comptime s1: fn (u32) bool, comptime s2: fn (u32) bool) i64 {
        // branch A, prefix greedy then without
        var pfx: i32 = 1;
        while (pfx >= 0) : (pfx -= 1) {
            var j0 = i;
            if (pfx == 1) {
                const c = cp[i];
                if (isNL(c) or uni.is_L(c) or uni.is_N(c) or i + 1 >= n) continue;
                j0 = i + 1;
            }
            var m1 = j0;
            while (m1 < n and s1(cp[m1])) m1 += 1;
            var s = m1;
            while (s >= j0) : (s -= 1) {
                if (s < n and s2(cp[s])) {
                    var k = s + 1;
                    while (k < n and s2(cp[k])) k += 1;
                    return @intCast(o2Contraction(cp, n, k));
                }
                if (s == 0) break;
            }
        }
        // branch B
        pfx = 1;
        while (pfx >= 0) : (pfx -= 1) {
            var j0 = i;
            if (pfx == 1) {
                const c = cp[i];
                if (isNL(c) or uni.is_L(c) or uni.is_N(c) or i + 1 >= n) continue;
                j0 = i + 1;
            }
            var m1 = j0;
            while (m1 < n and s1(cp[m1])) m1 += 1;
            if (m1 > j0) {
                var k = m1;
                while (k < n and s2(cp[k])) k += 1;
                return @intCast(o2Contraction(cp, n, k));
            }
        }
        return -1;
    }

    fn pretokO200k(t: *Tok, p: []const u8, a: usize, b: usize, out: []i32, no: *usize) !void {
        if (b <= a) return;
        const span = try t.decodeSpan(p, a, b);
        const cp, const off, const n = .{ span.cp, span.off, span.n };
        var i: usize = 0;
        while (i < n) {
            const start = i;
            const c = cp[i];
            // A|B letter runs with case-aware split
            {
                const e = lettersEnd(cp, n, i, o2S1, o2S2);
                if (e > @as(i64, @intCast(i))) {
                    i = @intCast(e);
                    try t.bpePiece(p, off[start], off[i], out, no);
                    continue;
                }
            }
            // C: \p{N}{1,3}
            if (uni.is_N(c)) {
                var j = i;
                var k: usize = 0;
                while (j < n and uni.is_N(cp[j]) and k < 3) {
                    j += 1;
                    k += 1;
                }
                i = j;
                try t.bpePiece(p, off[start], off[i], out, no);
                continue;
            }
            // D: ' ?[^\s\p{L}\p{N}]+[\r\n/]*'
            {
                var j = i;
                if (c == ' ' and j + 1 < n and !uni.is_S(cp[j + 1]) and !uni.is_L(cp[j + 1]) and !uni.is_N(cp[j + 1])) j += 1;
                if (j < n and !uni.is_S(cp[j]) and !uni.is_L(cp[j]) and !uni.is_N(cp[j])) {
                    while (j < n and !uni.is_S(cp[j]) and !uni.is_L(cp[j]) and !uni.is_N(cp[j])) j += 1;
                    while (j < n and (isNL(cp[j]) or cp[j] == '/')) j += 1;
                    i = j;
                    try t.bpePiece(p, off[start], off[i], out, no);
                    continue;
                }
            }
            // E/F/G whitespace
            {
                var r = i;
                while (r < n and uni.is_S(cp[r])) r += 1;
                if (r > i) {
                    var last: i64 = -1;
                    for (i..r) |j| {
                        if (isNL(cp[j])) last = @intCast(j);
                    }
                    if (last >= 0) {
                        i = @intCast(last + 1);
                        try t.bpePiece(p, off[start], off[i], out, no);
                        continue;
                    }
                    var end: usize = if (r < n) r - 1 else r;
                    if (end <= i) end = i + 1;
                    i = end;
                    try t.bpePiece(p, off[start], off[i], out, no);
                    continue;
                }
            }
            i += 1;
            try t.bpePiece(p, off[start], off[i], out, no);
        }
    }

    fn pretokKimi(t: *Tok, p: []const u8, a: usize, b: usize, out: []i32, no: *usize) !void {
        if (b <= a) return;
        const span = try t.decodeSpan(p, a, b);
        const cp, const off, const n = .{ span.cp, span.off, span.n };
        var i: usize = 0;
        while (i < n) {
            const start = i;
            const c = cp[i];
            // H: [\p{Han}]+
            if (uni.is_Han(c)) {
                var j = i;
                while (j < n and uni.is_Han(cp[j])) j += 1;
                i = j;
                try t.bpePiece(p, off[start], off[i], out, no);
                continue;
            }
            // A|B letter runs, Han excluded
            {
                const e = lettersEnd(cp, n, i, kmS1, kmS2);
                if (e > @as(i64, @intCast(i))) {
                    i = @intCast(e);
                    try t.bpePiece(p, off[start], off[i], out, no);
                    continue;
                }
            }
            // C: \p{N}{1,3}
            if (uni.is_N(c)) {
                var j = i;
                var k: usize = 0;
                while (j < n and uni.is_N(cp[j]) and k < 3) {
                    j += 1;
                    k += 1;
                }
                i = j;
                try t.bpePiece(p, off[start], off[i], out, no);
                continue;
            }
            // D: ' ?[^\s\p{L}\p{N}]+[\r\n]*'  (no '/' tail, unlike o200k)
            {
                var j = i;
                if (c == ' ' and j + 1 < n and !uni.is_S(cp[j + 1]) and !uni.is_L(cp[j + 1]) and !uni.is_N(cp[j + 1])) j += 1;
                if (j < n and !uni.is_S(cp[j]) and !uni.is_L(cp[j]) and !uni.is_N(cp[j])) {
                    while (j < n and !uni.is_S(cp[j]) and !uni.is_L(cp[j]) and !uni.is_N(cp[j])) j += 1;
                    while (j < n and isNL(cp[j])) j += 1;
                    i = j;
                    try t.bpePiece(p, off[start], off[i], out, no);
                    continue;
                }
            }
            // E/F/G whitespace
            {
                var r = i;
                while (r < n and uni.is_S(cp[r])) r += 1;
                if (r > i) {
                    var last: i64 = -1;
                    for (i..r) |j| {
                        if (isNL(cp[j])) last = @intCast(j);
                    }
                    if (last >= 0) {
                        i = @intCast(last + 1);
                        try t.bpePiece(p, off[start], off[i], out, no);
                        continue;
                    }
                    var end: usize = if (r < n) r - 1 else r;
                    if (end <= i) end = i + 1;
                    i = end;
                    try t.bpePiece(p, off[start], off[i], out, no);
                    continue;
                }
            }
            i += 1;
            try t.bpePiece(p, off[start], off[i], out, no);
        }
    }

    // ---------- encode / decode --------------------------------------------

    /// text -> ids. Added tokens split the text first (longest match wins),
    /// each intervening chunk goes through the family's pre-tokenizer + BPE.
    /// Writes at most out.len ids; returns the count.
    pub fn encode(t: *Tok, text: []const u8, out: []i32) !usize {
        _ = t.scratch_impl.reset(.retain_capacity);
        var no: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            // next added-token occurrence at or after i (longest match)
            var hitpos: i64 = -1;
            var hitlen: usize = 0;
            var hitid: i32 = -1;
            var j = i;
            while (j < text.len and hitpos < 0) : (j += 1) {
                for (t.sp) |sp| {
                    if (sp.str.len > 0 and j + sp.str.len <= text.len and
                        std.mem.eql(u8, text[j .. j + sp.str.len], sp.str))
                    {
                        hitpos = @intCast(j);
                        hitlen = sp.str.len;
                        hitid = sp.id;
                        break;
                    }
                }
            }
            const chunk_end: usize = if (hitpos < 0) text.len else @intCast(hitpos);
            if (chunk_end > i) {
                if (t.kimi) {
                    try t.pretokKimi(text, i, chunk_end, out, &no);
                } else if (t.o200k) {
                    try t.pretokO200k(text, i, chunk_end, out, &no);
                } else {
                    try t.pretokChunk(text, i, chunk_end, out, &no);
                }
            }
            if (hitpos < 0) break;
            if (no < out.len) {
                out[no] = hitid;
                no += 1;
            }
            i = @as(usize, @intCast(hitpos)) + hitlen;
        }
        return no;
    }

    /// id of an added token given its content; -1 if absent.
    pub fn idOf(t: *Tok, content: []const u8) i32 {
        for (t.sp) |sp| {
            if (std.mem.eql(u8, sp.str, content)) return sp.id;
        }
        return -1;
    }

    /// ids -> text: inverse byte-level map; added tokens emit literally.
    /// Returns bytes written into out (out is NOT NUL-terminated by design:
    /// callers treat it as a slice of the returned length).
    pub fn decode(t: *Tok, ids: []const i32, out: []u8) usize {
        var o: usize = 0;
        for (ids) |id| {
            if (id < 0) continue;
            const idx: usize = @intCast(id);
            if (idx >= t.id2str.len) continue;
            const s = t.id2str[idx];
            if (s.len == 0) continue;
            if (t.id_added[idx]) {
                for (s) |ch| {
                    if (o < out.len) {
                        out[o] = ch;
                        o += 1;
                    }
                }
                continue;
            }
            var j: usize = 0;
            while (j < s.len) {
                const nxt = u8Next(s, j);
                j += nxt.len;
                if (nxt.cp < 1024 and t.cp2byte[nxt.cp] >= 0 and o < out.len) {
                    out[o] = @intCast(t.cp2byte[nxt.cp]);
                    o += 1;
                }
            }
        }
        return o;
    }
};

/// tokenizer.json loader (the path K3 never uses — K3 loads tiktoken.model via
/// tok_loader.zig). Ported for parity and tools. Mirrors tok_load: same checks
/// (negative/implausible ids, malformed merges/added), same field semantics.
pub fn loadFromTokenizerJson(t: *Tok, backing: Allocator, path: []const u8) !void {
    t.buildBytemap();
    const buf = try std.fs.cwd().readFileAlloc(backing, path, 1 << 30);
    defer backing.free(buf);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const root = try json.parse(arena.allocator(), buf);
    const model = json.get(root, "model") orelse return error.MissingModel;
    const vocab = json.get(model, "vocab") orelse return error.MissingVocab;
    if (vocab.* != .obj) return error.MissingVocab;
    const merges = json.get(model, "merges");
    const added = json.get(root, "added_tokens");

    var merges_val: ?*const json.Value = merges;
    if (merges == null or merges.?.* != .arr or merges.?.arr.len == 0) {
        t.rankbpe = true;
        merges_val = null;
    }

    var maxid: i64 = 0;
    for (vocab.obj.kids) |kid| {
        const id = kid.asInt() catch return error.BadVocabId;
        if (id < 0) return error.BadVocabId;
        if (id > maxid) maxid = id;
    }
    if (added) |a| {
        if (a.* == .arr) {
            for (a.arr) |kid| {
                const ji = json.get(kid, "id") orelse return error.MalformedAddedToken;
                const id = ji.asInt() catch return error.MalformedAddedToken;
                if (id < 0) return error.BadVocabId;
                if (id > maxid) maxid = id;
            }
        }
    }
    if (maxid > (1 << 21)) return error.ImplausibleVocabId;
    const n_ids: usize = @intCast(maxid + 1);

    const aa = t.arena();
    t.id2str = try aa.alloc([]const u8, n_ids);
    t.id_added = try aa.alloc(bool, n_ids);
    t.id_special = try aa.alloc(bool, n_ids);
    for (t.id2str) |*s| s.* = "";
    @memset(t.id_added, false);
    @memset(t.id_special, false);

    for (vocab.obj.keys, vocab.obj.kids) |k, kid| {
        const id: i32 = @intCast(kid.asInt() catch return error.BadVocabId);
        const key = try aa.dupe(u8, k);
        try t.vocab.put(key, id);
        t.id2str[@intCast(id)] = key;
    }

    if (merges_val) |mv| {
        for (mv.arr, 0..) |pr, rank| {
            // HF ships two merge encodings: ["l","r"] pairs (newer) and
            // "l r" space-joined strings (OLMoE). Byte-level vocab never
            // contains a literal 0x20 (spaces are Ġ), so the split is safe.
            var l: []const u8 = undefined;
            var r: []const u8 = undefined;
            if (pr.* == .arr) {
                if (pr.arr.len < 2) return error.MalformedMerge;
                if (pr.arr[0].* != .str or pr.arr[1].* != .str) return error.MalformedMerge;
                l = pr.arr[0].str;
                r = pr.arr[1].str;
            } else if (pr.* == .str) {
                const sp = std.mem.indexOfScalar(u8, pr.str, ' ') orelse return error.MalformedMerge;
                l = pr.str[0..sp];
                r = pr.str[sp + 1 ..];
            } else return error.MalformedMerge;
            const key = try aa.alloc(u8, l.len + 1 + r.len);
            @memcpy(key[0..l.len], l);
            key[l.len] = 0;
            @memcpy(key[l.len + 1 ..], r);
            try t.merges.put(key, @intCast(rank));
        }
    }

    if (added) |a| {
        if (a.* == .arr) {
            const sp = try aa.alloc(Special, a.arr.len);
            for (a.arr, 0..) |kid, i| {
                const jc = json.get(kid, "content") orelse return error.MalformedAddedToken;
                const ji = json.get(kid, "id") orelse return error.MalformedAddedToken;
                if (jc.* != .str) return error.MalformedAddedToken;
                const id = ji.asInt() catch return error.MalformedAddedToken;
                if (id < 0 or id > maxid) return error.BadVocabId;
                const content = try aa.dupe(u8, jc.str);
                sp[i] = .{ .str = content, .id = @intCast(id) };
                t.id2str[@intCast(id)] = content;
                t.id_added[@intCast(id)] = true;
                if (json.get(kid, "special")) |sf| {
                    if (sf.* == .bool_v and sf.bool_v) t.id_special[@intCast(id)] = true;
                }
            }
            // longest match first
            std.mem.sort(Special, sp, {}, struct {
                fn lt(_: void, x: Special, y: Special) bool {
                    return x.str.len > y.str.len;
                }
            }.lt);
            t.sp = sp;
        }
    }

    // pre-tokenizer family detection
    if (json.get(root, "pre_tokenizer")) |pt| {
        if (json.get(pt, "pretokenizers")) |ps| {
            if (ps.* == .arr) {
                for (ps.arr) |kid| {
                    if (json.get(kid, "pattern")) |pat| {
                        if (json.get(pat, "Regex")) |rx| {
                            if (rx.* == .str) {
                                if (std.mem.indexOf(u8, rx.str, "\\p{Lu}") != null) t.o200k = true;
                                if (std.mem.indexOf(u8, rx.str, "\\p{Han}") != null) t.kimi = true;
                            }
                        }
                    }
                }
            }
        }
    }
}

test "bytemap is a bijection over 256 bytes" {
    var t = try Tok.init(std.testing.allocator);
    defer t.deinit(std.testing.allocator);
    t.buildBytemap();
    var seen = [_]bool{false} ** 1024;
    for (0..256) |b| {
        const cp = t.byte2cp[b];
        try std.testing.expect(!seen[cp]);
        seen[cp] = true;
        try std.testing.expectEqual(@as(i16, @intCast(b)), t.cp2byte[cp]);
    }
}

test "u8Next decodes and tolerates invalid bytes" {
    const s = "héllo"; // h | é(2) | l | l | o
    try std.testing.expectEqual(@as(u32, 'h'), Tok.u8Next(s, 0).cp);
    try std.testing.expectEqual(@as(u32, 0xE9), Tok.u8Next(s, 1).cp);
    try std.testing.expectEqual(@as(usize, 2), Tok.u8Next(s, 1).len);
    // truncated multibyte tail -> single unit
    try std.testing.expectEqual(@as(u32, 0xC3), Tok.u8Next(&[_]u8{0xC3}, 0).cp);
    try std.testing.expectEqual(@as(usize, 1), Tok.u8Next(&[_]u8{0xC3}, 0).len);
}

// tokenizer.json is the GQA-family format (Qwen3/OLMoE ship it; K3 does
// not). Byte-level vocab keys: ASCII printable chars map to themselves,
// space is "Ġ". This fixture exercises vocab+merges+added_tokens through
// the real loader — the same path `k3 <qwen_dir> --tok <dir>` takes.
test "tokenizer.json: load, encode, decode roundtrip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const doc =
        \\{"model":{"type":"BPE","vocab":{"A":0,"B":1,"AB":2,"C":3,
        \\ "Ġ":4,"Ġthe":5,"<|eot|>":6},
        \\ "merges":[["A","B"],["Ġ","the"]]},
        \\ "added_tokens":[{"id":6,"content":"<|eot|>","special":true}],
        \\ "pre_tokenizer":{"type":"ByteLevel"}}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "tokenizer.json", .data = doc });
    var pathbuf: [4096]u8 = undefined;
    const rp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(rp);
    const tj = try std.fmt.bufPrint(&pathbuf, "{s}/tokenizer.json", .{rp});

    var t = try Tok.init(std.testing.allocator);
    defer t.deinit(std.testing.allocator);
    try loadFromTokenizerJson(t, std.testing.allocator, tj);

    // "AB" merges to id 2, lone "C" -> 3, " the" -> Ġthe -> 5
    var out: [16]i32 = undefined;
    const n = try t.encode("ABC the<|eot|>", &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(i32, &[_]i32{ 2, 3, 5, 6 }, out[0..n]);

    var txt: [64]u8 = undefined;
    const tl = t.decode(out[0..n], &txt);
    try std.testing.expectEqualStrings("ABC the<|eot|>", txt[0..tl]);
}
