//! sybil.zig — Sybil resistance via proof-of-lattice-work (PoLW).
//!
//! Prevents identity spam by requiring peers to solve a lattice-based challenge
//! that is expensive to compute but cheap to verify. Uses the E0 node hash
//! and octonion routing as the proof function.
//!
//! Zero external dependencies beyond std.

const std = @import("std");

// =============================================================================
// Constants
// =============================================================================

pub const E0_NODE_COUNT: usize = 421;
pub const BASE_EDGE: u32 = 15;

/// Number of leading zero bits required in the proof hash.
pub const DEFAULT_DIFFICULTY: u8 = 12;

/// Maximum nonce before giving up.
pub const MAX_NONCE: u64 = 10_000_000;

/// Number of challenge bytes.
pub const CHALLENGE_SIZE: usize = 32;

// =============================================================================
// Challenge — a lattice-based challenge for PoLW
// =============================================================================

pub const Challenge = struct {
    /// Random challenge bytes (from block hash or peer's public key).
    seed: [CHALLENGE_SIZE]u8,
    /// Required difficulty (leading zero bits).
    difficulty: u8,
    /// Timestamp when challenge was issued.
    issued_ms: u64,

    pub inline fn init(seed: [CHALLENGE_SIZE]u8, difficulty: u8, issued_ms: u64) Challenge {
        return .{
            .seed = seed,
            .difficulty = difficulty,
            .issued_ms = issued_ms,
        };
    }

    /// Generate a random challenge.
    pub fn random(rng: *std.Random.DefaultPrng, difficulty: u8, now_ms: u64) Challenge {
        var seed: [CHALLENGE_SIZE]u8 = undefined;
        rng.random().bytes(&seed);
        return .{
            .seed = seed,
            .difficulty = difficulty,
            .issued_ms = now_ms,
        };
    }
};

// =============================================================================
// Proof — a solution to a lattice challenge
// =============================================================================

pub const Proof = struct {
    /// Nonce that produces a valid hash.
    nonce: u64,
    /// The resulting hash satisfying the difficulty.
    hash: [32]u8,
    /// Number of iterations used to find the proof.
    iterations: u64,

    pub inline fn init(nonce: u64, hash: [32]u8, iterations: u64) Proof {
        return .{
            .nonce = nonce,
            .hash = hash,
            .iterations = iterations,
        };
    }
};

// =============================================================================
// PoLW — proof-of-lattice-work computation and verification
// =============================================================================

/// Computes the lattice hash for a given challenge seed and nonce.
/// Uses E0 node placement + octonion routing to create a lattice-specific hash.
pub fn latticeHash(challenge: [CHALLENGE_SIZE]u8, nonce: u64) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    // Hash the challenge seed
    hasher.update(&challenge);

    // Hash the nonce
    var nonce_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &nonce_bytes, nonce, .little);
    hasher.update(&nonce_bytes);

    // Lattice-specific mixing: simulate E0 node placement
    var x: u32 = 0;
    while (x < 15) : (x += 3) {
        var y: u32 = 0;
        while (y < 15) : (y += 3) {
            const z: u32 = (x + y) % 15;
            if ((x + y + z) % 3 != 0) continue;

            // E0 node index
            const idx = (x *% 7 + y *% 11 + z *% 13) % 421;

            // Octonion e-value
            const dx = @min(x, 14 - x);
            const dy = @min(y, 14 - y);
            const dz = if (z >= 7) z - 7 else 7 - z;
            const e_val: u8 = @intCast(@mod(@as(i64, 6) + @as(i64, dz) - @as(i64, dx) - @as(i64, dy), 8));

            // Mix into hash
            hasher.update(std.mem.asBytes(&idx));
            hasher.update(std.mem.asBytes(&e_val));
        }
    }

    // Final nonce mixing
    hasher.update(&nonce_bytes);

    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

/// Counts the number of leading zero bits in a 32-byte hash.
pub inline fn leadingZeroBits(hash: [32]u8) u16 {
    var count: u16 = 0;
    for (hash) |byte| {
        if (byte == 0) {
            count += 8;
        } else {
            var b = byte;
            while ((b & 0x80) == 0) {
                count += 1;
                b <<= 1;
            }
            break;
        }
    }
    return count;
}

