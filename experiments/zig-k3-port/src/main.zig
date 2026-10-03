//! main.zig - `k3`: run a Kimi K3 checkpoint end to end.
//!
//! Port of .kimi-k3-in-c/src/cli/k3_run.c (1649 lines) onto the native q128
//! stack: same flags, same validation order, same refusal diagnostics, same
//! exit codes:
//!   0  success
//!   1  runtime failure (I/O, bind, forward, memory-plan refusal)
//!   2  usage / refusal before work started
//!   4  routed-expert drops - the produced token ids are CORRUPT
//!
//! Every f32 buffer the C carried is a []Q128 here (32 B/element, exact);
//! the only floating point left is human-facing reporting - budgets, timing,
//! the JSON summary - never inference math.
//!
//! DOCUMENTED DIVERGENCES FROM C
//!   - State-file payloads are Q128 elements, not f32, so the format version
//!     is bumped 1 -> 2: a C-written v1 file is refused by the version check
//!     rather than silently misread, and ours is refused by C likewise.
//!   - `atoi("abc")` == 0 semantics are preserved, but C's --ids loop fills
//!     the 32768-slot prompt with zeros on unparsable input (a strtol quirk);
//!     we emit one 0 per unparsable character instead.
//!   - KV/state/scratch accounting counts q128 elements (32 B) where C
//!     counted f32 (4 B): the refusal budgets are the same ratios, the byte
//!     figures are ours.

const std = @import("std");
const k3 = @import("k3");
const cfg = @import("cfg");
const st = @import("st");
const bind = @import("bind");
const trunk_mod = @import("trunk");
const peersrc = @import("peersrc");
const cache_mod = @import("cache");
const ops = @import("ops");
const model = @import("model");
const sample = @import("sample");
const rev = @import("reversible");
const sched = @import("sched");
const fabexec = @import("fabexec");
const q128 = @import("q128");
const pio = @import("pio");
const tok_mod = @import("tok");
const tok_loader = @import("tok_loader");
const gpu_mod = @import("gpu");
const gqa_cfg = @import("gqa_cfg");
const gqa_bind = @import("gqa_bind");
const model_gqa = @import("model_gqa");
const qwen35_cli = @import("qwen35_cli");

const Q = k3.Q128;
const Allocator = std.mem.Allocator;
const Writer = std.io.AnyWriter;

const VERSION = "1.0.0";
const SPEC_MAX: usize = 8;
pub const STATE_VER: i32 = 2;

const zero = Q{ .raw = 0 };

// ------------------------------------------------------------- helpers ----

var mono: ?std.time.Timer = null;

fn nowS() f64 {
    if (mono == null) mono = std.time.Timer.start() catch return 0;
    return @as(f64, @floatFromInt(mono.?.read())) / 1e9;
}

fn human(b_in: f64, o: []u8) []const u8 {
    const u = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var b = b_in;
    var i: usize = 0;
    while (b >= 1000.0 and i < 4) {
        b /= 1000.0;
        i += 1;
    }
    return std.fmt.bufPrint(o, "{d:.2} {s}", .{ b, u[i] }) catch unreachable;
}

/// atof(3): longest valid prefix, 0 on no conversion.
fn atofC(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    var end = i;
    if (end < s.len and (s[end] == '+' or s[end] == '-')) end += 1;
    var saw_digit = false;
    while (end < s.len and std.ascii.isDigit(s[end])) {
        end += 1;
        saw_digit = true;
    }
    if (end < s.len and s[end] == '.') {
        end += 1;
        while (end < s.len and std.ascii.isDigit(s[end])) {
            end += 1;
            saw_digit = true;
        }
    }
    if (!saw_digit) return 0;
    if (end < s.len and (s[end] == 'e' or s[end] == 'E')) {
        var e = end + 1;
        if (e < s.len and (s[e] == '+' or s[e] == '-')) e += 1;
        var ed = false;
        while (e < s.len and std.ascii.isDigit(s[e])) {
            e += 1;
            ed = true;
        }
        if (ed) end = e;
    }
    return std.fmt.parseFloat(f64, s[i..end]) catch 0;
}

/// atoi(3): leading whitespace, optional sign, digits, stop at first junk.
fn atoiC(s: []const u8) i32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    var v: i64 = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) {
        v = std.math.clamp(v * 10 + (s[i] - '0'), -1 << 40, 1 << 40);
        i += 1;
    }
    if (neg) v = -v;
    return @intCast(std.math.clamp(v, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32))));
}

fn usage(f: Writer) void {
    f.print(
        \\k3 {s}, Kimi K3 inference engine
        \\
        \\usage: k3 <model_dir> [options]
        \\
        \\prompt (exactly one):
        \\  --prompt TEXT         tokenize TEXT and run it
        \\  --prompt-file PATH    read the prompt from a file; use this for non-ASCII, since
        \\                        argv is re-encoded by the shell
        \\  --ids 1,2,3           raw token ids; the reproducible channel used by the tests
        \\  --media PATH          Q35M raw image/video patch tensor for Qwen3.5
        \\  --dump-vision PATH    dump Qwen3.5 visual embeddings as decimal Q128 values
        \\
        \\memory:
        \\  --preset NAME         auto | ultra | laptop | desktop | workstation | server | max
        \\                        auto sizes both budgets from this machine's free RAM,
        \\                        trunk-first; also spelled --trunk-gb auto
        \\  --list-presets        show each preset's split and expected speed
        \\  --trunk DIR           packed trunk directory; enables streaming (see scripts/)
        \\  --trunk-gb X          trunk ring / pinned-layer budget
        \\  --cache-gb X          routed-expert cache budget
        \\  --ultra-low-memory    stream embedding rows and lm_head chunks, and reuse one
        \\                        recurrent-state slot during full recompute; needs --trunk
        \\
        \\generation:
        \\  --gen N               tokens to generate (default 8)
        \\  --incremental         carry KV cache and recurrent state between tokens
        \\  --save-state PATH     write the carried state after the run, so the next turn of a
        \\                        conversation resumes instead of re-reading the whole prompt
        \\  --load-state PATH     resume from a saved state; the prompt given now is treated as
        \\                        the CONTINUATION of the saved sequence. Needs --incremental
        \\  --draft-trunk DIR     hybrid decode: a second packed trunk (typically a quantized
        \\                        derivation of the real one, see tools/qdq_trunk.py) DRAFTS
        \\                        tokens which the exact model verifies in batched sweeps.
        \\                        Output remains exactly the exact model's greedy decode; the
        \\                        draft only proposes. Needs --incremental; implies --spec 4
        \\  --draft-trunk-gb X    trunk budget for the draft model (default 6)
        \\  --spec N              speculative decode: draft up to N tokens by n-gram lookup and
        \\                        verify them in ONE batched sweep. Output is identical to
        \\                        serial decode by construction; needs --incremental. An extra
        \\                        verified position costs ~22% of a serial token when the trunk
        \\                        streams, so repetitive text decodes up to several times faster
        \\  --verify-rewind       tape a per-step receipt (state snapshot + logits fold) and,
        \\                        after decode, replay every taped step in reverse proving the
        \\                        trajectory is exactly recoverable (ADR-0028-style verified
        \\                        replay, NOT a model inverse). Needs --incremental; does not
        \\                        compose with --spec/--draft-trunk
        \\  --rewind-depth N      cap the rewind tape at N steps (default: all generated steps)
        \\  --temperature F       sampling temperature; 0 (default) = exact greedy argmax
        \\  --top-k N             keep only the N largest logits before sampling
        \\  --top-p F             nucleus filter: keep the smallest prefix reaching mass p
        \\  --rep-penalty F       HF repetition penalty (1 = off): positive logits /F,
        \\                        negative *F, applied over the emitted sequence
        \\  --seed N              SplitMix64 seed — same seed ⇒ same stream everywhere.
        \\                        Sampling does not compose with --spec/--draft-trunk.
        \\  --tok DIR             directory with tiktoken.model and tokenizer_config.json
        \\
        \\diagnostics:
        \\  --config PATH         model config; defaults to <model_dir>/config.json
        \\  --layers N            bind only the first N layers (partial shard sets)
        \\  --dump-logits PATH    write float32 logits for the first step
        \\  --dump-cache-trace D  write expert_hist.json and expert_trace.bin into D, for
        \\                        offline analysis with tools/sim_cache.py
        \\  --weights-peer EP     serve safetensors shards from a k3peer endpoint
        \\  --exec-peer LIST      comma-separated k3peer endpoints that compute experts
        \\                      (OP_EXEC: latent vector out, expert output back — the
        \\                      peer holds the weights; falls back to local fetch)
        \\  --key-file PATH       K3P2 PSK (32 raw bytes) for peer transports
        \\  --peer-eph            K3P3 ephemeral-X25519 handshake for peer transports
        \\                        (forward secrecy; mutually exclusive with --key-file)
        \\  --out FILE            JSON results (default k3_run.json)
        \\  --sched-emit FILE     per-token scale-0 scheduler commits as JSONL
        \\                        (Observation→Commit receipts; telemetry only,
        \\                        never alters argmax)
        \\  --version, --help
        \\
        \\Memory is a dial, not a floor: the same model runs in 8 GB and in 224 GB and produces
        \\identical output. Give memory to the trunk before the expert cache, see
        \\docs/TUNING.md for why, and scripts/k3-doctor.sh to size this machine.
        \\
    , .{VERSION}) catch {};
}

// ------------------------------------------------------------- presets ----
// Named memory budgets, so a user does not have to discover the trunk/cache
// split empirically. Every preset fills the trunk before it feeds the cache:
// per token the engine re-reads the ENTIRE trunk but only ~25.8 GB of routed
// experts, and measured on the released checkpoint trunk-first runs 1.69x
// faster than cache-first at a fixed 128 GB (docs/PERFORMANCE.md).

const Preset = struct {
    name: []const u8,
    trunk_gb: f64,
    cache_gb: f64,
    ultra: bool,
    note: []const u8,
};

// The trunk/cache figures are BUDGETS passed to the two allocators; the note
// quotes measured peak RSS for the whole process on the reference machine.
const PRESETS = [_]Preset{
    .{ .name = "ultra", .trunk_gb = 2.5, .cache_gb = 0.31, .ultra = true, .note = "~3 GB planned: streamed model tables, one state slot. Slow." },
    .{ .name = "laptop", .trunk_gb = 3.0, .cache_gb = 1.0, .ultra = false, .note = "8.2 GB peak RSS. The ordinary-path floor." },
    .{ .name = "desktop", .trunk_gb = 16.0, .cache_gb = 10.0, .ultra = false, .note = "31.9 GB peak RSS." },
    .{ .name = "workstation", .trunk_gb = 60.0, .cache_gb = 30.0, .ultra = false, .note = "95.5 GB peak RSS; the expert cache starts to matter here." },
    .{ .name = "server", .trunk_gb = 110.0, .cache_gb = 13.0, .ultra = false, .note = "~128 GB peak RSS; 90 of 93 trunk layers pinned. Fastest." },
    .{ .name = "max", .trunk_gb = 110.0, .cache_gb = 109.0, .ultra = false, .note = "~224 GB peak RSS; trunk pinned and a large expert cache." },
};

