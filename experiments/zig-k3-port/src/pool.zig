//! pool.zig — persistent worker pool for deterministic parallel-for work.
//!
//! Ported from Digit's src/worker_pool.zig: workers spawn once at create and
//! sleep on a condition variable; each `run` publishes a job (context + fn +
//! item count) under a new epoch, and workers plus the submitting thread all
//! drain items through a shared atomic index. The index→item mapping is fixed
//! regardless of scheduling, so results are deterministic by construction —
//! K3's call sites map item i to disjoint row ranges / cache work items that
//! write disjoint slots.
//!
//! One correctness fix vs the donor: Digit's pool lets a straggler worker's
//! `next_index.fetchAdd` land after the next epoch's reset, running a stale
//! context pointer on the new epoch's items. Here `run` waits until every
//! drainer has left the drain loop (not just until items are consumed) before
//! returning, so `next_index` is never reset while an old-epoch fetchAdd can
//! still happen. `run` calls are also serialized by `run_mutex`.
//! Digit's follow-up backport: workers register in `drainers` under `mutex`
//! before unlocking, closing the residual latch-job → unlock → register
//! window where `run` could observe `drainers == 0` too early.
//!
//! Single-threaded targets (wasm): no workers are spawned and `run` degrades
//! to a serial loop — identical bytes, just sequential.

const std = @import("std");
const builtin = @import("builtin");

pub const supports_threads = !builtin.single_threaded;

/// Hard cap on workers — matches ops.zig's MAX_PAR_THREADS fan-out cap so the
/// pool never limits a caller that already partitioned for 32 lanes.
pub const MAX_WORKERS: usize = 32;

pub const RunFn = *const fn (context: *anyopaque, index: usize) void;

const Job = struct {
    context: *anyopaque,
    run_fn: RunFn,
    count: usize,
    epoch: u64,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    threads: [MAX_WORKERS]?std.Thread = .{null} ** MAX_WORKERS,
    worker_count: usize = 0,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: std.Thread.Condition = .{},
    run_mutex: std.Thread.Mutex = .{},
    job: ?Job = null,
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    remaining: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    drainers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    epoch: u64 = 0,
    shutdown: bool = false,

    /// Spawns min(worker_count, MAX_WORKERS) threads that live until destroy.
    /// The pool is a pointer so worker contexts reference it stably. On
    /// single-threaded targets no threads are spawned and run() is serial.
    pub fn create(allocator: std.mem.Allocator, worker_count: usize) !*Pool {
        const self = try allocator.create(Pool);
        self.* = .{ .allocator = allocator };
        errdefer allocator.destroy(self);
        if (comptime supports_threads) {
            const count = @min(worker_count, MAX_WORKERS);
            var spawned: usize = 0;
            errdefer {
                self.mutex.lock();
                self.shutdown = true;
                self.cond.broadcast();
                self.mutex.unlock();
                for (self.threads[0..spawned]) |thread| if (thread) |value| value.join();
            }
            for (0..count) |index| {
                self.threads[index] = std.Thread.spawn(.{}, workerMain, .{self}) catch null;
                if (self.threads[index] != null) spawned += 1;
            }
            self.worker_count = spawned;
        }
        return self;
    }

    pub fn destroy(self: *Pool) void {
        if (comptime supports_threads) {
            self.mutex.lock();
            self.shutdown = true;
            self.cond.broadcast();
            self.mutex.unlock();
            for (self.threads) |thread| if (thread) |value| value.join();
        }
        self.allocator.destroy(self);
    }

    fn workerMain(self: *Pool) void {
        var seen_epoch: u64 = 0;
        self.mutex.lock();
        while (true) {
            while (!self.shutdown and (self.job == null or self.job.?.epoch == seen_epoch)) {
                self.cond.wait(&self.mutex);
            }
            if (self.shutdown) {
                self.mutex.unlock();
                return;
            }
            const job = self.job.?;
            seen_epoch = job.epoch;
            // Digit follow-up fix: register as a drainer while still holding
            // the mutex. Between the unlock and drain()'s fetchAdd the worker
            // was invisible to run()'s exit check, so a job-latched straggler
            // could still fetchAdd into the next epoch's index space.
            _ = self.drainers.fetchAdd(1, .acq_rel);
            self.mutex.unlock();
            self.drainItems(job);
            self.leaveDrain();
            self.mutex.lock();
        }
    }

    /// Drains job items via the shared atomic index. Called by workers and by
    /// the submitting thread so a pool with zero live workers still completes.
    /// Caller must already be registered in `drainers`.
    fn drainItems(self: *Pool, job: Job) void {
        while (true) {
            const index = self.next_index.fetchAdd(1, .acq_rel);
            if (index >= job.count) break;
            job.run_fn(job.context, index);
            if (self.remaining.fetchSub(1, .acq_rel) == 1) {
                self.mutex.lock();
                self.done.broadcast();
                self.mutex.unlock();
            }
        }
    }

    /// Leaving drain (drainers decrement + broadcast) is what allows the next
    /// epoch's next_index reset to be safe.
    fn leaveDrain(self: *Pool) void {
        _ = self.drainers.fetchSub(1, .acq_rel);
        self.mutex.lock();
        self.done.broadcast();
        self.mutex.unlock();
    }

    /// Runs run_fn(context, index) for every index in 0..count and returns
    /// only after every item has completed AND every drainer has exited —
    /// the condition that makes the next publish safe. Falls back to a
    /// sequential loop when no workers are available or the target has no
    /// threads (single-threaded targets cannot compile Condition.wait).
    pub fn run(self: *Pool, context: *anyopaque, run_fn: RunFn, count: usize) void {
        if (comptime !supports_threads) {
            for (0..count) |index| run_fn(context, index);
            return;
        }
        self.run_mutex.lock();
        defer self.run_mutex.unlock();
        if (self.worker_count == 0 or count <= 1) {
            for (0..count) |index| run_fn(context, index);
            return;
        }
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.epoch += 1;
            self.job = .{ .context = context, .run_fn = run_fn, .count = count, .epoch = self.epoch };
            self.next_index.store(0, .release);
            self.remaining.store(count, .release);
            self.cond.broadcast();
        }
        _ = self.drainers.fetchAdd(1, .acq_rel);
        self.drainItems(self.job.?);
        self.leaveDrain();
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.remaining.load(.acquire) != 0 or self.drainers.load(.acquire) != 0) {
            self.done.wait(&self.mutex);
        }
    }
};