/// Checks if a hash meets the required difficulty.
pub inline fn meetsDifficulty(hash: [32]u8, difficulty: u16) bool {
    return leadingZeroBits(hash) >= difficulty;
}

/// Solves a lattice challenge by finding a nonce that produces a valid hash.
pub fn solveChallenge(challenge: Challenge) ?Proof {
    var nonce: u64 = 0;
    while (nonce < MAX_NONCE) : (nonce += 1) {
        const hash = latticeHash(challenge.seed, nonce);
        if (meetsDifficulty(hash, challenge.difficulty)) {
            return Proof.init(nonce, hash, nonce + 1);
        }
    }
    return null;
}

/// Verifies a proof against a challenge.
pub fn verifyProof(challenge: Challenge, proof: Proof) bool {
    const hash = latticeHash(challenge.seed, proof.nonce);
    if (!std.mem.eql(u8, &hash, &proof.hash)) return false;
    return meetsDifficulty(hash, challenge.difficulty);
}

// =============================================================================
// PeerIdentity — a peer's identity with associated proof
// =============================================================================

pub const PeerIdentity = struct {
    /// Peer's public key hash (32 bytes).
    pubkey_hash: [32]u8,
    /// Lattice location (from mesh.zig Location).
    location: u64,
    /// Proof of work for this identity.
    proof: Proof,
    /// When the identity was registered.
    registered_ms: u64,
    /// Challenge used for the proof.
    challenge_seed: [CHALLENGE_SIZE]u8,

    pub fn init(
        pubkey_hash: [32]u8,
        location: u64,
        proof: Proof,
        registered_ms: u64,
        challenge_seed: [CHALLENGE_SIZE]u8,
    ) PeerIdentity {
        return .{
            .pubkey_hash = pubkey_hash,
            .location = location,
            .proof = proof,
            .registered_ms = registered_ms,
            .challenge_seed = challenge_seed,
        };
    }

    pub fn verify(self: PeerIdentity, difficulty: u8) bool {
        const challenge = Challenge.init(self.challenge_seed, difficulty, self.registered_ms);
        return verifyProof(challenge, self.proof);
    }
};

// =============================================================================
// IdentityRegistry — tracks peer identities and prevents Sybil attacks
// =============================================================================