fn presetFind(name: []const u8) ?*const Preset {
    for (&PRESETS) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

fn presetList(f: Writer) void {
    f.print("presets (trunk / expert-cache, in GB):\n", .{}) catch {};
    for (&PRESETS) |*p| {
        f.print("  {s: <12} {d: >6.2} / {d: <6.2}  {s}\n", .{ p.name, p.trunk_gb, p.cache_gb, p.note }) catch {};
    }
    f.print("  {s: <12} {s: >6} / {s: <6}  {s}\n", .{ "auto", "fit", "fit", "sizes both from this machine's free RAM, trunk-first. Recommended." }) catch {};
    f.print("\nAll presets stream the trunk, so they need --trunk <packed_dir>.\n" ++
        "Run scripts/k3-doctor.sh to see which one this machine fits.\n", .{}) catch {};
}

// ---------------------------------------------------------------- config ----
// The released constants, kept ONLY as a fallback for runs against a shard
// directory with no config.json (partial fixtures, hand-assembled trunks).
// Every value matches the released config.json, but a hardcoded table cannot
// notice a checkpoint revision - so cfg.loadFile is preferred whenever a
// config is present, and this path announces itself loudly.

fn f32q(bits: u32) Q {
    return Q.fromF32Bits(bits) catch unreachable;
}

/// The released-checkpoint constants. `pub` so tools and the scale test share
/// the one authoritative table rather than drifting copies.
pub fn realCfgHardcoded(c: *k3.K3Cfg) void {
    c.* = .{};
    c.hidden = 7168;
    c.n_layers = 93;
    c.vocab = 163840;
    c.rms_eps = f32q(0x3727c5ac); // 1e-5f
    c.kda_heads = 96;
    c.kda_head_dim = 128;
    c.conv_k = 4;
    c.gate_lb = f32q(0xc0a00000); // -5.0f
    c.n_heads = 96;
    c.q_lora = 1536;
    c.kv_lora = 512;
    c.qk_nope = 128;
    c.qk_rope = 64;
    c.v_head = 128;
    c.mla_out_gate = true;
    c.n_experts = 896;
    c.topk = 16;
    c.n_shared = 2;
    c.latent = 3584;
    c.moe_inter = 3072;
    c.routed_scale = f32q(0x3f800000); // 1.0f
    c.moe_renorm = true;
    c.latent_norm = true;
    c.first_dense = 1;
    c.dense_inter = 33792;
    c.attn_res_block = 12;
    c.situ_b1 = f32q(0x40800000); // 4.0f
    c.situ_b2 = f32q(0x41c80000); // 25.0f
    var n: usize = 0;
    var i: i32 = 4;
    while (i <= 93) : (i += 4) { // config lists are ONE-based
        c.full_attn[n] = i;
        n += 1;
    }
    c.full_attn[n] = 93;
    n += 1;
    c.n_full_attn = @intCast(n);
}

/// Prefer the checkpoint's own config; fall back only when there is none.
/// Returns true on success, false if a config was found but could not be
/// trusted - in that case the caller MUST abort rather than fall back.
fn realCfg(arena: Allocator, c: *k3.K3Cfg, shard_dir: []const u8, cfg_path_opt: ?[]const u8, diag: *cfg.Diag, out: Writer) bool {
    var path_buf: [4096]u8 = undefined;
    var cfg_path = cfg_path_opt;
    if (cfg_path == null) {
        const guess = std.fmt.bufPrint(&path_buf, "{s}/config.json", .{shard_dir}) catch return false;
        if (std.fs.cwd().access(guess, .{})) |_| {
            cfg_path = guess;
        } else |_| {}
    }
    if (cfg_path) |p| {
        cfg.loadFile(c, arena, p, diag) catch {
            out.writeAll(diag.buf.constSlice()) catch {};
            return false;
        };
        out.print("config: {s} ({s} shape) | hidden={d} layers={d} vocab={d} | " ++
            "{d} MLA + {d} KDA | experts {d} top{d} shared{d} | latent={d}\n", .{
            p,             if (diag.nested) "nested" else "flat", c.hidden,    c.n_layers, c.vocab,
            c.n_full_attn, c.n_layers - c.n_full_attn,            c.n_experts, c.topk,     c.n_shared,
            c.latent,
        }) catch {};
        return true;
    }
    realCfgHardcoded(c);
    out.print("config: NO config.json found under {s}\n" ++
        "        falling back to the built-in Kimi K3 constants (93 layers, 24 MLA).\n" ++
        "        These match the released checkpoint but are NOT read from it; pass\n" ++
        "        --config PATH to validate against the real file.\n", .{shard_dir}) catch {};
    return true;
}

fn jsonString(f: anytype, s: ?[]const u8) void {
    if (s == null) {
        f.writeAll("null") catch {};
        return;
    }
    f.writeByte('"') catch {};
    for (s.?) |ch| {
        switch (ch) {
            '"' => f.writeAll("\\\"") catch {},
            '\\' => f.writeAll("\\\\") catch {},
            0x08 => f.writeAll("\\b") catch {},
            0x0C => f.writeAll("\\f") catch {},
            '\n' => f.writeAll("\\n") catch {},
            '\r' => f.writeAll("\\r") catch {},
            '\t' => f.writeAll("\\t") catch {},
            else => {
                if (ch < 0x20) f.print("\\u{x:0>4}", .{ch}) catch {} else f.writeByte(ch) catch {};
            },
        }
    }
    f.writeByte('"') catch {};
}

// ------------------------------------------------- conversation state ----
// Everything the engine carries between tokens, on disk: the KDA recurrent
// matrices plus ShortConv history (fixed size, context-independent), the MLA
// KV cache, and the shared rope rows - stored position-major inside each MLA
// layer's slice so only the OCCUPIED positions are written. The AttnRes block
// buffer is NOT carried: forward() rebuilds it every pass.
//
// Format follows C's K3StateHdr byte for byte through the header; the payload
// elements are Q128 (32 B each) instead of f32, hence version 2.

/// One taped decode step for --verify-rewind: the recurrent state as it was
/// BEFORE the step plus the receipt the replay must reproduce. KV/rope caches
/// are deliberately absent — they are append-only and a replayed step rewrites
/// its own slots deterministically (the same property --spec relies on).
const RewindFrame = struct {
    input: []i32, // duped token slice fed to forward for this step
    ks_snap: []Q, // KDA/ShortConv state snapshot before the step
    cached: usize, // w.cached before the step
    emitted: i32,
    argmax: i32,
    fold: u256,
};

/// Snapshot the pre-step recurrent state and the step's input into the tape.
/// Returns the frame index to seal after the step's logits exist, or null when
/// the tape is full/allocation failed (taping never aborts the decode).
fn tapeFrame(alloc: Allocator, tape: *std.ArrayList(RewindFrame), input: []const i32, ks: []const Q, cached: usize) ?usize {
    const snap = alloc.alloc(Q, ks.len) catch return null;
    const inp = alloc.dupe(i32, input) catch {
        alloc.free(snap);
        return null;
    };
    @memcpy(snap, ks);
    tape.append(.{ .input = inp, .ks_snap = snap, .cached = cached, .emitted = -1, .argmax = -1, .fold = 0 }) catch {
        alloc.free(snap);
        alloc.free(inp);
        return null;
    };
    return tape.items.len - 1;
}

/// Record the receipt once the step's logits exist: the xor-fold receipt plus
/// the raw argmax (computed even when sampling drove the emitted pick).
fn sealFrame(frame: *RewindFrame, emitted: i32, logits: []const Q) void {
    frame.emitted = emitted;
    frame.argmax = @intCast(model.argmax(logits));
    frame.fold = rev.logitsFold(logits);
}

const StateHdr = extern struct {
    magic: [4]u8,
    version: i32,
    fp: [12]i32,
    n_bound: i32,
    n_mla: i32,
    cached: i32,
    nseq: i32,
    kper: i64, // KDA+conv elements per layer
    kvpp: i64, // KV elements per position, per MLA layer
    ropepp: i64, // rope elements per position, per MLA layer
};

fn stateFp(c: *const k3.K3Cfg, fpv: *[12]i32) void {
    fpv[0] = c.hidden;
    fpv[1] = c.n_layers;
    fpv[2] = c.vocab;
    fpv[3] = c.kda_heads;
    fpv[4] = c.kda_head_dim;
    fpv[5] = c.conv_k;
    fpv[6] = c.n_heads;
    fpv[7] = c.qk_nope;
    fpv[8] = c.qk_rope;
    fpv[9] = c.v_head;
    fpv[10] = c.n_experts;
    fpv[11] = c.topk;
}

/// Reads only the header, so the caller can size buffers before committing.
fn statePeek(path: []const u8, hd: *StateHdr, errw: Writer) i32 {
    const f = std.fs.cwd().openFile(path, .{}) catch |e| {
        errw.print("{s}: {s}\n", .{ path, @errorName(e) }) catch {};
        return -1;
    };
    defer f.close();
    const got = f.readAll(std.mem.asBytes(hd)) catch 0;
    if (got != @sizeOf(StateHdr) or !std.mem.eql(u8, &hd.magic, "K3ST")) {
        errw.print("{s} is not a k3 state file\n", .{path}) catch {};
        return -1;
    }
    if (hd.version != STATE_VER) {
        errw.print("{s} is state version {d}, this build writes {d}\n", .{ path, hd.version, STATE_VER }) catch {};
        return -1;
    }
    return 0;
}

fn stateLoad(path: []const u8, c: *const k3.K3Cfg, hd: *const StateHdr, seq: []i32, ks: []Q, kvc: []Q, ropec: []Q, n_bound: usize, n_mla: usize, kv_cap: usize, errw: Writer) i32 {
    var fpv: [12]i32 = undefined;
    stateFp(c, &fpv);
    if (!std.mem.eql(i32, &hd.fp, &fpv)) {
        errw.print("REFUSING: {s} was written by a different model architecture.\n" ++
            "  Restoring it would produce fluent, wrong output.\n", .{path}) catch {};
        return -1;
    }
    if (hd.n_bound != n_bound or hd.n_mla != n_mla) {
        errw.print("REFUSING: {s} holds {d} bound layers and {d} MLA layers, " ++
            "this run has {d} and {d}\n", .{ path, hd.n_bound, hd.n_mla, n_bound, n_mla }) catch {};
        return -1;
    }
    if (@as(usize, @intCast(hd.cached)) > kv_cap) {
        errw.print("REFUSING: {s} holds {d} positions, this run's KV cache is {d}.\n" ++
            "  Raise --gen or shorten the prompt.\n", .{ path, hd.cached, kv_cap }) catch {};
        return -1;
    }
    const f = std.fs.cwd().openFile(path, .{}) catch |e| {
        errw.print("{s}: {s}\n", .{ path, @errorName(e) }) catch {};
        return -1;
    };
    defer f.close();
    f.seekTo(@sizeOf(StateHdr)) catch {
        errw.print("{s} is truncated\n", .{path}) catch {};
        return -1;
    };

    const nseq: usize = @intCast(hd.nseq);
    const kper: usize = @intCast(hd.kper);
    const kvpp: usize = @intCast(hd.kvpp);
    const ropepp: usize = @intCast(hd.ropepp);
    const cached: usize = @intCast(hd.cached);

    var ok = f.readAll(std.mem.sliceAsBytes(seq[0..nseq])) catch 0 == nseq * 4;
    if (ok) ok = (f.readAll(std.mem.sliceAsBytes(ks[0 .. kper * n_bound])) catch 0) == kper * n_bound * @sizeOf(Q);
    // Position-major inside each layer slice, so a differently-sized
    // destination cache is written slice by slice rather than as one block.
    if (ok) for (0..n_mla) |mi| {
        const dst = kvc[mi * kv_cap * kvpp ..][0 .. cached * kvpp];
        if ((f.readAll(std.mem.sliceAsBytes(dst)) catch 0) != cached * kvpp * @sizeOf(Q)) {
            ok = false;
            break;
        }
    };
    if (ok) for (0..n_mla) |mi| {
        const dst = ropec[mi * kv_cap * ropepp ..][0 .. cached * ropepp];
        if ((f.readAll(std.mem.sliceAsBytes(dst)) catch 0) != cached * ropepp * @sizeOf(Q)) {
            ok = false;
            break;
        }
    };
    if (!ok) {
        errw.print("{s} is truncated\n", .{path}) catch {};
        return -1;
    }
    return 0;
}

fn stateSave(path: []const u8, c: *const k3.K3Cfg, seq: []const i32, ks: []const Q, kvc: []const Q, ropec: []const Q, n_bound: usize, n_mla: usize, kv_cap: usize, cached: usize, kper: usize, kvpp: usize, ropepp: usize, errw: Writer) i32 {
    // Atomic commit (TheUE e0_file_store pattern): write to a sibling .tmp
    // and rename over the target, so a crash mid-write can never leave a
    // truncated K3ST where a checkpoint was expected.
    var tmp_buf: [4096]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch {
        errw.print("{s}: path too long for atomic save\n", .{path}) catch {};
        return -1;
    };
    const f = std.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch |e| {
        errw.print("{s}: {s}\n", .{ tmp_path, @errorName(e) }) catch {};
        return -1;
    };
    // no defer close: the handle is closed explicitly before the rename, and
    // a failed write path closes it too (see below)
    var hd = StateHdr{
        .magic = "K3ST".*,
        .version = STATE_VER,
        .fp = undefined,
        .n_bound = @intCast(n_bound),
        .n_mla = @intCast(n_mla),
        .cached = @intCast(cached),
        .nseq = @intCast(seq.len),
        .kper = @intCast(kper),
        .kvpp = @intCast(kvpp),
        .ropepp = @intCast(ropepp),
    };
    stateFp(c, &hd.fp);

    var ok = true;
    f.writeAll(std.mem.asBytes(&hd)) catch {
        ok = false;
    };
    if (ok) f.writeAll(std.mem.sliceAsBytes(seq)) catch {
        ok = false;
    };
    if (ok) f.writeAll(std.mem.sliceAsBytes(ks[0 .. kper * n_bound])) catch {
        ok = false;
    };
    if (ok) for (0..n_mla) |mi| {
        const src = kvc[mi * kv_cap * kvpp ..][0 .. cached * kvpp];
        f.writeAll(std.mem.sliceAsBytes(src)) catch {
            ok = false;
            break;
        };
    };
    if (ok) for (0..n_mla) |mi| {
        const src = ropec[mi * kv_cap * ropepp ..][0 .. cached * ropepp];
        f.writeAll(std.mem.sliceAsBytes(src)) catch {
            ok = false;
            break;
        };
    };
    // Close BEFORE rename — required on Windows and harmless elsewhere.
    f.close();
    if (!ok) {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        errw.print("failed writing {s}\n", .{tmp_path}) catch {};
        return -1;
    }
    std.fs.cwd().rename(tmp_path, path) catch |e| {
        std.fs.cwd().deleteFile(tmp_path) catch {};
        errw.print("{s}: rename failed: {s}\n", .{ path, @errorName(e) }) catch {};
        return -1;
    };
    return 0;
}

// -------------------------------------------------- speculative drafting ----
// Longest-suffix n-gram drafting for --spec: if the last n ids (n=4, then 3)
// already appeared earlier in the sequence, propose the ids that followed
// them there. Evidence-gated: when the n-gram occurred more than once, every
// occurrence must propose the same next id, and the draft stops at the first
// position where the histories diverge. Drafts are PROPOSALS only; batched
// greedy verification emits exactly what serial decode would.

fn specDraft(seq: []const i32, cap_in: usize, out: []i32) usize {
    const T = seq.len;
    const cap = @min(cap_in, SPEC_MAX);
    var n: usize = 4;
    while (n >= 3) : (n -= 1) {
        if (T < n + 1) continue;
        var m1: ?usize = null; // two most recent matches
        var m2: ?usize = null;
        var j: usize = T - n - 1;
        while (true) {
            var hit = true;
            for (0..n) |i| {
                if (seq[j + i] != seq[T - n + i]) {
                    hit = false;
                    break;
                }
            }
            if (hit) {
                if (m1 == null) {
                    m1 = j;
                } else {
                    m2 = j;
                    break;
                }
            }
            if (j == 0) break;
            j -= 1;
        }
        const s1 = m1 orelse continue;
        var nd: usize = 0;
        var i: usize = 0;
        while (nd < cap and s1 + n + i < T) : (i += 1) {
            const cand = seq[s1 + n + i];
            if (m2) |s2| {
                // stop where the two histories stop agreeing
                if (s2 + n + i >= s1 or seq[s2 + n + i] != cand) break;
            }
            out[nd] = cand;
            nd += 1;
        }
        if (nd > 0) return nd;
    }
    return 0;
}

// ---------------------------------------------------------- the model ----

/// The C `Weights` bundle: layer bindings (resident or trunk-streamed), the
/// model-level tables, the streamed-table reader (ultra), and the incremental
/// decode state. Only MLA layers need a KV cache, so they are numbered
/// densely via mla_slot rather than indexing all n_layers.
/// The bound resident model: per-layer binds, model-level tensors, optional
/// streaming handles, and the incremental-decode caches. `pub` so
/// tools/make_tiny_checkpoint can drive a forward through the real engine
/// path rather than re-implementing it.
pub const Weights = struct {
    lay: []bind.LayerBind = &.{},
    mb: bind.ModelBind = .{},
    ms: ?model.ModelStream = null,
    n_bound: usize = 0,
    layers_completed: usize = 0,
    ultra: bool = false,
    trunk: ?*trunk_mod.Trunk = null, // non-null when the trunk is streamed
    kvc: ?[]Q = null,
    ropec: ?[]Q = null,
    mla_slot: []i32 = &.{}, // [n_layers] -> dense MLA index, or -1
    n_mla: usize = 0,
    kv_cap: usize = 0,
    cached: usize = 0,
    draft_mode: bool = false, // cache-only expert routing
    /// When set, layered MoE calls use this ExpertSrc instead of
    /// `cache.src` — the ExecMux fan-out for --exec-peer fabric compute.
    expert_src: ?*k3.ExpertSrc = null,
};

/// Gather one embedding row into dst[hidden], widening if the table is bf16.
/// The table is indexed rather than multiplied, so it cannot go through mmw.
fn embedRow(dst: []Q, table: ?*const anyopaque, wdt: k3.Wdt, row: usize, E: usize) !void {
    const p = table orelse return error.MissingWeight;
    switch (wdt) {
        .bf16 => {
            const b: [*]const u16 = @ptrCast(@alignCast(p));
            for (0..E) |i| dst[i] = try k3.q128FromBf16(b[row * E + i]);
        },
        else => {
            const t: [*]const f32 = @ptrCast(@alignCast(p));
            for (0..E) |i| dst[i] = try Q.fromF32Bits(@bitCast(t[row * E + i]));
        },
    }
}

/// One full forward over ids[0..T], writing logits for the LAST position
/// only. Incremental decode carries KDA/conv state and the MLA caches across
/// calls; the full-recompute path rebuilds them every step, matching the C
/// contract. arg_all, when set, receives argmax(logits) for EVERY position -
/// the batched greedy verification --spec and --draft-trunk consume.
/// Returns 0 on success, -1 on failure (logits_last untouched).
pub fn forward(w: *Weights, c: *const k3.K3Cfg, cache: *cache_mod.Cache, ids: []const i32, logits_last: []Q, scratch: []Q, h: []Q, br: []Q, kstate: []Q, arg_all: ?[]i32, errw: Writer) i32 {
    const T = ids.len;
    const E: usize = @intCast(c.hidden);
    const maxb: usize = @intCast(@divTrunc(c.n_layers, c.attn_res_block) + 2);
    const P: usize = @intCast(c.kda_heads * c.kda_head_dim);
    const kper = P * @as(usize, @intCast(c.kda_head_dim)) + 3 * P * (@as(usize, @intCast(c.conv_k)) - 1);
    const vocab: usize = @intCast(c.vocab);

    for (0..T) |t| {
        const dst = h[t * E ..][0..E];
        if (w.ultra) {
            w.ms.?.embedRow(dst, ids[t]) catch {
                errw.print("embedding row load failed for token {d} at position {d}\n", .{ ids[t], t }) catch {};
                return -1;
            };
        } else {
            embedRow(dst, w.mb.embed, w.mb.wdt, @intCast(ids[t]), E) catch return -1;
        }
    }

    @memset(br[0 .. T * maxb * E], zero);
    // Incremental decode carries the KDA recurrent matrix and ShortConv
    // history across steps, so it must NOT be cleared here; the full-recompute
    // path rebuilds from scratch every step and must be.
    if (w.kvc == null) {
        const slots: usize = if (w.ultra) 1 else w.n_bound;
        @memset(kstate[0 .. kper * slots], zero);
    }
    w.layers_completed = 0;
    var nb: i32 = 0;
    for (0..w.n_bound) |L| {
        // Streaming: bring this layer in, and hint the next one so its read
        // overlaps this layer's arithmetic. The order is fixed 0..N-1 every
        // token, so the hint is never wrong.
        if (w.trunk) |tr| {
            if (tr.bind(c, @intCast(L), &w.lay[L]) != 0) {
                errw.print("trunk bind failed at layer {d}\n", .{L}) catch {};
                return -1;
            }
            tr.prefetch(@intCast(L + 1));
        }
        // Point this layer's MoE at the cache before use. Doing it here rather
        // than at bind time keeps LayerBind independent of any cache.
        if (w.lay[L].lay.moe != null) {
            w.lay[L].moe.src = w.expert_src orelse &cache.src;
            w.lay[L].moe.layer = @intCast(L);
            // The draft routes only among resident experts, reading zero new
            // expert bytes; the exact model keeps true routing.
            w.lay[L].moe.cache_only = w.draft_mode;
        }
        // Full recompute consumes a layer's KDA/ShortConv state only while
        // that layer executes; ultra may clear and reuse one slot.
        const sidx: usize = if (w.ultra and w.kvc == null) 0 else kper * L;
        const layer_state = kstate[sidx..][0..kper];
        if (w.ultra and w.kvc == null) @memset(layer_state, zero);
        const drops_before = k3.expert_drops;
        if (w.kvc != null and w.mla_slot.len > L and w.mla_slot[L] >= 0) {
            const kvper = w.kv_cap * @as(usize, @intCast(c.n_heads)) * @as(usize, @intCast(c.qk_nope + c.v_head));
            const rpper = w.kv_cap * @as(usize, @intCast(c.qk_rope));
            const mi: usize = @intCast(w.mla_slot[L]);
            ops.decoderLayerInc(h, br, &nb, &w.lay[L].lay, c, @intCast(L), T, layer_state, scratch, w.kvc.?[mi * kvper ..][0..kvper], w.ropec.?[mi * rpper ..][0..rpper], w.cached, w.kv_cap) catch return -1;
        } else {
            ops.decoderLayerInc(h, br, &nb, &w.lay[L].lay, c, @intCast(L), T, layer_state, scratch, null, null, 0, 0) catch return -1;
        }
        if (k3.expert_drops != drops_before) {
            errw.print("routed expert load failed at layer {d}; refusing partial " ++
                "MoE output\n", .{L}) catch {};
            return -1;
        }
        w.layers_completed = L + 1;
    }

    // The model-level aggregator, beyond the two per layer. Exactly one pair
    // exists in the checkpoint; skipping it is silent.
    if (w.mb.out_res_norm.len > 0 and w.mb.out_res_proj.len > 0) {
        const fold = scratch[0..E];
        const src = scratch[E..];
        for (0..E) |i| fold[i] = w.mb.out_res_norm[i].mul(w.mb.out_res_proj[i]) catch return -1;
        for (0..T) |t| {
            for (0..@intCast(nb)) |b| {
                @memcpy(src[b * E ..][0..E], br[(t * maxb + b) * E ..][0..E]);
            }
            @memcpy(src[@as(usize, @intCast(nb)) * E ..][0..E], h[t * E ..][0..E]);
            ops.attnRes(h[t * E ..][0..E], src, fold, @as(usize, @intCast(nb)) + 1, E, c.rms_eps) catch return -1;
        }
    }

    const nrm = scratch[0..E];
    if (arg_all) |arg| {
        for (0..T) |t| {
            ops.rmsnorm(nrm, h[t * E ..][0..E], w.mb.norm, c.rms_eps) catch return -1;
            if (w.ultra) {
                w.ms.?.project(logits_last, nrm) catch return -1;
            } else {
                ops.mmw(logits_last, nrm, w.mb.lm_head, w.mb.wdt, E, vocab) catch return -1;
            }
            arg[t] = @intCast(model.argmax(logits_last[0..vocab]));
        }
        // logits_last now holds the FINAL position's vector, as in C.
        return 0;
    }
    ops.rmsnorm(nrm, h[(T - 1) * E ..][0..E], w.mb.norm, c.rms_eps) catch return -1;
    if (w.ultra) {
        w.ms.?.project(logits_last, nrm) catch return -1;
    } else {
        ops.mmw(logits_last, nrm, w.mb.lm_head, w.mb.wdt, E, vocab) catch return -1;
    }
    return 0;
}

// -------------------------------------------------- bounded allocation ----
// TrackingAllocator: a std.mem.Allocator adapter that counts live bytes and
// can refuse past a byte limit. The run wires every allocation through it so
// the budgets the banner prints are enforced by the allocator itself, not
// just forecasted. limit == null means count-only (the C behaviour: the
// memory plan refuses up front, the tracker measures reality).

const TrackingAllocator = struct {
    parent: Allocator,
    live: usize = 0,
    peak: usize = 0,
    limit: ?usize = null,
    denied: u64 = 0,

    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = allocFn, .resize = resizeFn, .free = freeFn },
        };
    }

    fn allocFn(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (self.limit) |lim| {
            if (self.live + len > lim) {
                self.denied += 1;
                return null;
            }
        }
        const p = self.parent.rawAlloc(len, ptr_align, ret_addr) orelse return null;
        self.live += len;
        self.peak = @max(self.peak, self.live);
        return p;
    }

    fn resizeFn(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            const d = new_len - buf.len;
            if (self.limit) |lim| {
                if (self.live + d > lim) {
                    self.denied += 1;
                    return false;
                }
            }
        }
        if (!self.parent.rawResize(buf, log2_align, new_len, ret_addr)) return false;
        if (new_len > buf.len) self.live += new_len - buf.len else self.live -= buf.len - new_len;
        self.peak = @max(self.peak, self.live);
        return true;
    }

    fn freeFn(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, log2_align, ret_addr);
        self.live -= buf.len;
    }
};