// ------------------------------------------------------------- global pool

/// The process-lifetime pool shared by ops (matmul rows) and cache (expert
/// prefetch). Lazily created on first parallel call; sized to the CPU and
/// overridable with K3_THREADS. Worker threads live until process exit —
/// like the trunk IO thread, they are intentionally never joined on the hot
/// path. Tests that want a clean shutdown call deinitGlobal.
var global_mutex: std.Thread.Mutex = .{};
var global_pool: ?*Pool = null;
var global_attempted: bool = false;

/// Worker count for the global pool: K3_THREADS if set to a positive value,
/// else the CPU count, clamped to MAX_WORKERS.
pub fn defaultWorkers() usize {
    if (std.posix.getenv("K3_THREADS")) |v| {
        const n = std.fmt.parseInt(usize, v, 10) catch 0;
        if (n > 0) return @min(n, MAX_WORKERS);
    }
    const ncpu = std.Thread.getCpuCount() catch 1;
    return @min(ncpu, MAX_WORKERS);
}

/// Returns the shared pool, creating it on first use. Uses page_allocator so
/// the singleton never registers against a caller's (or a test's) allocator;
/// the pool's memory is three allocations total, freed by deinitGlobal.
/// Returns null only if allocation itself fails — callers then run serial.
pub fn global() ?*Pool {
    if (comptime !supports_threads) return null;
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_pool) |p| return p;
    if (global_attempted) return null;
    global_attempted = true;
    global_pool = Pool.create(std.heap.page_allocator, defaultWorkers()) catch null;
    return global_pool;
}

/// Tears the global pool down (worker join + free). For tests/tools that want
/// a clean process teardown; the engine itself lets it live for the process.
pub fn deinitGlobal() void {
    if (comptime !supports_threads) return;
    global_mutex.lock();
    defer global_mutex.unlock();
    if (global_pool) |p| {
        p.destroy();
        global_pool = null;
    }
}

/// Convenience: run count items through the global pool (serial if absent or
/// on single-threaded targets). This is the shape ops/cache call sites use.
pub fn runItems(context: *anyopaque, run_fn: RunFn, count: usize) void {
    if (comptime !supports_threads) {
        for (0..count) |index| run_fn(context, index);
        return;
    }
    if (global()) |p| {
        p.run(context, run_fn, count);
    } else {
        for (0..count) |index| run_fn(context, index);
    }
}

// ------------------------------------------------------------------ tests

const Ctx = struct {
    counters: []std.atomic.Value(u32),
    values: []u64,
    fn bump(context: *anyopaque, index: usize) void {
        const c: *Ctx = @ptrCast(@alignCast(context));
        _ = c.counters[index].fetchAdd(1, .monotonic);
        c.values[index] = @as(u64, index) *% 2654435761;
    }
};

test "pool runs every item exactly once, deterministically" {
    if (comptime !supports_threads) return;
    var counters: [256]std.atomic.Value(u32) = undefined;
    var values: [256]u64 = undefined;
    for (&counters) |*c| c.* = std.atomic.Value(u32).init(0);
    var ctx = Ctx{ .counters = &counters, .values = &values };

    const pool = try Pool.create(std.testing.allocator, 8);
    defer pool.destroy();

    // Back-to-back epochs: the drain-race fix means a straggler from run N
    // can never fetchAdd into run N+1's index space.
    for (0..8) |_| pool.run(&ctx, Ctx.bump, 256);
    for (counters) |c| try std.testing.expectEqual(@as(u32, 8), c.load(.monotonic));
    for (values, 0..) |v, i| try std.testing.expectEqual(@as(u64, i) *% 2654435761, v);
}

test "pool serial fallback for zero workers and count<=1" {
    var counters: [4]std.atomic.Value(u32) = undefined;
    var values: [4]u64 = undefined;
    for (&counters) |*c| c.* = std.atomic.Value(u32).init(0);
    var ctx = Ctx{ .counters = &counters, .values = &values };

    const pool = try Pool.create(std.testing.allocator, 0);
    defer pool.destroy();
    pool.run(&ctx, Ctx.bump, 4);
    for (counters) |c| try std.testing.expectEqual(@as(u32, 1), c.load(.monotonic));
}

test "runItems works without a global pool init" {
    var counters: [16]std.atomic.Value(u32) = undefined;
    var values: [16]u64 = undefined;
    for (&counters) |*c| c.* = std.atomic.Value(u32).init(0);
    var ctx = Ctx{ .counters = &counters, .values = &values };
    runItems(&ctx, Ctx.bump, 16);
    for (counters) |c| try std.testing.expectEqual(@as(u32, 1), c.load(.monotonic));
    deinitGlobal();
}