pub const IdentityRegistry = struct {
    allocator: std.mem.Allocator,
    /// Map from pubkey hash to peer identity.
    identities: std.AutoHashMap([32]u8, PeerIdentity),
    /// Map from location to pubkey hash (one identity per location).
    location_to_pubkey: std.AutoHashMap(u64, [32]u8),
    /// Required difficulty for new registrations.
    difficulty: u8,
    /// Minimum time between registrations from the same IP (ms).
    rate_limit_ms: u64,
    /// Last registration time per IP prefix (simplified).
    last_registration: std.AutoHashMap(u32, u64),

    pub fn init(allocator: std.mem.Allocator, difficulty: u8) IdentityRegistry {
        return .{
            .allocator = allocator,
            .identities = std.AutoHashMap([32]u8, PeerIdentity).init(allocator),
            .location_to_pubkey = std.AutoHashMap(u64, [32]u8).init(allocator),
            .difficulty = difficulty,
            .rate_limit_ms = 60_000,
            .last_registration = std.AutoHashMap(u32, u64).init(allocator),
        };
    }

    pub fn deinit(self: *IdentityRegistry) void {
        self.identities.deinit();
        self.location_to_pubkey.deinit();
        self.last_registration.deinit();
    }

    /// Register a new peer identity. Returns false if rejected.
    pub fn register(
        self: *IdentityRegistry,
        identity: PeerIdentity,
        ip_prefix: u32,
        now_ms: u64,
    ) !bool {
        // Check proof of work
        if (!identity.verify(self.difficulty)) return false;

        // Check if pubkey already registered
        if (self.identities.contains(identity.pubkey_hash)) return false;

        // Check if location already taken
        if (self.location_to_pubkey.contains(identity.location)) return false;

        // Rate limiting: check last registration from this IP
        if (self.last_registration.get(ip_prefix)) |last_ms| {
            if (now_ms - last_ms < self.rate_limit_ms) return false;
        }

        // Register
        try self.identities.put(identity.pubkey_hash, identity);
        try self.location_to_pubkey.put(identity.location, identity.pubkey_hash);
        try self.last_registration.put(ip_prefix, now_ms);
        return true;
    }

    /// Check if an identity is registered.
    pub inline fn isRegistered(self: *const IdentityRegistry, pubkey_hash: [32]u8) bool {
        return self.identities.contains(pubkey_hash);
    }

    /// Get an identity by pubkey hash.
    pub inline fn getIdentity(self: *const IdentityRegistry, pubkey_hash: [32]u8) ?PeerIdentity {
        return self.identities.get(pubkey_hash);
    }

    /// Number of registered identities.
    pub inline fn count(self: *const IdentityRegistry) usize {
        return self.identities.count();
    }

    /// Remove an identity (e.g., for misbehavior).
    pub fn revoke(self: *IdentityRegistry, pubkey_hash: [32]u8) bool {
        if (self.identities.fetchRemove(pubkey_hash)) |kv| {
            _ = self.location_to_pubkey.remove(kv.value.location);
            return true;
        }
        return false;
    }

    /// Check if a location is already claimed.
    pub inline fn isLocationClaimed(self: *const IdentityRegistry, location: u64) bool {
        return self.location_to_pubkey.contains(location);
    }
};

// =============================================================================
// Reputation — tracks peer behavior for additional Sybil defense
// =============================================================================

pub const Reputation = struct {
    /// Positive interactions.
    upvotes: u32 = 0,
    /// Negative interactions.
    downvotes: u32 = 0,
    /// Last interaction time.
    last_interaction_ms: u64 = 0,

    pub inline fn score(self: Reputation) f32 {
        const total = self.upvotes + self.downvotes;
        if (total == 0) return 0.5;
        return @as(f32, @floatFromInt(self.upvotes)) / @as(f32, @floatFromInt(total));
    }

    pub fn upvote(self: *Reputation, now_ms: u64) void {
        self.upvotes += 1;
        self.last_interaction_ms = now_ms;
    }

    pub fn downvote(self: *Reputation, now_ms: u64) void {
        self.downvotes += 1;
        self.last_interaction_ms = now_ms;
    }
};