// ---------------------------------------------------------------- main ----

// ------------------------------------------------------- GQA+MoE path ----

/// Peek at config.json's model_type. Returns the string when it names the
/// GQA+MoE family this binary can dispatch; null for kimi_k3, absent files,
/// or anything else (the K3 path then applies its own config diagnostics).
/// llama4 and the phase-B hybrids return their strings too — gqa_cfg.load
/// refuses them explicitly inside runGqa rather than silently misrouting.
fn peekGqa(alloc: Allocator, dir: []const u8, cfg_path: ?[]const u8) ?[]const u8 {
    var path_buf: [4096]u8 = undefined;
    var p = cfg_path;
    if (p == null) {
        const guess = std.fmt.bufPrint(&path_buf, "{s}/config.json", .{dir}) catch return null;
        if (std.fs.cwd().access(guess, .{})) |_| {
            p = guess;
        } else |_| return null;
    }
    const mt = gqa_cfg.peekModelType(alloc, p.?) catch return null;
    const fam = [_][]const u8{ "qwen3_moe", "olmoe", "qwen3_next", "qwen3_5_moe", "llama4" };
    for (fam) |f| {
        if (std.mem.eql(u8, mt, f)) return mt;
    }
    return null;
}

/// A "peer:host:port" URI hands the whole trunk to a k3peer endpoint.
fn peerUri(s: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, s, "peer:")) s[5..] else null;
}

/// --key-file: a raw 32-byte XChaCha20-Poly1305 pre-shared key.
fn loadPeerKey(alloc: Allocator, path: []const u8) ![32]u8 {
    const raw = try std.fs.cwd().readFileAlloc(alloc, path, 4096);
    defer alloc.free(raw);
    if (raw.len != 32) return error.BadKeyFile;
    var k: [32]u8 = undefined;
    @memcpy(&k, raw);
    return k;
}

fn parseIdsList(s: []const u8, out_ids: []usize) usize {
    var np: usize = 0;
    var p: usize = 0;
    while (p < s.len and np < out_ids.len) {
        var q = p;
        if (s[q] == '+') q += 1;
        var v: usize = 0;
        var saw = false;
        while (q < s.len and std.ascii.isDigit(s[q])) {
            v = v * 10 + (s[q] - '0');
            q += 1;
            saw = true;
        }
        if (!saw) {
            p += 1;
            continue;
        }
        out_ids[np] = v;
        np += 1;
        p = q;
        while (p < s.len and (s[p] == ',' or s[p] == ' ')) p += 1;
    }
    return np;
}

/// The GQA+MoE run path: strict config -> resident bind -> prompt eval ->
/// greedy decode over model_gqa.forwardInc. Flags honored: --ids,
/// --prompt/--prompt-file + --tok, --gen, --layers, --config,
/// --dump-logits. Flags that only exist on the K3 path (trunk, expert
/// cache budgets, spec decode, state files, gpu) are rejected loudly.
fn runGqa(
    alloc: Allocator,
    dir: []const u8,
    cfg_path: ?[]const u8,
    ids_s: ?[]const u8,
    prompt_text: ?[]const u8,
    prompt_file: ?[]const u8,
    tok_dir: ?[]const u8,
    gen_in: i32,
    want_layers: i32,
    logits_path: ?[]const u8,
    weights_peer: ?[]const u8,
    peer_auth: peersrc.Auth,
    mt: []const u8,
    out: Writer,
    errw: Writer,
) u8 {
    // ---- config ----
    var path_buf: [4096]u8 = undefined;
    var p = cfg_path;
    if (p == null) {
        p = std.fmt.bufPrint(&path_buf, "{s}/config.json", .{dir}) catch return 2;
    }
    var c: gqa_cfg.GqaCfg = .{};
    var diag: gqa_cfg.Diag = .{};
    gqa_cfg.loadFile(&c, alloc, p.?, &diag) catch |e| {
        out.writeAll(diag.buf.constSlice()) catch {};
        if (diag.buf.len == 0) errw.print("gqa: config load failed: {s}\n", .{@errorName(e)}) catch {};
        return 2;
    };
    if (want_layers > 0 and want_layers < c.n_layers) {
        out.print("NOTE: binding only the first {d} of {d} layers. Output is NOT the full " ++
            "model; it is a partial stack for testing the machinery.\n\n", .{ want_layers, c.n_layers }) catch {};
        c.n_layers = want_layers;
    }
    out.print("config: {s} ({s}) | hidden={d} layers={d} vocab={d} | " ++
        "heads {d}/{d}x{d} | experts {d} top{d} shared={d}\n", .{
        p.?,            mt,     c.hidden,   c.n_layers,  c.vocab,
        c.n_heads,      c.n_kv, c.head_dim, c.n_experts, c.topk,
        c.shared_inter,
    }) catch {};

    // ---- bind ----
    var s = if (weights_peer) |ep|
        st.St.openPeer(alloc, ep, peer_auth) catch |e| {
            errw.print("peer {s}: safetensors open failed: {s}\n", .{ ep, @errorName(e) }) catch {};
            return 1;
        }
    else
        st.St.open(alloc, dir) catch |e| {
            errw.print("{s}: safetensors open failed: {s}\n", .{ dir, @errorName(e) }) catch {};
            return 1;
        };
    defer s.close();
    const t_bind0 = nowS();
    // Full classic-MoE checkpoints cannot materialize every expert on this
    // host. Stream one selected bf16 expert at a time while keeping attention,
    // router, embeddings, and norms resident. Small fixtures/partial runs
    // retain the resident path used by the original parity gate.
    const stream_experts = c.n_experts > 32;
    var w = (if (stream_experts)
        gqa_bind.bindStreamed(alloc, &s, &c)
    else
        gqa_bind.bind(alloc, &s, &c)) catch |e| {
        errw.print("gqa: weight bind failed: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    defer gqa_bind.deinit(&w, alloc);
    {
        var hb: [32]u8 = undefined;
        out.print("bind: {s} resident ({d:.1}s)\n", .{ human(@floatFromInt(w.blob.len), &hb), nowS() - t_bind0 }) catch {};
    }

    // ---- prompt ----
    const idsbuf = alloc.alloc(usize, k3.MAX_PROMPT) catch return 1;
    defer alloc.free(idsbuf);
    var np: usize = 0;
    if (prompt_text != null or prompt_file != null) {
        if (tok_dir == null) {
            errw.print("--prompt/--prompt-file need --tok DIR\n", .{}) catch {};
            return 2;
        }
        const t = tok_mod.Tok.init(alloc) catch {
            errw.print("OOM loading the tokenizer\n", .{}) catch {};
            return 1;
        };
        // GQA-family models ship HF tokenizer.json; tiktoken.model +
        // tokenizer_config.json (the K3 pair) is the fallback.
        var tjbuf: [4096]u8 = undefined;
        const tj = std.fmt.bufPrint(&tjbuf, "{s}/tokenizer.json", .{tok_dir.?}) catch null;
        const have_tj = if (tj) |tjp| blk: {
            if (std.fs.cwd().access(tjp, .{})) |_| {
                break :blk true;
            } else |_| {
                break :blk false;
            }
        } else false;
        if (have_tj) {
            tok_mod.loadFromTokenizerJson(t, alloc, tj.?) catch {
                errw.print("{s}: tokenizer.json load failed\n", .{tj.?}) catch {};
                return 1;
            };
        } else {
            tok_loader.load(t, alloc, tok_dir.?) catch {
                errw.print("{s}: tokenizer load failed\n", .{tok_dir.?}) catch {};
                return 1;
            };
        }
        const ptext = if (prompt_file) |pf|
            std.fs.cwd().readFileAlloc(alloc, pf, 1 << 30) catch |e| {
                errw.print("{s}: {s}\n", .{ pf, @errorName(e) }) catch {};
                return 1;
            }
        else
            prompt_text.?;
        const ib = alloc.alloc(i32, k3.MAX_PROMPT) catch return 1;
        np = t.encode(ptext, ib) catch {
            errw.print("tokenize failed\n", .{}) catch {};
            return 1;
        };
        for (ib[0..np], 0..) |v, ix| idsbuf[ix] = @intCast(@max(@as(i32, 0), v));
        out.print("  tokenized: {d} bytes -> {d} ids\n", .{ ptext.len, np }) catch {};
    } else {
        np = parseIdsList(ids_s.?, idsbuf);
    }
    if (np == 0) {
        errw.print("no prompt ids parsed\n", .{}) catch {};
        return 2;
    }
    for (idsbuf[0..np]) |id| {
        if (id >= @as(usize, @intCast(c.vocab))) {
            errw.print("token id {d} is outside the vocabulary of {d}\n", .{ id, c.vocab }) catch {};
            return 2;
        }
    }

    // ---- state ----
    const E: usize = @intCast(c.hidden);
    const V: usize = @intCast(c.vocab);
    const gen: usize = @intCast(@max(gen_in, 0));
    const cap = np + gen;
    const kvh: usize = @intCast(c.n_kv * c.head_dim);
    const nl: usize = @intCast(c.n_layers);

    const h = alloc.alloc(Q, cap * E) catch return 1;
    defer alloc.free(h);
    const scratch = alloc.alloc(Q, model_gqa.scratchNeed(&c, cap)) catch return 1;
    defer alloc.free(scratch);
    const kcb = alloc.alloc(Q, nl * cap * kvh) catch return 1;
    defer alloc.free(kcb);
    const vcb = alloc.alloc(Q, nl * cap * kvh) catch return 1;
    defer alloc.free(vcb);
    const kc = alloc.alloc([]Q, nl) catch return 1;
    defer alloc.free(kc);
    const vc = alloc.alloc([]Q, nl) catch return 1;
    defer alloc.free(vc);
    for (0..nl) |L| {
        kc[L] = kcb[L * cap * kvh ..][0 .. cap * kvh];
        vc[L] = vcb[L * cap * kvh ..][0 .. cap * kvh];
    }
    const logits = alloc.alloc(Q, V) catch return 1;
    defer alloc.free(logits);

    // ---- prompt eval + greedy decode ----
    const t0 = nowS();
    model_gqa.forwardInc(&w, &c, idsbuf[0..np], 0, logits, h[0 .. np * E], scratch, kc, vc, cap) catch |e| {
        errw.print("gqa: prompt forward failed: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    const t1 = nowS();
    out.print("prompt: {d} tokens evaluated in {d:.1}s\n", .{ np, t1 - t0 }) catch {};
    if (logits_path) |lp| {
        dumpLogitsFile(lp, logits, errw) catch return 1;
    }

    var next = model_gqa.argmax(logits);
    var cur = np;
    for (0..gen) |g| {
        out.print("{d}{s}", .{ next, if (g + 1 < gen) " " else "\n" }) catch {};
        idsbuf[0] = next;
        model_gqa.forwardInc(&w, &c, idsbuf[0..1], cur, logits, h[0..E], scratch, kc, vc, cap) catch |e| {
            errw.print("\ngqa: decode step {d} failed: {s}\n", .{ g, @errorName(e) }) catch {};
            return 1;
        };
        next = model_gqa.argmax(logits);
        cur += 1;
    }
    out.print("decode: {d} tokens in {d:.1}s\n", .{ gen, nowS() - t1 }) catch {};
    return 0;
}

fn dumpLogitsFile(path: []const u8, logits: []const Q, errw: Writer) !void {
    const f = std.fs.cwd().createFile(path, .{}) catch |e| {
        errw.print("{s}: {s}\n", .{ path, @errorName(e) }) catch {};
        return e;
    };
    defer f.close();
    var bw = std.io.bufferedWriter(f.writer());
    for (logits) |v| {
        bw.writer().print("{d}\n", .{v.toF64()}) catch return error.WriteFailed;
    }
    bw.flush() catch return error.WriteFailed;
}

fn run(alloc: Allocator, argv: []const []const u8, out: Writer, errw: Writer) u8 {
    // Informational flags are answered before anything else, because they must
    // work without a model directory - `k3 --help` on a machine with no
    // checkpoint is the first thing most people type.
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            usage(out);
            return 0;
        }
        if (std.mem.eql(u8, a, "--version")) {
            out.print("k3 {s}\n", .{VERSION}) catch {};
            return 0;
        }
        if (std.mem.eql(u8, a, "--list-presets")) {
            presetList(out);
            return 0;
        }
    }
    if (argv.len < 2) {
        usage(errw);
        return 2;
    }

    const dir = argv[1];
    if (dir.len > 0 and dir[0] == '-') {
        errw.print("the first argument must be the model directory, got '{s}'\n\n", .{dir}) catch {};
        usage(errw);
        return 2;
    }

    var ids_s: ?[]const u8 = null;
    var outp: []const u8 = "k3_run.json";
    var trunk_dir: ?[]const u8 = null;
    var weights_peer: ?[]const u8 = null;
    var exec_peers: ?[]const u8 = null;
    var peer_key_file: ?[]const u8 = null;
    var peer_eph = false;
    var peer_auth: peersrc.Auth = .none;
    // Expert-cache diagnostics are opt-in: writing them unconditionally drops
    // two undeclared files into whatever directory the user ran from.
    var trace_dir: ?[]const u8 = null;
    var logits_path: ?[]const u8 = null;
    var sched_emit_path: ?[]const u8 = null;
    var prompt_text: ?[]const u8 = null;
    var prompt_file: ?[]const u8 = null;
    var media_path: ?[]const u8 = null;
    var vision_dump_path: ?[]const u8 = null;
    var tok_dir: ?[]const u8 = null;
    var cfg_path: ?[]const u8 = null;
    var gen: i32 = 8;
    var want_layers: i32 = -1;
    var cache_gb: f64 = 64.0;
    var trunk_gb: f64 = 16.0;
    var budget_auto = false;
    var spec_n: i32 = 0;
    var tf_check = false;
    var draft_dir: ?[]const u8 = null;
    var draft_gb: f64 = 6.0;
    var load_state: ?[]const u8 = null;
    var save_state: ?[]const u8 = null;
    var preset_name: ?[]const u8 = null;
    var incremental = false;
    var ultra = false;
    var use_gpu = false;
    var gpu_device: ?[]const u8 = null;
    var temperature: f64 = 0;
    var top_k: i32 = 0;
    var top_p: f64 = 0;
    var rep_penalty: f64 = 1;
    var tunnel_tail: f64 = 0;
    var tunnel_prefetch = false;
    var seed: u64 = 0;
    var verify_rewind = false;
    var rewind_depth: usize = 0; // 0 = all generated steps

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const takeValue = struct {
            fn get(av: []const []const u8, idx: *usize) ?[]const u8 {
                if (idx.* + 1 < av.len) {
                    idx.* += 1;
                    return av[idx.*];
                }
                return null;
            }
        }.get;
        if (std.mem.eql(u8, a, "--ids")) {
            if (takeValue(argv, &i)) |v| ids_s = v;
        } else if (std.mem.eql(u8, a, "--prompt")) {
            if (takeValue(argv, &i)) |v| prompt_text = v;
        } else if (std.mem.eql(u8, a, "--prompt-file")) {
            if (takeValue(argv, &i)) |v| prompt_file = v;
        } else if (std.mem.eql(u8, a, "--tok")) {
            if (takeValue(argv, &i)) |v| tok_dir = v;
        } else if (std.mem.eql(u8, a, "--media")) {
            if (takeValue(argv, &i)) |v| media_path = v;
        } else if (std.mem.eql(u8, a, "--dump-vision")) {
            if (takeValue(argv, &i)) |v| vision_dump_path = v;
        } else if (std.mem.eql(u8, a, "--config")) {
            if (takeValue(argv, &i)) |v| cfg_path = v;
        } else if (std.mem.eql(u8, a, "--gen")) {
            if (takeValue(argv, &i)) |v| gen = atoiC(v);
        } else if (std.mem.eql(u8, a, "--cache-gb")) {
            if (takeValue(argv, &i)) |v| cache_gb = atofC(v);
        } else if (std.mem.eql(u8, a, "--layers")) {
            if (takeValue(argv, &i)) |v| want_layers = atoiC(v);
        } else if (std.mem.eql(u8, a, "--out")) {
            if (takeValue(argv, &i)) |v| outp = v;
        } else if (std.mem.eql(u8, a, "--trunk")) {
            if (takeValue(argv, &i)) |v| trunk_dir = v;
        } else if (std.mem.eql(u8, a, "--weights-peer")) {
            if (takeValue(argv, &i)) |v| weights_peer = v;
        } else if (std.mem.eql(u8, a, "--exec-peer")) {
            if (takeValue(argv, &i)) |v| exec_peers = v;
        } else if (std.mem.eql(u8, a, "--key-file")) {
            if (takeValue(argv, &i)) |v| peer_key_file = v;
        } else if (std.mem.eql(u8, a, "--peer-eph")) {
            peer_eph = true;
        } else if (std.mem.eql(u8, a, "--spec")) {
            if (takeValue(argv, &i)) |v| spec_n = atoiC(v);
        } else if (std.mem.eql(u8, a, "--tf-check")) {
            tf_check = true;
        } else if (std.mem.eql(u8, a, "--load-state")) {
            if (takeValue(argv, &i)) |v| load_state = v;
        } else if (std.mem.eql(u8, a, "--save-state")) {
            if (takeValue(argv, &i)) |v| save_state = v;
        } else if (std.mem.eql(u8, a, "--draft-trunk")) {
            if (takeValue(argv, &i)) |v| draft_dir = v;
        } else if (std.mem.eql(u8, a, "--draft-trunk-gb")) {
            if (takeValue(argv, &i)) |v| draft_gb = atofC(v);
        } else if (std.mem.eql(u8, a, "--trunk-gb")) {
            if (takeValue(argv, &i)) |v| {
                if (std.mem.eql(u8, v, "auto")) {
                    budget_auto = true;
                } else {
                    trunk_gb = atofC(v);
                    budget_auto = false;
                }
            }
        } else if (std.mem.eql(u8, a, "--gpu")) {
            use_gpu = true;
        } else if (std.mem.eql(u8, a, "--gpu-device")) {
            if (takeValue(argv, &i)) |v| gpu_device = v;
        } else if (std.mem.eql(u8, a, "--incremental")) {
            incremental = true;
        } else if (std.mem.eql(u8, a, "--ultra-low-memory")) {
            ultra = true;
        } else if (std.mem.eql(u8, a, "--dump-logits")) {
            if (takeValue(argv, &i)) |v| logits_path = v;
        } else if (std.mem.eql(u8, a, "--sched-emit")) {
            if (takeValue(argv, &i)) |v| sched_emit_path = v;
        } else if (std.mem.eql(u8, a, "--dump-cache-trace")) {
            if (takeValue(argv, &i)) |v| trace_dir = v;
        } else if (std.mem.eql(u8, a, "--preset")) {
            if (i + 1 < argv.len) {
                const v = argv[i + 1];
                if (std.mem.eql(u8, v, "auto")) {
                    // Not in the table: the table is fixed budgets, auto is
                    // computed from this machine's MemAvailable below, once
                    // parsing is complete.
                    i += 1;
                    budget_auto = true;
                    preset_name = "auto";
                    ultra = false;
                } else if (presetFind(v)) |p| {
                    // A preset sets the budget; an explicit --trunk-gb/
                    // --cache-gb after it still wins, applied in argv order.
                    i += 1;
                    trunk_gb = p.trunk_gb;
                    cache_gb = p.cache_gb;
                    preset_name = p.name;
                    ultra = p.ultra;
                } else {
                    i += 1;
                    errw.print("unknown preset '{s}'\n\n", .{v}) catch {};
                    presetList(errw);
                    return 2;
                }
            }
        } else if (std.mem.eql(u8, a, "--temperature")) {
            if (takeValue(argv, &i)) |v| temperature = atofC(v);
        } else if (std.mem.eql(u8, a, "--top-k")) {
            if (takeValue(argv, &i)) |v| top_k = atoiC(v);
        } else if (std.mem.eql(u8, a, "--top-p")) {
            if (takeValue(argv, &i)) |v| top_p = atofC(v);
        } else if (std.mem.eql(u8, a, "--rep-penalty")) {
            if (takeValue(argv, &i)) |v| rep_penalty = atofC(v);
        } else if (std.mem.eql(u8, a, "--tunnel-tail")) {
            if (takeValue(argv, &i)) |v| tunnel_tail = atofC(v);
        } else if (std.mem.eql(u8, a, "--tunnel-prefetch")) {
            tunnel_prefetch = true;
        } else if (std.mem.eql(u8, a, "--verify-rewind")) {
            verify_rewind = true;
        } else if (std.mem.eql(u8, a, "--rewind-depth")) {
            if (takeValue(argv, &i)) |v| rewind_depth = @intCast(@max(atoiC(v), 0));
        } else if (std.mem.eql(u8, a, "--seed")) {
            if (takeValue(argv, &i)) |v| seed = @bitCast(@as(i64, atoiC(v)));
        } else if (std.mem.eql(u8, a, "--list-presets")) {
            presetList(out);
            return 0;
        } else if (std.mem.eql(u8, a, "--version")) {
            out.print("k3 {s}\n", .{VERSION}) catch {};
            return 0;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            usage(out);
            return 0;
        } else {
            errw.print("unknown option {s}\n\n", .{a}) catch {};
            usage(errw);
            return 2;
        }
    }

    if (peer_key_file != null and peer_eph) {
        errw.print("--key-file and --peer-eph are mutually exclusive\n", .{}) catch {};
        return 2;
    }
    if (peer_key_file) |kf| {
        const peer_key = loadPeerKey(alloc, kf) catch {
            errw.print("--key-file {s}: expected a raw 32-byte key\n", .{kf}) catch {};
            return 2;
        };
        peer_auth = .{ .psk = peer_key };
    }
    if (peer_eph) peer_auth = .eph;
    if (comptime !peersrc.available) {
        if (weights_peer != null or exec_peers != null or
            (trunk_dir != null and peerUri(trunk_dir.?) != null) or
            (draft_dir != null and peerUri(draft_dir.?) != null))
        {
            errw.print("peer transports need sockets; unavailable on this target (WASI)\n", .{}) catch {};
            return 2;
        }
    }

    if (ultra and trunk_dir == null) {
        errw.print("--ultra-low-memory needs --trunk; resident trunk cannot fit its " ++
            "memory contract\n", .{}) catch {};
        return 2;
    }
    if (ultra and budget_auto) {
        errw.print("--ultra-low-memory uses explicit bounded budgets; use " ++
            "--preset ultra or pass --trunk-gb/--cache-gb\n", .{}) catch {};
        return 2;
    }
    if (ultra and (spec_n > 0 or draft_dir != null)) {
        errw.print("--ultra-low-memory does not yet support --spec or --draft-trunk; " ++
            "use deterministic serial decode\n", .{}) catch {};
        return 2;
    }
    const sampling_on = temperature != 0 or top_k != 0 or top_p != 0 or rep_penalty != 1 or tunnel_tail != 0;
    if (tunnel_tail != 0) {
        if (tunnel_tail < 0 or top_p <= 0) {
            errw.print("--tunnel-tail needs --top-p and a non-negative decay\n", .{}) catch {};
            return 2;
        }
    }
    k3.tunnel_prefetch = tunnel_prefetch;
    if (verify_rewind) {
        if (!incremental) {
            errw.print("--verify-rewind needs --incremental (per-step carried state)\n", .{}) catch {};
            return 2;
        }
        if (spec_n > 0 or draft_dir != null) {
            errw.print("--verify-rewind does not compose with --spec/--draft-trunk; " ++
                "the draft path manages its own acceptance rewind\n", .{}) catch {};
            return 2;
        }
    }
    if (sampling_on and (spec_n > 0 or draft_dir != null)) {
        // Batched draft verification is a greedy-identity contract; a
        // stochastic pick cannot satisfy "accepted == serial argmax".
        errw.print("sampling flags do not compose with --spec/--draft-trunk; " ++
            "the verification contract is greedy-identity\n", .{}) catch {};
        return 2;
    }
    if (temperature < 0) {
        errw.print("--temperature must be >= 0 (0 = greedy argmax)\n", .{}) catch {};
        return 2;
    }
    if (top_p < 0 or top_p > 1) {
        errw.print("--top-p must be in [0, 1] (0 = off)\n", .{}) catch {};
        return 2;
    }
    if (rep_penalty <= 0) {
        errw.print("--rep-penalty must be > 0 (1 = off)\n", .{}) catch {};
        return 2;
    }
    {
        const nsrc = @intFromBool(ids_s != null) + @intFromBool(prompt_text != null) + @intFromBool(prompt_file != null);
        if (nsrc == 0) {
            errw.print("one of --ids, --prompt or --prompt-file is required\n", .{}) catch {};
            return 2;
        }
        if (nsrc > 1) {
            // Refuse rather than pick: silently preferring one source would
            // make a mistyped invocation run the WRONG prompt.
            errw.print("--ids, --prompt and --prompt-file are mutually exclusive\n", .{}) catch {};
            return 2;
        }
    }

    // ---- architecture dispatch ----
    // config.json's model_type selects the engine: kimi_k3 (or no config at
    // all, where the K3 hardcoded fallback below applies) stays on the K3
    // path; the GQA+MoE family (qwen3_moe / olmoe / phase-B hybrids) runs
    // the parallel model_gqa stack. An unreadable/absent config returns
    // null here and the K3 path produces its own diagnostics.
    if (peekGqa(alloc, dir, cfg_path)) |mt| {
        if (std.mem.eql(u8, mt, "qwen3_5_moe")) {
            if (ids_s == null or prompt_text != null or prompt_file != null) {
                errw.writeAll("qwen3.5 currently requires --ids; use --media for Q35M image/video input\n") catch {};
                return 2;
            }
            var qcfg_buf: [4096]u8 = undefined;
            const qcfg = cfg_path orelse (std.fmt.bufPrint(&qcfg_buf, "{s}/config.json", .{dir}) catch return 2);
            return qwen35_cli.run(alloc, dir, qcfg, ids_s.?, media_path, vision_dump_path, logits_path, @intCast(@max(gen, 0)), out, errw);
        }
        return runGqa(alloc, dir, cfg_path, ids_s, prompt_text, prompt_file, tok_dir, gen, want_layers, logits_path, weights_peer, peer_auth, mt, out, errw);
    }

    // ---- auto budget ----
    // RAM-first: per token the engine re-reads the ENTIRE streamed trunk but
    // only a fraction of the routed experts, and steady-state expert caching
    // yields nothing until the arena is tens of GB. So auto gives the trunk
    // everything this machine has, minus a safety margin, and the cache gets
    // real memory only after the whole trunk would be resident.
    if (budget_auto) {
        const avail: f64 = @floatFromInt(pio.memAvailableBytes());
        if (avail <= 0.0) {
            errw.print("--preset auto needs /proc/meminfo; pass explicit " ++
                "--trunk-gb/--cache-gb on this platform\n", .{}) catch {};
            return 2;
        }
        // Fixed costs outside both budgets: embeddings + lm_head 4.70 GB,
        // safetensors index, recurrent state 0.63 GB, KV cache and scratch.
        // Reserve them plus a 2 GB + 2% margin so auto never invites the
        // OOM killer.
        const reserve = 2.0 + 0.02 * (avail / 1e9) + 4.70 + 1.70;
        const usable = avail / 1e9 - reserve;
        const slot_min = 2.5; // one ring slot + headroom; refuse below
        const cache_min = 0.5; // topk+1 expert slots is ~0.3 GB
        if (usable < slot_min + cache_min) {
            errw.print("auto: only {d:.1} GB usable after the {d:.1} GB reserve; " ++
                "below the {d:.1} GB floor. Pass explicit budgets.\n", .{ usable, reserve, slot_min + cache_min }) catch {};
            return 2;
        }
        const trunk_full = 111.0; // full packed trunk + widen headroom
        if (usable - cache_min >= trunk_full) {
            // Full residency: per-token trunk reads disappear entirely.
            trunk_gb = trunk_full;
            cache_gb = usable - trunk_full;
        } else {
            // Partial pinning has WEAK returns and real hazards on the
            // released checkpoint, so below full residency auto pins only
            // while the whole process stays comfortably clear of the RAM
            // ceiling (55% of MemTotal, falling back to the usable figure
            // when /proc is absent).
            const memtotal: f64 = @floatFromInt(pio.memTotalBytes());
            const rss_ceiling = if (memtotal > 0.0) 0.55 * memtotal / 1e9 else usable;
            var cap = rss_ceiling - reserve - cache_min;
            if (cap < slot_min) cap = slot_min;
            trunk_gb = usable - cache_min;
            if (trunk_gb > cap) trunk_gb = cap;
            cache_gb = cache_min;
        }
        out.print("auto budget: {d:.1} GB available, {d:.1} GB reserved -> trunk {d:.1} GB / " ++
            "expert cache {d:.1} GB\n", .{ avail / 1e9, reserve, trunk_gb, cache_gb }) catch {};
    }

    var c: k3.K3Cfg = .{};
    var diag: cfg.Diag = .{};
    if (!realCfg(alloc, &c, dir, cfg_path, &diag, out)) {
        errw.print("ABORTED: the model config could not be read with confidence.\n", .{}) catch {};
        return 2;
    }
    if (want_layers > 0 and want_layers < c.n_layers) {
        out.print("NOTE: binding only the first {d} of {d} layers. Output is NOT the full " ++
            "model; it is a partial stack for testing the machinery.\n\n", .{ want_layers, c.n_layers }) catch {};
    }

    // ---- optional GPU backend ----
    // Hooks the composite ops (mmw / kdaLayer / mlaCached / moe) onto a Vulkan
    // compute device. Integer q128 on both sides => bit-exact with the CPU
    // path; the GPU run IS the same computation, just dispatched differently.
    if (use_gpu) {
        gpu_mod.installBackend(alloc, gpu_device) catch |e| {
            errw.print("--gpu: backend init failed: {s}", .{@errorName(e)}) catch {};
            if (!gpu_mod.available) {
                errw.print(" (this binary was built without -Dgpu)\n", .{}) catch {};
            } else {
                errw.print("\n", .{}) catch {};
            }
            return 2;
        };
        out.print("gpu backend: composite kernels on Vulkan\n", .{}) catch {};
    }

    // ---- prompt ----
    // Three entry points, one representation. --ids is the reproducible
    // channel every fixture and the oracle use; --prompt / --prompt-file
    // tokenize here in Zig. The tokenizer is loaded ONLY when actually needed.
    const prompt = alloc.alloc(i32, k3.MAX_PROMPT) catch {
        errw.print("OOM allocating prompt buffer\n", .{}) catch {};
        return 2;
    };
    var np: usize = 0;
    var tokp: ?*tok_mod.Tok = null;
    const have_tok = prompt_text != null or prompt_file != null;

    if (have_tok) {
        if (tok_dir == null) {
            errw.print("--prompt/--prompt-file need --tok DIR (the directory with " ++
                "tiktoken.model and tokenizer_config.json)\n", .{}) catch {};
            return 2;
        }
        const t = tok_mod.Tok.init(alloc) catch {
            errw.print("OOM loading the tokenizer\n", .{}) catch {};
            return 1;
        };
        tok_loader.load(t, alloc, tok_dir.?) catch {
            errw.print("{s}: tokenizer load failed\n", .{tok_dir.?}) catch {};
            return 1;
        };
        tokp = t;

        var ptext: []const u8 = undefined;
        if (prompt_file) |pf| {
            // tk_read_file semantics: an unreadable prompt file is fatal (exit 1)
            ptext = std.fs.cwd().readFileAlloc(alloc, pf, 1 << 30) catch |e| {
                errw.print("{s}: {s}\n", .{ pf, @errorName(e) }) catch {};
                return 1;
            };
        } else {
            ptext = prompt_text.?;
        }
        np = t.encode(ptext, prompt) catch {
            errw.print("tokenize failed\n", .{}) catch {};
            return 1;
        };
        out.print("  tokenized: {d} bytes -> {d} ids\n", .{ ptext.len, np }) catch {};
    } else {
        const s = ids_s.?;
        var p: usize = 0;
        while (p < s.len and np < k3.MAX_PROMPT) {
            var q = p;
            var neg = false;
            if (s[q] == '+' or s[q] == '-') {
                neg = s[q] == '-';
                q += 1;
            }
            var v: i64 = 0;
            var saw = false;
            while (q < s.len and std.ascii.isDigit(s[q])) {
                v = v * 10 + (s[q] - '0');
                q += 1;
                saw = true;
            }
            if (!saw) {
                // C's strtol fills the prompt with zeros on unparsable input;
                // we append one 0 per character instead (see header note).
                prompt[np] = 0;
                np += 1;
                p += 1;
                continue;
            }
            prompt[np] = @intCast(std.math.clamp(if (neg) -v else v, @as(i64, std.math.minInt(i32)), @as(i64, std.math.maxInt(i32))));
            np += 1;
            p = q;
            while (p < s.len and (s[p] == ',' or s[p] == ' ')) p += 1;
        }
    }
    if (np == 0) {
        errw.print("no prompt ids parsed\n", .{}) catch {};
        return 2;
    }
    for (prompt[0..np]) |id| {
        if (id < 0 or id >= c.vocab) {
            errw.print("token id {d} is outside the vocabulary of {d}\n", .{ id, c.vocab }) catch {};
            return 2;
        }
    }

    // Validate the request before allocating anything. Refuse rather than
    // clamp: a caller who asks for more tokens than this build supports should
    // be told, not quietly handed fewer.
    if (gen < 0 or gen > k3.MAX_GEN) {
        errw.print("--gen {d} is out of range: this build generates at most {d} " ++
            "tokens (outtok[{d}])\n", .{ gen, k3.MAX_GEN, k3.MAX_GEN }) catch {};
        return 2;
    }
    if (np > k3.MAX_PROMPT) {
        errw.print("prompt of {d} ids exceeds the {d}-id ceiling (seq[{d}])\n", .{ np, k3.MAX_PROMPT, k3.MAX_PROMPT + k3.MAX_GEN }) catch {};
        return 2;
    }
    if (np + @as(usize, @intCast(gen)) + 1 > k3.MAX_PROMPT + k3.MAX_GEN) {
        errw.print("prompt {d} + gen {d} + 1 exceeds the {d}-position ceiling\n", .{ np, gen, k3.MAX_PROMPT + k3.MAX_GEN }) catch {};
        return 2;
    }
    // THE REAL CONTEXT LIMIT is the MLA KV cache, not any array size. Ours is
    // q128 elements (32 B), 8x the C f32 figure - computed from the config.
    if (incremental) {
        var n_mla_cfg: usize = 0;
        for (0..@intCast(c.n_layers)) |L| {
            if (c.isMla(@intCast(L))) n_mla_cfg += 1;
        }
        const kvpp = @as(usize, @intCast(c.n_heads)) * @as(usize, @intCast(c.qk_nope + c.v_head)) + @as(usize, @intCast(c.qk_rope));
        const kv_bpp = @as(f64, @floatFromInt(n_mla_cfg * kvpp * @sizeOf(Q)));
        const kv_need = @as(f64, @floatFromInt(np + @as(usize, @intCast(gen)) + 1)) * kv_bpp;
        const avail: f64 = @floatFromInt(pio.memAvailableBytes());
        var kb: [32]u8 = undefined;
        var ab: [32]u8 = undefined;
        out.print("  KV cache : {s} for {d} positions ({d:.2} MB/position)\n", .{ human(kv_need, &kb), np + @as(usize, @intCast(gen)) + 1, kv_bpp / 1e6 }) catch {};
        if (avail > 0.0 and kv_need > avail * 0.9) {
            errw.print("\nREFUSING: the KV cache for {d} positions needs {s} but only {s} is\n" ++
                "available. This is a MEMORY limit, not an engine ceiling: MLA caches\n" ++
                "expanded k and v across the MLA layers, so context costs per position\n" ++
                "regardless of budget. Shorten the request, or use full\n" ++
                "recompute (drop --incremental), which carries no KV cache at all.\n", .{ np + @as(usize, @intCast(gen)) + 1, human(kv_need, &kb), human(avail, &ab) }) catch {};
            return 2;
        }
    }

    var b1: [32]u8 = undefined;
    out.print("Kimi K3, pure C, released checkpoint\n", .{}) catch {};
    // The directory, not a shard count: the count comes from the "indexed"
    // line once st.open has actually counted them.
    out.print("  model    : {s}\n", .{dir}) catch {};
    out.print("  prompt   : {d} tokens, generating {d}\n", .{ np, gen }) catch {};
    if (preset_name) |pn| {
        out.print("  preset   : {s} (trunk {d:.2} GB / expert cache {d:.2} GB)\n", .{ pn, trunk_gb, cache_gb }) catch {};
    }
    out.print("\n", .{}) catch {};

    var s = if (weights_peer) |ep|
        st.St.openPeer(alloc, ep, peer_auth) catch {
            errw.print("peer {s}: safetensors open failed\n", .{ep}) catch {};
            return 1;
        }
    else
        st.St.open(alloc, dir) catch return 1;
    defer s.close();
    var trunk_store: trunk_mod.Trunk = undefined;
    var trunk_open = false;
    defer if (trunk_open) trunk_store.close();
    var trunk_d: trunk_mod.Trunk = undefined;
    var trunk_d_open = false;
    defer if (trunk_d_open) trunk_d.close();

    var t0 = nowS();
    out.print("indexed {d} tensors from {d} shards in {d:.2} s\n", .{ s.tensors.len, s.nshard(), nowS() - t0 }) catch {};

    // ---- how much will this take? Report BEFORE allocating, so a box that
    // cannot hold it fails with a number rather than an OOM kill. ----
    const NL: usize = if (want_layers > 0 and want_layers < c.n_layers) @intCast(want_layers) else @intCast(c.n_layers);
    var total: i64 = 0;
    var missing: usize = 0;
    for (0..NL) |L| {
        const n = bind.bindLayerBytes(&s, &c, @intCast(L));
        if (n < 0) {
            missing += 1;
            continue;
        }
        total += n;
    }
    if (missing > 0) {
        errw.print("\n{d} of {d} layers are missing tensors in this shard set. " ++
            "A partial download cannot run the model.\n", .{ missing, NL }) catch {};
        return 1;
    }
    // Report the mode actually in effect: the trunk is either resident or
    // streamed, and the two have very different memory profiles.
    if (trunk_dir != null) {
        out.print("trunk on disk : {s} total (STREAMED from {s}, not held in RAM)\n", .{ human(@floatFromInt(total), &b1), trunk_dir.? }) catch {};
    } else {
        out.print("resident trunk: {s} in RAM (large matrices kept in the checkpoint's bf16,\n" ++
            "  fp32 only for the norms and biases that kernels read elementwise)\n", .{human(@floatFromInt(total), &b1)}) catch {};
    }

    // Add up EVERYTHING before allocating anything. Being OOM-killed halfway
    // through binding wastes the whole load and reports nothing useful; a
    // refusal with the two numbers side by side says exactly what box this
    // needs. Element counts mirror C; the byte figures count q128 (32 B)
    // elements where C counted f32.
    {
        const E64: f64 = @floatFromInt(c.hidden);
        const w_trunk = if (trunk_dir != null) trunk_gb * 1e9 else @as(f64, @floatFromInt(total));
        const w_model = if (ultra)
            @as(f64, @floatFromInt(model.MODEL_STREAM_CHUNK)) + 2.0 * @as(f64, @floatFromInt(st.ST_ALIGN)) + 3.0 * E64 * @sizeOf(Q)
        else
            2.0 * @as(f64, @floatFromInt(c.vocab)) * E64 * 2 + 3.0 * E64 * @sizeOf(Q);
        const w_cache = cache_gb * 1e9;
        const Tm = np + @as(usize, @intCast(gen)) + 1;
        const mb = @divTrunc(c.n_layers, c.attn_res_block) + 2;
        const Pp = @as(usize, @intCast(c.kda_heads * c.kda_head_dim));
        const state_layers: usize = if (ultra and !incremental) 1 else NL;
        const w_state = @as(f64, @floatFromInt((Pp * @as(usize, @intCast(c.kda_head_dim)) + 3 * Pp * (@as(usize, @intCast(c.conv_k)) - 1)) * state_layers)) * @sizeOf(Q);
        const w_buf = (@as(f64, @floatFromInt(Tm)) * E64 + @as(f64, @floatFromInt(Tm)) * @as(f64, @floatFromInt(mb)) * E64 + @as(f64, @floatFromInt(k3.layerScratch(&c, Tm))) + @as(f64, @floatFromInt(c.vocab))) * @sizeOf(Q);
        // The KV cache MUST be in this total: it is the only term that grows
        // with context, so a guard that omits it is blind to the one thing it
        // exists to catch.
        var n_mla: usize = 0;
        for (0..@intCast(c.n_layers)) |L| {
            if (c.isMla(@intCast(L))) n_mla += 1;
        }
        const w_kv = if (incremental)
            @as(f64, @floatFromInt(Tm * n_mla * (@as(usize, @intCast(c.n_heads)) * @as(usize, @intCast(c.qk_nope + c.v_head)) + @as(usize, @intCast(c.qk_rope))))) * @sizeOf(Q)
        else
            0.0;
        const need_b = w_trunk + w_model + w_cache + w_state + w_buf + w_kv;
        const have: f64 = @floatFromInt(pio.memAvailableBytes());

        var b2: [32]u8 = undefined;
        var b3: [32]u8 = undefined;
        var b4: [32]u8 = undefined;
        var b5: [32]u8 = undefined;
        var b6: [32]u8 = undefined;
        var b7: [32]u8 = undefined;
        out.print("\nmemory plan\n", .{}) catch {};
        out.print("  trunk {s: <10} {s}\n  embed + lm_head  {s} {s}\n  expert cache     {s}\n" ++
            "  recurrent state  {s}\n  buffers          {s}\n  KV cache         {s}\n" ++
            "  TOTAL            {s}\n", .{
            if (trunk_dir != null) "(STREAMED)" else "(resident)",
            human(w_trunk, &b1),
            human(w_model, &b2),
            if (ultra) "(STREAMED)" else "(resident)",
            human(w_cache, &b3),
            human(w_state, &b4),
            human(w_buf, &b5),
            human(w_kv, &b7),
            human(need_b, &b6),
        }) catch {};
        if (have > 0.0) {
            out.print("  available        {s}\n", .{human(have, &b1)}) catch {};
            if (need_b > have * 0.95) {
                errw.print("\nREFUSING TO START: this needs {s} and the machine has {s} " ++
                    "available, a shortfall of {s}.\n" ++
                    "Options: a larger box, a smaller --cache-gb, or fewer --layers.\n", .{ human(need_b, &b6), human(have, &b1), human(need_b - have, &b2) }) catch {};
                return 1;
            }
        }
        out.print("\n", .{}) catch {};
    }

    var w = Weights{};
    defer if (w.ms) |*msp| msp.deinit();
    w.lay = alloc.alloc(bind.LayerBind, NL) catch return 1;
    w.ultra = ultra;

    t0 = nowS();
    if (trunk_dir) |td| {
        // STREAMED. Nothing is bound up front: each layer is read from the
        // packed trunk on fast local storage as the forward pass reaches it.
        // RAM stops being a floor and becomes a dial, and unlike quantisation
        // it costs no accuracy.
        if (peerUri(td)) |ep| {
            trunk_store.openPeer(alloc, ep, peer_auth, &c, @intFromFloat(trunk_gb * 1e9)) catch return 1;
        } else {
            trunk_store.open(alloc, td, &c, @intFromFloat(trunk_gb * 1e9)) catch return 1;
        }
        trunk_open = true;
        if (@as(usize, @intCast(trunk_store.n_layers)) < NL) {
            errw.print("packed trunk has {d} layers, need {d}\n", .{ trunk_store.n_layers, NL }) catch {};
            return 1;
        }
        w.trunk = &trunk_store;
        w.n_bound = NL;
        out.print("trunk streaming enabled from {s} in {d:.1} s\n", .{ td, nowS() - t0 }) catch {};
    } else {
        for (0..NL) |L| {
            if (bind.bindLayer(alloc, &s, &c, @intCast(L), &w.lay[L]) != 0) {
                errw.print("bind failed at layer {d}\n", .{L}) catch {};
                return 1;
            }
            w.n_bound = L + 1;
            if ((L + 1) % 10 == 0 or L + 1 == NL) {
                out.print("  bound {d}/{d} layers, {d:.1} s elapsed\n", .{ L + 1, NL, nowS() - t0 }) catch {};
            }
        }
        const t_bind = nowS() - t0;
        out.print("trunk loaded in {d:.1} s ({d:.0} MB/s from disk)\n", .{ t_bind, @as(f64, @floatFromInt(total)) / 1e6 / t_bind }) catch {};
    }

    t0 = nowS();
    if (bind.bindModelParts(alloc, &s, &c, !ultra, !ultra, &w.mb) != 0) return 1;
    if (ultra) {
        w.ms = model.ModelStream.init(&s, &c) catch return 1;
    }
    if (ultra) {
        out.print("final norms: {s} resident; embedding and lm_head streamed in {d:.1} s\n\n", .{ human(@floatFromInt(w.mb.nbytes), &b1), nowS() - t0 }) catch {};
    } else {
        out.print("embedding, final norm and lm_head: {s} in {d:.1} s\n\n", .{ human(@floatFromInt(w.mb.nbytes), &b1), nowS() - t0 }) catch {};
    }

    var cache: cache_mod.Cache = .{};
    cache.init(alloc, &s, &c, @intFromFloat(cache_gb * 1e9)) catch return 1;
    defer cache.deinit();

    // The plan is a forecast. This is the outcome.
    {
        var rb: [32]u8 = undefined;
        out.print("peak RSS after loading weights: {s}  (the plan above is a forecast, " ++
            "this is measured)\n", .{human(@floatFromInt(pio.peakRssBytes()), &rb)}) catch {};
    }
    out.print("expert cache: {d} slots x {d:.2} MB = {d:.2} GB ({d:.2}% of the 1.45 TB expert pool)\n\n", .{
        cache.nslot,
        @as(f64, @floatFromInt(cache.slot_bytes)) / 1e6,
        @as(f64, @floatFromInt(cache.nslot)) * @as(f64, @floatFromInt(cache.slot_bytes)) / 1e9,
        100.0 * @as(f64, @floatFromInt(cache.nslot)) / (92.0 * @as(f64, @floatFromInt(c.n_experts))),
    }) catch {};

    // ---- exec peers (OP_EXEC fabric compute) --------------------------------
    // --exec-peer a:9471,b:9472 — each endpoint becomes an ExecPeer on an
    // authenticated session; the mux answers ExpertSrc.exec by stable
    // (layer, expert) → peer assignment, and falls back to the local
    // cache on any failure. Remote results are bit-identical by contract.
    var exec_mux: ?fabexec.ExecMux = null;
    var exec_sessions: [8]peersrc.Session = undefined;
    var exec_bufs: [8]struct { scratch: []u8 = &.{}, wire: []u8 = &.{} } = .{ .{}, .{}, .{}, .{}, .{}, .{}, .{}, .{} };
    var exec_peer_arr: [8]fabexec.ExecPeer = undefined;
    var n_exec: usize = 0;
    defer {
        for (exec_bufs) |b| {
            if (b.scratch.len > 0) alloc.free(b.scratch);
            if (b.wire.len > 0) alloc.free(b.wire);
        }
        for (exec_sessions[0..n_exec]) |*sess| sess.stream.close();
    }
    if (exec_peers) |eps| {
        var it = std.mem.splitScalar(u8, eps, ',');
        while (it.next()) |ep| {
            if (ep.len == 0) continue;
            if (n_exec == 8) {
                errw.print("--exec-peer supports at most 8 endpoints\n", .{}) catch {};
                return 2;
            }
            const stream = peersrc.connect(ep) catch |e| {
                errw.print("exec peer {s}: connect failed: {s}\n", .{ ep, @errorName(e) }) catch {};
                return 1;
            };
            exec_sessions[n_exec] = peersrc.Session.client(stream, peer_auth) catch |e| {
                errw.print("exec peer {s}: handshake failed: {s}\n", .{ ep, @errorName(e) }) catch {};
                return 1;
            };
            exec_bufs[n_exec].scratch = alloc.alloc(u8, @as(usize, @intCast(c.latent)) * 32 + 64) catch return 1;
            exec_bufs[n_exec].wire = alloc.alloc(u8, exec_bufs[n_exec].scratch.len + 256) catch return 1;
            exec_peer_arr[n_exec] = .{
                .sess = &exec_sessions[n_exec],
                .scratch = exec_bufs[n_exec].scratch,
                .wire = exec_bufs[n_exec].wire,
            };
            n_exec += 1;
        }
        if (n_exec > 0) {
            exec_mux = fabexec.ExecMux.init(&cache.src, exec_peer_arr[0..n_exec]);
            w.expert_src = exec_mux.?.source();
            out.print("exec peers: {d} endpoint(s); routed experts go remote-first, " ++
                "local cache is the fallback\n\n", .{n_exec}) catch {};
        }
    }

    // ---- buffers ----
    // A resumed session must hold the saved history as well as the new
    // tokens, so the KV cache and every per-position buffer are sized for
    // both. The header is read here, before anything is allocated; the
    // payload is restored after.
    var shd: StateHdr = undefined;
    var prior: usize = 0;
    if (load_state) |ls| {
        if (!incremental) {
            errw.print("--load-state needs --incremental\n", .{}) catch {};
            return 2;
        }
        if (statePeek(ls, &shd, errw) != 0) return 1;
        prior = @intCast(shd.nseq);
        out.print("resuming from {s}: {d} prior positions, {d} new\n\n", .{ ls, prior, np }) catch {};
    }
    const Tmax = prior + np + @as(usize, @intCast(gen)) + 1;
    const E: usize = @intCast(c.hidden);
    const maxb: usize = @intCast(@divTrunc(c.n_layers, c.attn_res_block) + 2);
    const P: usize = @intCast(c.kda_heads * c.kda_head_dim);
    const kper = P * @as(usize, @intCast(c.kda_head_dim)) + 3 * P * (@as(usize, @intCast(c.conv_k)) - 1);

    // The model-level aggregator lays out fold[E] followed by (nb+1) source
    // rows inside scratch, and nb reaches n_layers/attn_res_block at full
    // depth, so scratch must hold at least (maxb + 2) * hidden elements. It is
    // checked rather than assumed: an off-by-one here would overwrite whatever
    // follows without any symptom until the logits came out subtly wrong.
    {
        const need_scratch = (maxb + 2) * E;
        const have_scratch = k3.layerScratch(&c, Tmax);
        if (have_scratch < need_scratch) {
            errw.print("scratch is {d} elements, the attn-res aggregator needs {d}\n", .{ have_scratch, need_scratch }) catch {};
            return 1;
        }
    }

    const state_layers: usize = if (ultra and !incremental) 1 else NL;
    const h = alloc.alloc(Q, Tmax * E) catch return 1;
    const br = alloc.alloc(Q, Tmax * maxb * E) catch return 1;
    const ks = alloc.alloc(Q, kper * state_layers) catch return 1;
    var sc_need = k3.layerScratch(&c, Tmax);
    {
        // the cached MLA path sizes its score buffer by cache capacity, not T
        const ic = k3.mlaScratchCached(&c, Tmax, Tmax, true);
        if (ic > sc_need) sc_need = ic;
    }
    const sc = alloc.alloc(Q, sc_need) catch return 1;
    const lg = alloc.alloc(Q, @intCast(c.vocab)) catch return 1;
    // Sampling (off by default → the emit sites below stay exact argmax).
    // work is the filter/sort scratch: filtered copy plus sort buffer.
    var sampler: ?sample.Sampler = null;
    var sample_work: []i256 = &.{};
    if (sampling_on) {
        sample_work = alloc.alloc(i256, 2 * @as(usize, @intCast(c.vocab))) catch return 1;
        sampler = sample.Sampler.init(.{
            .temperature = if (temperature == 0) 0 else q128.fromF64(temperature),
            .top_k = @intCast(@max(top_k, 0)),
            .top_p = if (top_p == 0) 0 else q128.fromF64(top_p),
            .repetition_penalty = q128.fromF64(rep_penalty),
            .tunnel_tail = if (tunnel_tail == 0) 0 else q128.fromF64(tunnel_tail),
            .seed = seed,
        });
        errw.print("sampling: temp={d} top-k={d} top-p={d} rep={d} seed={d}\n", .{ temperature, top_k, top_p, rep_penalty, seed }) catch {};
    }
    if (state_layers == 1 and NL > 1) {
        out.print("recurrent state: one {s} slot, cleared and reused across {d} layers\n\n", .{ human(@floatFromInt(kper * state_layers * @sizeOf(Q)), &b1), NL }) catch {};
    } else {
        out.print("recurrent state for {d} layers: {s}\n\n", .{ state_layers, human(@floatFromInt(kper * state_layers * @sizeOf(Q)), &b1) }) catch {};
    }

    // ---- generate ----
    // Sized from the ACTUAL request, not from the ceiling.
    const seq = alloc.alloc(i32, prior + np + @as(usize, @intCast(gen)) + 8) catch return 1;
    const outtok = alloc.alloc(i32, @as(usize, @intCast(gen)) + 8) catch return 1;
    // On a resume the saved history occupies the front of the sequence and the
    // prompt given now is its continuation; the restore below fills seq[0..prior).
    @memcpy(seq[prior .. prior + np], prompt[0..np]);
    var T = prior + np;
    var nout: usize = 0;

    // ---- optional incremental decode ----
    // Full recompute re-runs the whole prefix every step, so expert traffic
    // grows with context. Incremental prefills once and then feeds ONE token
    // per step, carrying the KDA recurrent state and an MLA KV cache.
    if (incremental) {
        w.mla_slot = alloc.alloc(i32, NL) catch return 1;
        w.n_mla = 0;
        for (0..NL) |L| {
            w.mla_slot[L] = if (c.isMla(@intCast(L))) @intCast(w.n_mla) else -1;
            if (c.isMla(@intCast(L))) w.n_mla += 1;
        }
        w.kv_cap = Tmax;
        const kvper = w.kv_cap * @as(usize, @intCast(c.n_heads)) * @as(usize, @intCast(c.qk_nope + c.v_head));
        const rpper = w.kv_cap * @as(usize, @intCast(c.qk_rope));
        const kvb = (kvper + rpper) * w.n_mla * @sizeOf(Q);
        out.print("incremental decode: KV cache {s} for {d} MLA layers at {d} positions\n\n", .{ human(@floatFromInt(kvb), &b1), w.n_mla, w.kv_cap }) catch {};
        w.kvc = alloc.alloc(Q, kvper * w.n_mla) catch {
            errw.print("KV cache allocation failed\n", .{}) catch {};
            return 1;
        };
        w.ropec = alloc.alloc(Q, rpper * w.n_mla) catch {
            errw.print("KV cache allocation failed\n", .{}) catch {};
            return 1;
        };
        @memset(w.kvc.?, zero);
        @memset(w.ropec.?, zero);
        @memset(ks[0 .. kper * NL], zero);
        w.cached = 0;

        if (load_state) |ls| {
            const tl = nowS();
            if (stateLoad(ls, &c, &shd, seq, ks, w.kvc.?, w.ropec.?, w.n_bound, w.n_mla, w.kv_cap, errw) != 0)
                return 1;
            w.cached = @intCast(shd.cached);
            out.print("restored {d} positions in {d:.2} s: decode continues without " ++
                "re-reading the prior context\n\n", .{ w.cached, nowS() - tl }) catch {};
        }
    }

    // --spec needs a snapshot of the carried KDA/ShortConv state to roll back
    // a partially-rejected draft batch: the recurrent state is updated in
    // place and is not positional, so the only sound recovery is
    // restore-and-replay the accepted prefix.
    const kper_f = kper;
    var spec_snap: ?[]Q = null;
    if (spec_n > 0) {
        if (!incremental) {
            errw.print("--spec needs --incremental; ignoring --spec\n", .{}) catch {};
            spec_n = 0;
        } else {
            if (spec_n > SPEC_MAX) spec_n = SPEC_MAX;
            spec_snap = alloc.alloc(Q, kper_f * w.n_bound) catch {
                errw.print("OOM for the --spec snapshot\n", .{}) catch {};
                return 1;
            };
            out.print("speculative decode: up to {d} drafted tokens per sweep, n-gram lookup, " ++
                "verified batched\n\n", .{spec_n}) catch {};
        }
    }

    // --verify-rewind: tape a per-step receipt (pre-step recurrent snapshot +
    // input + logits fold) and replay the steps in reverse after decode,
    // proving the recorded trajectory is exactly recoverable. Verified
    // snapshot replay — not a functional inverse (docs/REVERSIBLE.md).
    var rewind_tape = std.ArrayList(RewindFrame).init(alloc);
    defer {
        for (rewind_tape.items) |*frame| {
            alloc.free(frame.input);
            alloc.free(frame.ks_snap);
        }
        rewind_tape.deinit();
    }
    const rewind_cap: usize = if (rewind_depth > 0) rewind_depth else std.math.maxInt(usize);
    if (verify_rewind) {
        var fb: [32]u8 = undefined;
        out.print("rewind verification: per-step state snapshots of {s}; " ++
            "replayed in reverse after decode\n\n", .{human(@floatFromInt(kper_f * w.n_bound * @sizeOf(Q)), &fb)}) catch {};
    }

    // ---- scheduler commit emission (--sched-emit) --------------------------
    // The E5→E7 contract path: every emitted token is summarized as an
    // Observation (receipt folds only — never tensors) and committed by the
    // scale-0 orchestrator, which accepts verbatim by construction. The JSONL
    // is what the comms-AI sidecar consumes to schedule the fabric. Tokens
    // are written to seq/outtok BEFORE this block reads them — the organ
    // cannot perturb the decode it observes.
    var sched_emit_f: ?std.fs.File = null;
    var sched_emit_w: ?Writer = null;
    var sched_orc = sched.Orchestrator.init(sched.ScalePolicy.forScale(0));
    var traj_fold: u256 = 0;
    if (sched_emit_path) |sp| {
        sched_emit_f = std.fs.cwd().createFile(sp, .{}) catch null;
        if (sched_emit_f) |sf| {
            sched_emit_w = sf.writer().any();
        } else {
            errw.print("k3: cannot open --sched-emit {s}; emission off\n", .{sp}) catch {};
        }
    }
    defer if (sched_emit_f) |sf| sf.close();

    // ---- hybrid decode: a second, typically quantized, trunk drafts ----
    // The draft shares everything identical between the two models: the
    // embedding, the lm_head, the layer map, and the routed experts. It
    // differs ONLY in trunk weights, so it needs its own trunk stream, its
    // own layer bindings, and its own recurrent/KV state. Output exactness is
    // structural: drafts feed the SAME batched greedy verification as --spec.
    var dw = Weights{};
    var dks: []Q = &.{};
    var dsnap: []Q = &.{};
    var hyb_rounds: i64 = 0;
    var hyb_drafted: i64 = 0;
    var hyb_accepted: i64 = 0;
    if (draft_dir != null) {
        if (!incremental or trunk_dir == null) {
            errw.print("--draft-trunk needs --incremental and --trunk; ignoring\n", .{}) catch {};
            draft_dir = null;
        } else {
            if (spec_n <= 0) spec_n = 4;
            if (spec_n > SPEC_MAX) spec_n = SPEC_MAX;
            if (spec_snap == null) {
                spec_snap = alloc.alloc(Q, kper_f * w.n_bound) catch {
                    errw.print("OOM for the --spec snapshot\n", .{}) catch {};
                    return 1;
                };
            }
            if (peerUri(draft_dir.?)) |ep| {
                trunk_d.openPeer(alloc, ep, peer_auth, &c, @intFromFloat(draft_gb * 1e9)) catch return 1;
            } else {
                trunk_d.open(alloc, draft_dir.?, &c, @intFromFloat(draft_gb * 1e9)) catch return 1;
            }
            trunk_d_open = true;
            dw.lay = alloc.alloc(bind.LayerBind, NL) catch return 1;
            dks = alloc.alloc(Q, kper_f * w.n_bound) catch {
                errw.print("OOM for the draft model state\n", .{}) catch {};
                return 1;
            };
            dsnap = alloc.alloc(Q, kper_f * w.n_bound) catch {
                errw.print("OOM for the draft model state\n", .{}) catch {};
                return 1;
            };
            const kvperd = w.kv_cap * @as(usize, @intCast(c.n_heads)) * @as(usize, @intCast(c.qk_nope + c.v_head));
            const rpperd = w.kv_cap * @as(usize, @intCast(c.qk_rope));
            dw.kvc = alloc.alloc(Q, kvperd * w.n_mla) catch {
                errw.print("OOM for the draft model state\n", .{}) catch {};
                return 1;
            };
            dw.ropec = alloc.alloc(Q, rpperd * w.n_mla) catch {
                errw.print("OOM for the draft model state\n", .{}) catch {};
                return 1;
            };
            @memset(dks, zero);
            @memset(dw.kvc.?, zero);
            @memset(dw.ropec.?, zero);
            dw.mb = w.mb; // embed + lm_head are the same tensors
            dw.trunk = &trunk_d;
            dw.n_bound = w.n_bound;
            dw.mla_slot = w.mla_slot; // read-only map, safely shared
            dw.n_mla = w.n_mla;
            dw.kv_cap = w.kv_cap;
            dw.cached = 0;
            dw.draft_mode = true; // cache-only routing: the draft reads no new experts
            out.print("hybrid decode: draft trunk {s} ({d:.1} GB budget) proposes up to {d} " ++
                "tokens per sweep;\n               the exact model verifies every one " ++
                "before it is emitted\n\n", .{ draft_dir.?, draft_gb, spec_n }) catch {};
        }
    }

    // --tf-check: teacher-forced agreement over the whole --ids sequence in
    // ONE sweep. Prediction i is the argmax after positions 0..i; it is
    // compared to the id the sequence actually continues with.
    if (tf_check) {
        if (np < 2) {
            errw.print("--tf-check needs at least 2 ids\n", .{}) catch {};
            return 2;
        }
        const arg = alloc.alloc(i32, np) catch {
            errw.print("OOM for --tf-check\n", .{}) catch {};
            return 1;
        };
        const t0c = nowS();
        if (forward(&w, &c, &cache, seq[0..np], lg, sc, h, br, ks, arg, errw) != 0) {
            errw.print("forward failed in --tf-check\n", .{}) catch {};
            return 1;
        }
        var match: usize = 0;
        for (0..np - 1) |j| {
            if (arg[j] == seq[j + 1]) match += 1;
        }
        out.print("teacher-forced agreement: {d}/{d} positions ({d:.1}%) in {d:.1} s\n", .{ match, np - 1, 100.0 * @as(f64, @floatFromInt(match)) / @as(f64, @floatFromInt(np - 1)), nowS() - t0c }) catch {};
        out.print("  per-position (p=predicted a=actual): ", .{}) catch {};
        for (0..np - 1) |j| {
            if (arg[j] != seq[j + 1])
                out.print("[{d} p={d} a={d}] ", .{ j, arg[j], seq[j + 1] }) catch {};
        }
        out.print("\n", .{}) catch {};
        if (std.fs.cwd().createFile(outp, .{})) |tf| {
            defer tf.close();
            tf.writer().print("{{\"tf_positions\":{d},\"tf_matches\":{d},\"tf_agreement\":{d:.4}}}\n", .{ np - 1, match, @as(f64, @floatFromInt(match)) / @as(f64, @floatFromInt(np - 1)) }) catch {};
        } else |_| {}
        return 0;
    }

    out.print("{s: <6} {s: <10} {s: <12} {s: <10} {s: <10} {s}\n", .{ "STEP", "TOKEN", "SECONDS", "CACHE HIT", "READ GB", "TOK/S" }) catch {};
    out.print("--------------------------------------------------------------------\n", .{}) catch {};
    k3.expert_drops = 0;
    var t_total: f64 = 0;
    // Per-step cache statistics are reset each iteration so the columns below
    // describe that step alone; the end-of-run summary needs whole-run totals,
    // so accumulate the expert side here. The trunk side is already
    // cumulative.
    var expert_ns_total: u64 = 0;
    var expert_gb_total: f64 = 0;
    var expert_reqs_total: u64 = 0;
    var expert_evict_total: u64 = 0;
    var expert_bytes_total: u64 = 0;

    var g: usize = 0;
    while (nout < @as(usize, @intCast(gen))) : (g += 1) {
        cache.resetStats();
        const ts = nowS();
        var frc: i32 = 0;
        var emit: [SPEC_MAX + 1]i32 = undefined;
        var emitn: usize = 0;
        if (incremental and g == 0) {
            // Step 0 feeds everything not yet consumed: the whole prompt on a
            // fresh run, and on a resume the carried pending token PLUS the
            // new prompt.
            const base = w.cached;
            const nT0 = T - base;
            var taped: ?usize = null;
            if (verify_rewind and rewind_tape.items.len < rewind_cap) taped = tapeFrame(alloc, &rewind_tape, seq[base..T], ks[0 .. kper_f * w.n_bound], base);
            frc = forward(&w, &c, &cache, seq[base..T], lg, sc, h, br, ks, null, errw);
            if (frc == 0) {
                w.cached = base + nT0;
                emit[emitn] = if (sampler) |*sm|
                    @intCast(sm.pick(lg[0..@intCast(c.vocab)], seq[0..T], sample_work))
                else
                    @intCast(model.argmax(lg[0..@intCast(c.vocab)]));
                emitn += 1;
                if (taped) |ti| sealFrame(&rewind_tape.items[ti], emit[emitn - 1], lg[0..@intCast(c.vocab)]);
            }
            // The draft model must absorb the same context, or its first
            // proposals come from a shorter one. Saved state does not include
            // the draft's, so a resumed run replays the WHOLE sequence through
            // the draft once; correctness never depends on this.
            if (dw.trunk != null and frc == 0) {
                const db: usize = if (load_state != null) 0 else base;
                if (forward(&dw, &c, &cache, seq[db .. base + nT0], lg, sc, h, br, dks, null, errw) == 0) {
                    dw.cached = base + nT0;
                } else frc = -1;
            }
        } else if (incremental) {
            const base = w.cached;
            var d: [SPEC_MAX]i32 = undefined;
            var nd: usize = 0;
            const spec_cap: usize = @intCast(spec_n);
            if (spec_snap != null and T + spec_cap + 1 < Tmax and base + spec_cap + 1 <= w.kv_cap) {
                if (dw.trunk != null) {
                    // The draft model proposes: k sequential one-token steps
                    // through the draft trunk, chaining its own argmax. Its
                    // state is snapshotted first so a partial acceptance can
                    // rewind it the same way the exact side rewinds.
                    @memcpy(dsnap, dks);
                    var prev = seq[base];
                    while (nd < spec_cap) {
                        const psl = [_]i32{prev};
                        if (forward(&dw, &c, &cache, &psl, lg, sc, h, br, dks, null, errw) != 0) break;
                        dw.cached += 1;
                        prev = @intCast(model.argmax(lg[0..@intCast(c.vocab)]));
                        d[nd] = prev;
                        nd += 1;
                    }
                    hyb_rounds += 1;
                    hyb_drafted += @intCast(nd);
                } else {
                    nd = specDraft(seq[0..T], spec_cap, &d);
                }
            }
            if (nd > 0) {
                // One sweep verifies the pending token plus nd drafts. arg[i]
                // is the model's own next token after batch position i; the
                // accepted prefix is exactly what serial decode would emit.
                var arg: [SPEC_MAX + 1]i32 = undefined;
                @memcpy(spec_snap.?, ks[0 .. kper_f * w.n_bound]);
                for (0..nd) |j| seq[T + j] = d[j];
                frc = forward(&w, &c, &cache, seq[base .. base + nd + 1], lg, sc, h, br, ks, &arg, errw);
                if (frc == 0) {
                    var m: usize = 0;
                    while (m < nd and arg[m] == d[m]) m += 1;
                    if (m == nd) {
                        // every fed position had true context; state is exact
                        w.cached = base + nd + 1;
                    } else {
                        // the recurrent state absorbed rejected tokens:
                        // restore, then replay only the accepted prefix. The
                        // replay also rewrites the KV rows those positions
                        // touched, so nothing stale survives.
                        @memcpy(ks[0 .. kper_f * w.n_bound], spec_snap.?);
                        w.cached = base;
                        frc = forward(&w, &c, &cache, seq[base .. base + m + 1], lg, sc, h, br, ks, null, errw);
                        if (frc == 0) w.cached = base + m + 1;
                    }
                    // Resync the draft model to the ACCEPTED sequence.
                    if (dw.trunk != null and frc == 0) {
                        hyb_accepted += @intCast(m);
                        if (m == nd) {
                            const last = d[nd - 1];
                            const lsl = [_]i32{last};
                            if (forward(&dw, &c, &cache, &lsl, lg, sc, h, br, dks, null, errw) == 0) {
                                dw.cached += 1;
                            } else frc = -1;
                        } else {
                            @memcpy(dks, dsnap);
                            dw.cached = base;
                            if (forward(&dw, &c, &cache, seq[base .. base + m + 1], lg, sc, h, br, dks, null, errw) == 0) {
                                dw.cached = base + m + 1;
                            } else frc = -1;
                        }
                    }
                    if (frc == 0) {
                        for (0..m) |j| {
                            emit[emitn] = d[j];
                            emitn += 1;
                        }
                        emit[emitn] = arg[m];
                        emitn += 1;
                    }
                }
            } else {
                var taped: ?usize = null;
                if (verify_rewind and rewind_tape.items.len < rewind_cap) taped = tapeFrame(alloc, &rewind_tape, seq[base .. base + 1], ks[0 .. kper_f * w.n_bound], base);
                frc = forward(&w, &c, &cache, seq[base .. base + 1], lg, sc, h, br, ks, null, errw);
                if (frc == 0) {
                    w.cached = base + 1;
                    emit[emitn] = if (sampler) |*sm|
                        @intCast(sm.pick(lg[0..@intCast(c.vocab)], seq[0..T], sample_work))
                    else
                        @intCast(model.argmax(lg[0..@intCast(c.vocab)]));
                    emitn += 1;
                    if (taped) |ti| sealFrame(&rewind_tape.items[ti], emit[emitn - 1], lg[0..@intCast(c.vocab)]);
                }
                // keep the draft in lockstep through non-drafted steps
                if (dw.trunk != null and frc == 0) {
                    if (forward(&dw, &c, &cache, seq[base .. base + 1], lg, sc, h, br, dks, null, errw) == 0) {
                        dw.cached = base + 1;
                    } else frc = -1;
                }
            }
        } else {
            frc = forward(&w, &c, &cache, seq[0..T], lg, sc, h, br, ks, null, errw);
            if (frc == 0) {
                emit[emitn] = if (sampler) |*sm|
                    @intCast(sm.pick(lg[0..@intCast(c.vocab)], seq[0..T], sample_work))
                else
                    @intCast(model.argmax(lg[0..@intCast(c.vocab)]));
                emitn += 1;
            }
        }
        // Abort the run rather than argmax a buffer the forward never wrote.
        if (frc != 0 or emitn == 0) {
            errw.print("forward pass failed at generation step {d}; aborting.\n", .{g}) catch {};
            return 1;
        }
        const nxt = emit[emitn - 1];
        // Dump the FIRST step's logits as raw float32 bits - the one check
        // that can see a small systematic error in the final norm, the
        // lm_head, or the model-level AttnRes. Ours are q128; the file format
        // (f32 little-endian) is identical.
        if (logits_path != null and g == 0) {
            if (std.fs.cwd().createFile(logits_path.?, .{})) |lf| {
                defer lf.close();
                const vocab: usize = @intCast(c.vocab);
                const f32buf = alloc.alloc(u8, vocab * 4) catch {
                    errw.print("OOM for the logits dump\n", .{}) catch {};
                    return 1;
                };
                for (lg[0..vocab], 0..) |v, vi| {
                    const fv: f32 = @floatCast(v.toF64());
                    std.mem.writeInt(u32, f32buf[vi * 4 ..][0..4], @bitCast(fv), .little);
                }
                lf.writeAll(f32buf) catch {
                    errw.print("cannot write {s} for the logits dump\n", .{logits_path.?}) catch {};
                    return 1;
                };
                out.print("wrote {s} ({d} float32 logits)\n", .{ logits_path.?, c.vocab }) catch {};
            } else |_| {
                errw.print("cannot open {s} for the logits dump\n", .{logits_path.?}) catch {};
            }
        }
        const dt = nowS() - ts;
        t_total += dt;
        const req = cache.hits + cache.misses;
        // (space-fill + signed {d} renders "+92" in Zig 0.13; C's %-10d is the
        // contract, so the column goes out unsigned)
        out.print("{d: <6} {d: <10} {d: <12.2} {d: <10.1} {d: <10.2} {d:.3}\n", .{ g, @as(u32, @intCast(nxt)), dt, if (req > 0) 100.0 * @as(f64, @floatFromInt(cache.hits)) / @as(f64, @floatFromInt(req)) else 0.0, @as(f64, @floatFromInt(cache.bytes_read)) / 1e9, 1.0 / dt }) catch {};
        // Roll the per-step figures up before the next reset wipes them.
        expert_ns_total += cache.load_ns;
        expert_gb_total += @as(f64, @floatFromInt(cache.bytes_read)) / 1e9;
        expert_bytes_total += cache.bytes_read;
        expert_reqs_total += cache.hits + cache.misses;
        expert_evict_total += cache.evictions;
        var ej: usize = 0;
        while (ej < emitn and nout < @as(usize, @intCast(gen)) and T < Tmax) : (ej += 1) {
            // Scale-0 scheduler commit: the observation rides on receipt
            // folds (logits/state/running checkpoint), the orchestrator
            // accepts verbatim, and the commit is pure telemetry — the
            // emitted token is written first and is never consulted or
            // altered by the scheduling organ. Scale 1/2 stay opt-in
            // elsewhere (sched tests), not in the decode hot path.
            const input_tok: u32 = if (T > 0) @intCast(@max(0, seq[T - 1])) else 0;
            seq[T] = emit[ej];
            T += 1;
            outtok[nout] = emit[ej];
            nout += 1;
            if (sched_emit_w) |sw| {
                const lg_fold = rev.logitsFold(lg[0..@intCast(c.vocab)]);
                const st_fold = rev.logitsFold(ks);
                traj_fold ^= lg_fold;
                const obs = sched.Observation{
                    .trajectory_id = @intCast(nout - 1),
                    .step = @intCast(nout - 1),
                    .input_token = input_tok,
                    .argmax_token = @intCast(emit[ej]),
                    .checkpoint_fold = traj_fold,
                    .logits_checksum = lg_fold,
                    .state_checksum = st_fold,
                    .coherence = Q.one,
                    .uncertainty = Q.zero,
                    .state_version = @intCast(w.cached),
                };
                var decs: [0]sched.Decision = .{};
                const res = sched_orc.run(obs, undefined, null, &decs) catch unreachable;
                const cm = res.commit;
                sw.print(
                    "{{\"step\":{d},\"commit\":{{\"trajectory_id\":{d},\"selected_token\":{d},\"model_fold\":\"{x}\",\"observer_fold\":\"{x}\",\"routing_fold\":\"{x}\",\"scale\":{d},\"branch_count\":{d}}},\"logits_fold\":\"{x}\",\"state_fold\":\"{x}\"}}\n",
                    .{ obs.step, cm.trajectory_id, cm.selected_token, cm.model_fold, cm.observer_fold, cm.routing_fold, cm.scale, cm.branch_count, lg_fold, st_fold },
                ) catch {};
            }
        }
        if (T >= Tmax) break;
    }
    if (save_state) |sv| {
        if (!incremental) {
            errw.print("--save-state needs --incremental; nothing written\n", .{}) catch {};
        } else {
            const tsv = nowS();
            const kvpp = @as(usize, @intCast(c.n_heads)) * @as(usize, @intCast(c.qk_nope + c.v_head));
            const ropepp: usize = @intCast(c.qk_rope);
            if (stateSave(sv, &c, seq[0..T], ks, w.kvc.?, w.ropec.?, w.n_bound, w.n_mla, w.kv_cap, w.cached, kper, kvpp, ropepp, errw) == 0) {
                const bytes = @as(f64, @sizeOf(StateHdr)) + @as(f64, @floatFromInt(T * 4)) + @as(f64, @floatFromInt(kper * w.n_bound)) * @sizeOf(Q) + @as(f64, @floatFromInt(w.cached * (kvpp + ropepp) * w.n_mla)) * @sizeOf(Q);
                var sb: [32]u8 = undefined;
                out.print("wrote {s} ({s}, {d} positions) in {d:.2} s\n", .{ sv, human(bytes, &sb), w.cached, nowS() - tsv }) catch {};
            }
        }
    }

    // Reverse traversal: restore each taped recurrent snapshot and replay the
    // step's input through the real forward. checksum_match=1 is bit-identical
    // proof the recorded trajectory is exactly recoverable from the tape —
    // verified replay, not a functional inverse (Digit ADR-0028). KV/rope
    // slots are append-only: each replay deterministically rewrites the
    // positions its own input covers and never disturbs the prefix.
    if (verify_rewind and rewind_tape.items.len > 0) {
        out.print("rewind depth={d}\n", .{rewind_tape.items.len}) catch {};
        var ri = rewind_tape.items.len;
        while (ri > 0) {
            ri -= 1;
            const frame = &rewind_tape.items[ri];
            @memcpy(ks[0 .. kper_f * w.n_bound], frame.ks_snap);
            w.cached = frame.cached;
            var checksum_match: u8 = 0;
            var argmax_match: u8 = 0;
            var rarg: i32 = -1;
            if (forward(&w, &c, &cache, frame.input, lg, sc, h, br, ks, null, errw) == 0) {
                w.cached = frame.cached + frame.input.len;
                rarg = @intCast(model.argmax(lg[0..@intCast(c.vocab)]));
                checksum_match = if (rev.logitsFold(lg[0..@intCast(c.vocab)]) == frame.fold) 1 else 0;
                argmax_match = if (rarg == frame.argmax) 1 else 0;
            } else {
                out.print("rewind_step={d} replay_failed\n", .{ri}) catch {};
                continue;
            }
            out.print("rewind_step={d} input={d} argmax={d} checksum_match={d} argmax_match={d}\n", .{ ri, frame.input[0], rarg, checksum_match, argmax_match }) catch {};
        }
    }

    if (dw.trunk != null and hyb_rounds > 0) {
        out.print("\nhybrid decode: {d} rounds, {d} drafted, {d} accepted ({d:.1}%), " ++
            "mean accepted run {d:.2}\n", .{ hyb_rounds, hyb_drafted, hyb_accepted, if (hyb_drafted > 0) 100.0 * @as(f64, @floatFromInt(hyb_accepted)) / @as(f64, @floatFromInt(hyb_drafted)) else 0.0, @as(f64, @floatFromInt(hyb_accepted)) / @as(f64, @floatFromInt(hyb_rounds)) }) catch {};
    }
    out.print("--------------------------------------------------------------------\n", .{}) catch {};
    out.print("{d} tokens in {d:.1} s, {d:.2} s/token average\n", .{ nout, t_total, t_total / @as(f64, @floatFromInt(nout)) }) catch {};

    // Decoded text, when a tokenizer is loaded. Printed as a distinct block:
    // a partially-decoded multi-byte sequence is not valid UTF-8, so streaming
    // would emit mojibake at every split codepoint.
    var generated_text: ?[]const u8 = null;
    if (tokp != null and nout > 0) {
        const buf = alloc.alloc(u8, nout * 8 + 1) catch null;
        if (buf) |tb| {
            const m = tokp.?.decode(outtok[0..nout], tb);
            generated_text = tb[0..m];
            out.print("\n--- generated text ---\n{s}\n----------------------\n\n", .{generated_text.?}) catch {};
        }
    }
    const peak_b = pio.peakRssBytes();
    {
        var rb: [32]u8 = undefined;
        out.print("PEAK RSS for the whole run: {s}   <- quote this, not the plan\n", .{human(@floatFromInt(peak_b), &rb)}) catch {};
        out.print("layers completed: {d}/{d}; routed expert drops: {d}\n\n", .{ w.layers_completed, NL, k3.expert_drops }) catch {};
    }
    cache.report("final step");

    if (std.fs.cwd().createFile(outp, .{})) |f| {
        defer f.close();
        var bw = std.io.bufferedWriter(f.writer());
        const wj = bw.writer().any();
        wj.print("{{\"prompt_ids\":[", .{}) catch {};
        for (prompt[0..np], 0..) |id, j| wj.print("{s}{d}", .{ if (j > 0) "," else "", id }) catch {};
        wj.print("],\"generated_ids\":[", .{}) catch {};
        for (outtok[0..nout], 0..) |id, j| wj.print("{s}{d}", .{ if (j > 0) "," else "", id }) catch {};
        wj.print("],\"full_ids\":[", .{}) catch {};
        for (seq[0..T], 0..) |id, j| wj.print("{s}{d}", .{ if (j > 0) "," else "", id }) catch {};
        wj.print("],\"layers\":{d},\"layers_requested\":{d},\"layers_completed\":{d}," ++
            "\"expert_drops\":{d},\"peak_rss_bytes\":{d:.0},\"wall_seconds\":{d:.4}," ++
            "\"seconds_per_token\":{d:.4},\"expert_bytes_read\":{d}," ++
            "\"trunk_bytes_read\":{d},\"embedding_bytes_read\":{d}," ++
            "\"lm_head_bytes_read\":{d},\"ultra_low_memory\":{s}," ++
            "\"generated_text\":", .{
            NL,                                          NL,                                            w.layers_completed,
            k3.expert_drops,                             @as(f64, @floatFromInt(peak_b)),               t_total,
            t_total / @as(f64, @floatFromInt(nout)),     expert_bytes_total,                            if (w.trunk) |tr| tr.bytes_read else 0,
            if (w.ms) |msp| msp.embed_bytes_read else 0, if (w.ms) |msp| msp.lm_head_bytes_read else 0, if (ultra) "true" else "false",
        }) catch {};
        jsonString(wj, generated_text);
        wj.writeAll("}\n") catch {};
        bw.flush() catch {};
        out.print("\nwrote {s}\n", .{outp}) catch {};
    } else |_| {}
    if (trace_dir) |td| {
        var pbuf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&pbuf, "{s}/expert_hist.json", .{td})) |hp| {
            cache.dumpHist(hp) catch {};
        } else |_| {}
        if (std.fmt.bufPrint(&pbuf, "{s}/expert_trace.bin", .{td})) |tp| {
            cache.dumpTrace(tp) catch {};
        } else |_| {}
    }

    // Report the compute-versus-I/O split rather than leaving it to be
    // inferred: a flat curve across a RAM sweep looks like a compute-bound
    // engine but is equally consistent with the trunk being streamed in full,
    // and only a direct measurement separates those.
    {
        const trunk_s = if (w.trunk) |tr| @as(f64, @floatFromInt(tr.load_ns)) / 1e9 else 0.0;
        const model_s = if (w.ms) |msp| @as(f64, @floatFromInt(msp.read_ns)) / 1e9 else 0.0;
        // Both terms MUST be whole-run totals over the same window.
        const io_s = trunk_s + @as(f64, @floatFromInt(expert_ns_total)) / 1e9 + model_s;
        const share = if (t_total > 0) 100.0 * io_s / t_total else 0.0;
        out.print("I/O share of wall clock: {d:.1}%  (trunk {d:.1} s + experts {d:.1} s + " ++
            "model tables {d:.1} s of {d:.1} s)\n", .{ share, trunk_s, @as(f64, @floatFromInt(expert_ns_total)) / 1e9, model_s, t_total }) catch {};
        out.print("  both figures are WHOLE-RUN totals over {d} steps\n", .{nout}) catch {};
        // Above 100% is not a bug in the arithmetic: with more than one trunk
        // ring slot the reader thread does device work while the main thread
        // computes, so the two terms genuinely overlap.
        if (share > 100.0)
            out.print("  over 100% because trunk reads overlap compute on the reader thread;\n" ++
                "  {d:.1} s of device time was hidden behind arithmetic\n", .{io_s - t_total}) catch {};
        // The DERIVED retention, not the raw hit count: `hits` counts an
        // expert the batch prefetch pulled off disk microseconds earlier, so
        // it equals the request count at every cache size. retained =
        // requests - evictions.
        const retained: u64 = if (expert_reqs_total > expert_evict_total) expert_reqs_total - expert_evict_total else 0;
        out.print("  experts, whole run: {d:.2} GB read | {d} of {d} requests retained in RAM" ++
            " ({d:.2}%) | {d} evictions\n" ++
            "    (retention = requests - evictions; the raw `hits` counter includes\n" ++
            "     experts the prefetcher had just read from disk, so it is not a\n" ++
            "     measure of avoided I/O)\n\n", .{
            expert_gb_total,    retained,
            expert_reqs_total,  if (expert_reqs_total > 0) 100.0 * @as(f64, @floatFromInt(retained)) / @as(f64, @floatFromInt(expert_reqs_total)) else 0.0,
            expert_evict_total,
        }) catch {};
    }
    if (w.trunk) |tr| tr.report("final");

    // A dropped expert means some token was computed with part of its routed
    // sum missing. The run still produced token ids and they still look
    // plausible, which is exactly why this has to be an error rather than a
    // note: silent numerical corruption that exits 0 is indistinguishable
    // from a good run.
    if (k3.expert_drops != 0) {
        errw.print("\nRUN INVALID: {d} routed expert load(s) failed and were dropped from\n" ++
            "the MoE sum. The token ids above are CORRUPT. Re-run; if this repeats,\n" ++
            "the shard set or the storage is at fault.\n", .{k3.expert_drops}) catch {};
        return 4;
    }
    return 0;
}