pub const ReputationTracker = struct {
    allocator: std.mem.Allocator,
    reputations: std.AutoHashMap([32]u8, Reputation),

    pub fn init(allocator: std.mem.Allocator) ReputationTracker {
        return .{
            .allocator = allocator,
            .reputations = std.AutoHashMap([32]u8, Reputation).init(allocator),
        };
    }

    pub fn deinit(self: *ReputationTracker) void {
        self.reputations.deinit();
    }

    pub fn upvote(self: *ReputationTracker, pubkey: [32]u8, now_ms: u64) !void {
        const entry = try self.reputations.getOrPut(pubkey);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.upvote(now_ms);
    }

    pub fn downvote(self: *ReputationTracker, pubkey: [32]u8, now_ms: u64) !void {
        const entry = try self.reputations.getOrPut(pubkey);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.downvote(now_ms);
    }

    pub inline fn getScore(self: *const ReputationTracker, pubkey: [32]u8) f32 {
        if (self.reputations.get(pubkey)) |rep| return rep.score();
        return 0.5;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "sybil: leadingZeroBits" {
    try std.testing.expectEqual(@as(u16, 0), leadingZeroBits([_]u8{0xFF} ** 32));
    try std.testing.expectEqual(@as(u16, 256), leadingZeroBits([_]u8{0x00} ** 32));
    try std.testing.expectEqual(@as(u16, 1), leadingZeroBits([_]u8{0x7F} ++ [_]u8{0xFF} ** 31));
    try std.testing.expectEqual(@as(u16, 4), leadingZeroBits([_]u8{0x0F} ++ [_]u8{0xFF} ** 31));
}

test "sybil: latticeHash is deterministic" {
    const challenge = [_]u8{0x42} ** 32;
    const h1 = latticeHash(challenge, 12345);
    const h2 = latticeHash(challenge, 12345);
    try std.testing.expectEqualSlices(u8, &h1, &h2);
}

test "sybil: latticeHash changes with nonce" {
    const challenge = [_]u8{0x42} ** 32;
    const h1 = latticeHash(challenge, 1);
    const h2 = latticeHash(challenge, 2);
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "sybil: solveChallenge with low difficulty" {
    var rng = std.Random.DefaultPrng.init(42);
    const challenge = Challenge.random(&rng, 4, 1000);
    const proof = solveChallenge(challenge);
    try std.testing.expect(proof != null);
    try std.testing.expect(verifyProof(challenge, proof.?));
}

test "sybil: verifyProof rejects wrong nonce" {
    var rng = std.Random.DefaultPrng.init(42);
    const challenge = Challenge.random(&rng, 4, 1000);
    const proof = solveChallenge(challenge).?;
    try std.testing.expect(verifyProof(challenge, proof));

    // Wrong nonce should fail
    const fake_proof = Proof.init(proof.nonce + 1, proof.hash, proof.iterations);
    try std.testing.expect(!verifyProof(challenge, fake_proof));
}

test "sybil: verifyProof rejects wrong hash" {
    var rng = std.Random.DefaultPrng.init(42);
    const challenge = Challenge.random(&rng, 4, 1000);
    const proof = solveChallenge(challenge).?;

    var bad_hash = proof.hash;
    bad_hash[0] ^= 0xFF;
    const fake_proof = Proof.init(proof.nonce, bad_hash, proof.iterations);
    try std.testing.expect(!verifyProof(challenge, fake_proof));
}

test "sybil: identity registry accepts valid proof" {
    const allocator = std.testing.allocator;
    var registry = IdentityRegistry.init(allocator, 4);
    defer registry.deinit();

    var rng = std.Random.DefaultPrng.init(42);
    const challenge = Challenge.random(&rng, 4, 1000);
    const proof = solveChallenge(challenge).?;

    var pubkey: [32]u8 = undefined;
    rng.random().bytes(&pubkey);

    const identity = PeerIdentity.init(pubkey, 12345, proof, 1000, challenge.seed);
    const registered = try registry.register(identity, 0xC0A80100, 1000);
    try std.testing.expect(registered);
    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "sybil: registry rejects duplicate pubkey" {
    const allocator = std.testing.allocator;
    var registry = IdentityRegistry.init(allocator, 4);
    defer registry.deinit();

    var rng = std.Random.DefaultPrng.init(42);
    const challenge = Challenge.random(&rng, 4, 1000);
    const proof = solveChallenge(challenge).?;

    var pubkey: [32]u8 = undefined;
    rng.random().bytes(&pubkey);

    const identity = PeerIdentity.init(pubkey, 12345, proof, 1000, challenge.seed);
    _ = try registry.register(identity, 0xC0A80100, 1000);

    // Same pubkey, different location — should fail
    const identity2 = PeerIdentity.init(pubkey, 54321, proof, 1000, challenge.seed);
    const registered = try registry.register(identity2, 0xC0A80100, 2000);
    try std.testing.expect(!registered);
}

test "sybil: registry rejects duplicate location" {
    const allocator = std.testing.allocator;
    var registry = IdentityRegistry.init(allocator, 4);
    defer registry.deinit();

    var rng = std.Random.DefaultPrng.init(42);

    // First identity
    const challenge1 = Challenge.random(&rng, 4, 1000);
    const proof1 = solveChallenge(challenge1).?;
    var pubkey1: [32]u8 = undefined;
    rng.random().bytes(&pubkey1);
    const identity1 = PeerIdentity.init(pubkey1, 99999, proof1, 1000, challenge1.seed);
    _ = try registry.register(identity1, 0xC0A80100, 1000);

    // Second identity with same location
    const challenge2 = Challenge.random(&rng, 4, 1000);
    const proof2 = solveChallenge(challenge2).?;
    var pubkey2: [32]u8 = undefined;
    rng.random().bytes(&pubkey2);
    const identity2 = PeerIdentity.init(pubkey2, 99999, proof2, 2000, challenge2.seed);
    const registered = try registry.register(identity2, 0xC0A80101, 2000);
    try std.testing.expect(!registered);
}

test "sybil: registry rate limiting" {
    const allocator = std.testing.allocator;
    var registry = IdentityRegistry.init(allocator, 4);
    defer registry.deinit();

    var rng = std.Random.DefaultPrng.init(42);

    // First registration from IP
    const challenge1 = Challenge.random(&rng, 4, 1000);
    const proof1 = solveChallenge(challenge1).?;
    var pubkey1: [32]u8 = undefined;
    rng.random().bytes(&pubkey1);
    const identity1 = PeerIdentity.init(pubkey1, 11111, proof1, 1000, challenge1.seed);
    _ = try registry.register(identity1, 0xC0A80100, 1000);

    // Second registration from same IP too soon — should fail
    const challenge2 = Challenge.random(&rng, 4, 1000);
    const proof2 = solveChallenge(challenge2).?;
    var pubkey2: [32]u8 = undefined;
    rng.random().bytes(&pubkey2);
    const identity2 = PeerIdentity.init(pubkey2, 22222, proof2, 5000, challenge2.seed);
    const registered = try registry.register(identity2, 0xC0A80100, 5000);
    try std.testing.expect(!registered);

    // After rate limit window — should succeed
    const registered2 = try registry.register(identity2, 0xC0A80100, 61000);
    try std.testing.expect(registered2);
}

test "sybil: registry rejects invalid proof" {
    const allocator = std.testing.allocator;
    var registry = IdentityRegistry.init(allocator, 8);
    defer registry.deinit();

    // Create a proof with insufficient difficulty
    const fake_hash = [_]u8{0xFF} ** 32;
    const fake_proof = Proof.init(0, fake_hash, 1);

    var pubkey: [32]u8 = undefined;
    @memset(&pubkey, 0xAA);

    const identity = PeerIdentity.init(pubkey, 12345, fake_proof, 1000, [_]u8{0} ** 32);
    const registered = try registry.register(identity, 0xC0A80100, 1000);
    try std.testing.expect(!registered);
}

test "sybil: registry revoke" {
    const allocator = std.testing.allocator;
    var registry = IdentityRegistry.init(allocator, 4);
    defer registry.deinit();

    var rng = std.Random.DefaultPrng.init(42);
    const challenge = Challenge.random(&rng, 4, 1000);
    const proof = solveChallenge(challenge).?;

    var pubkey: [32]u8 = undefined;
    rng.random().bytes(&pubkey);

    const identity = PeerIdentity.init(pubkey, 12345, proof, 1000, challenge.seed);
    _ = try registry.register(identity, 0xC0A80100, 1000);
    try std.testing.expectEqual(@as(usize, 1), registry.count());

    try std.testing.expect(registry.revoke(pubkey));
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expect(!registry.isRegistered(pubkey));
}

test "sybil: reputation score" {
    var rep = Reputation{};
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rep.score(), 1e-6);

    rep.upvote(1000);
    rep.upvote(2000);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), rep.score(), 1e-6);

    rep.downvote(3000);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), rep.score(), 1e-6);
}

test "sybil: reputation tracker" {
    const allocator = std.testing.allocator;
    var tracker = ReputationTracker.init(allocator);
    defer tracker.deinit();

    var pubkey: [32]u8 = undefined;
    @memset(&pubkey, 0xBB);

    try tracker.upvote(pubkey, 1000);
    try tracker.upvote(pubkey, 2000);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), tracker.getScore(pubkey), 1e-6);

    try tracker.downvote(pubkey, 3000);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), tracker.getScore(pubkey), 1e-6);
}