pub fn main() u8 {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    var tracker = TrackingAllocator{ .parent = gpa_state.allocator() };
    var arena_state = std.heap.ArenaAllocator.init(tracker.allocator());
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const argv = std.process.argsAlloc(alloc) catch {
        std.io.getStdErr().writer().writeAll("OOM reading argv\n") catch {};
        return 2;
    };
    var argv_slices = alloc.alloc([]const u8, argv.len) catch return 2;
    for (argv, 0..) |a, j| argv_slices[j] = a;
    return run(alloc, argv_slices, std.io.getStdOut().writer().any(), std.io.getStdErr().writer().any());
}

// ------------------------------------------------------------------ tests ----

const testing = std.testing;

test "atoiC follows atoi(3): whitespace, sign, prefix digits, junk stops" {
    try testing.expectEqual(@as(i32, 0), atoiC("abc"));
    try testing.expectEqual(@as(i32, 0), atoiC(""));
    try testing.expectEqual(@as(i32, 12), atoiC("12"));
    try testing.expectEqual(@as(i32, -12), atoiC("-12"));
    try testing.expectEqual(@as(i32, 12), atoiC("  +12tail"));
    try testing.expectEqual(@as(i32, 7), atoiC("7x"));
    try testing.expectEqual(@as(i32, 0), atoiC("-x"));
}

test "atofC follows atof(3): longest valid prefix, 0 on no conversion" {
    try testing.expectEqual(@as(f64, 0), atofC("abc"));
    try testing.expectEqual(@as(f64, 2.5), atofC("2.5"));
    try testing.expectEqual(@as(f64, -1.25), atofC(" -1.25junk"));
    try testing.expectEqual(@as(f64, 1e3), atofC("1e3"));
    try testing.expectEqual(@as(f64, 1.5), atofC("1.5e")); // dangling exponent ignored
    try testing.expectEqual(@as(f64, 12.0), atofC("12."));
}

test "specDraft: single-occurrence suffix chains to the cap" {
    // tail {7,11,5,9} previously occurred at j=1; with only ONE occurrence the
    // draft is everything that followed it there, up to the cap.
    const seq = [_]i32{ 3, 7, 11, 5, 9, 3, 7, 11, 5, 9 };
    var out: [8]i32 = undefined;
    const n = specDraft(&seq, 4, &out);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(i32, &.{ 3, 7, 11, 5 }, out[0..n]);
    // wider cap extends the chain to the end of the evidence
    const n5 = specDraft(&seq, 8, &out);
    try testing.expectEqual(@as(usize, 5), n5);
    try testing.expectEqualSlices(i32, &.{ 3, 7, 11, 5, 9 }, out[0..n5]);
}

test "specDraft: histories diverging at the first continuation draft nothing" {
    // tail {1,2,3} occurs at j=1 (followed by 9) and j=7 (followed by 5);
    // first candidates disagree -> zero-length draft for n=3, no n=4 match.
    const seq = [_]i32{ 7, 1, 2, 3, 9, 8, 1, 2, 3, 5, 6, 1, 2, 3 };
    var out: [8]i32 = undefined;
    try testing.expectEqual(@as(usize, 0), specDraft(&seq, 4, &out));
}

test "specDraft: histories agreeing then diverging yield a partial draft" {
    // tail {1,2,3} at j=7 followed by {6,8}, at j=1 followed by {6,9}:
    // they agree once (6) then diverge -> draft {6}.
    const seq = [_]i32{ 0, 1, 2, 3, 6, 9, 0, 1, 2, 3, 6, 8, 1, 2, 3 };
    var out: [8]i32 = undefined;
    const n = specDraft(&seq, 4, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(i32, 6), out[0]);
}

test "specDraft: no history means no draft" {
    const seq = [_]i32{ 8, 4, 2, 1, 16, 32 };
    var out: [8]i32 = undefined;
    try testing.expectEqual(@as(usize, 0), specDraft(&seq, 4, &out));
}

test "jsonString escapes control chars and quotes, null when absent" {
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    jsonString(fbs.writer().any(), "a\"b\\c\nd\x01");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", fbs.getWritten());
    fbs.reset();
    jsonString(fbs.writer().any(), null);
    try testing.expectEqualStrings("null", fbs.getWritten());
}

test "TrackingAllocator enforces the byte limit and records the denial" {
    var ta = TrackingAllocator{ .parent = testing.allocator, .limit = 64 };
    const a = ta.allocator();
    const p = try a.alloc(u8, 40);
    try testing.expectEqual(@as(usize, 40), ta.live);
    try testing.expectError(error.OutOfMemory, a.alloc(u8, 40));
    try testing.expectEqual(@as(u64, 1), ta.denied);
    try testing.expectEqual(@as(usize, 40), ta.peak); // the denied alloc did not move peak
    try testing.expectEqual(@as(usize, 40), ta.live);
    a.free(p);
    try testing.expectEqual(@as(usize, 0), ta.live);
}

test "StateHdr serializes the native q128 payload verbatim" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    var pbuf: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/st.bin", .{try tmp.dir.realpath(".", &pbuf)});
    var c = k3.K3Cfg{ .hidden = 8, .n_layers = 2, .vocab = 16, .kda_heads = 1, .kda_head_dim = 2, .conv_k = 4, .n_heads = 1, .qk_nope = 2, .qk_rope = 1, .v_head = 2, .n_experts = 4, .topk = 2 };
    const seq = [_]i32{ 3, 7, 11 };
    var ks_arr = [_]Q{ f32q(0x3f800000), f32q(0x40000000), f32q(0x40400000) };
    var kvc_arr = [_]Q{ f32q(0x3f000000), f32q(0x3f400000), f32q(0x3f800000), f32q(0x3fa00000), f32q(0x3fc00000), f32q(0x3fe00000) };
    var rp_arr = [_]Q{ f32q(0x40000000), f32q(0x40100000) };
    var erbuf: [256]u8 = undefined;
    var erfbs = std.io.fixedBufferStream(&erbuf);
    const erw = erfbs.writer().any();
    // n_bound=1, n_mla=1, kv_cap=2, cached=2, kper=3, kvpp=3, ropepp=1
    try testing.expectEqual(@as(i32, 0), stateSave(path, &c, &seq, &ks_arr, &kvc_arr, &rp_arr, 1, 1, 2, 2, 3, 3, 1, erw));
    var hd: StateHdr = undefined;
    try testing.expectEqual(@as(i32, 0), statePeek(path, &hd, erw));
    try testing.expectEqual(@as(i32, STATE_VER), hd.version);
    try testing.expectEqual(@as(i64, 3), hd.kper);
    var ks2 = [_]Q{ zero, zero, zero };
    var kvc2 = [_]Q{zero} ** 6;
    var rp2 = [_]Q{zero} ** 2;
    var seq2: [3]i32 = undefined;
    try testing.expectEqual(@as(i32, 0), stateLoad(path, &c, &hd, &seq2, &ks2, &kvc2, &rp2, 1, 1, 2, erw));
    try testing.expectEqualSlices(i32, &seq, &seq2);
    try testing.expectEqualSlices(Q, &ks_arr, &ks2);
    try testing.expectEqualSlices(Q, &kvc_arr, &kvc2);
    try testing.expectEqualSlices(Q, &rp_arr, &rp2);
    // fp mismatch refuses
    c.vocab = 17;
    erfbs.reset();
    try testing.expectEqual(@as(i32, -1), stateLoad(path, &c, &hd, &seq2, &ks2, &kvc2, &rp2, 1, 1, 2, erw));
    try testing.expect(std.mem.indexOf(u8, erfbs.getWritten(), "REFUSING") != null);
}

test "preset table is trunk-first and ordered" {
    try testing.expectEqual(@as(usize, 6), PRESETS.len);
    try testing.expect(PRESETS[0].ultra);
    for (PRESETS[1..]) |*p| try testing.expect(!p.ultra);
    try testing.expect(presetFind("server").?.cache_gb == 13.0);
    try testing.expect(presetFind("auto") == null); // auto is computed, not tabulated
}
