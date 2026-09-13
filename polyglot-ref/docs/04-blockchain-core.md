# 04 — Blockchain Core (`blockchain/`)

## Architecture Overview

### Purpose

The blockchain module implements a decentralized, zero-drift sovereign ledger built on the Q128.128 fixed-point arithmetic stack. It eliminates IEEE 754 floating-point consensus forks across heterogeneous hardware by using deterministic 256-bit signed fixed-point math for all balance transitions, transaction signing, and block validation.

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `account.zig` | 276 | `AccountState`: Q128.128 balance, credit/debit, transfer, address generation |
| `transaction.zig` | 279 | `Transaction`: serialization, ed25519 signing/verification, Blake2b-256 hashing |
| `block.zig` | 307 | `Block`/`BlockHeader`: Merkle tree, defect charge, PoW validation |
| `ledger.zig` | 383 | `Ledger`: canonical chain, account store, genesis, block validation/application |
| `consensus.zig` | 281 | `PhaseVector`: chain phase computation, canonical chain selection, double-spend resolution |
| `build.zig` | 65 | Build system: test targets |

### Dependencies

- **Internal**: `q128_128` module (from `../zig/q128_128.zig`)
- **External**: None (uses Zig stdlib crypto: `std.crypto.sign.Ed25519`, `std.crypto.hash.blake2.Blake2b256`)

### Architecture Diagram

```
Transaction (signed) → Block (Merkle root + defect charge) → Ledger (validate + apply)
                                                              ↓
                                                    Consensus (phase vector)
                                                              ↓
                                                    Canonical chain selection
```

### Key Design Principles

1. **Zero-drift balances**: All account balances stored as Q128.128 (`balance_int: i128`, `balance_frac: u128`). No floating-point operations in any balance computation.
2. **Deterministic consensus**: Phase-lock settlement via topological defect charges. Double-spends resolved by e9 boundary absorbing phase variance — no centralized coordination.
3. **Ed25519 signatures**: Transaction signing uses `std.crypto.sign.Ed25519` for 128-bit security.
4. **Blake2b-256 hashing**: Block and transaction hashing uses `std.crypto.hash.blake2.Blake2b256`.
5. **Merkle tree**: Binary Merkle tree over transaction hashes for tamper-evident block contents.

---

## API Reference

### `account.zig`

#### Types

```zig
pub const Address = [32]u8;  // Ed25519 public key

pub const AccountState = struct {
    balance_int: i128,     // Integer part of Q128.128 balance
    balance_frac: u128,    // Fractional part of Q128.128 balance
    nonce: u64,            // Transaction counter (replay protection)
    address: Address,      // Account public key
};
```

#### Key Functions

```zig
pub fn init(address: Address) AccountState
pub fn credit(acc: *AccountState, amount_int: i128, amount_frac: u128) void
pub fn debit(acc: *AccountState, amount_int: i128, amount_frac: u128) !void
pub fn getBalance(acc: *const AccountState) struct { int: i128, frac: u128 }
pub fn compareBalance(acc: *const AccountState, other_int: i128, other_frac: u128) i32
pub fn transfer(from: *AccountState, to: *AccountState, amount_int: i128, amount_frac: u128) !void
pub fn generateAddress() Address
pub fn addressToHex(addr: Address) [64]u8
pub fn hexToAddress(hex: []const u8) !Address
```

#### Balance Operations

- **credit**: Adds amount to balance. Handles fractional overflow (carry to integer part).
- **debit**: Subtracts amount from balance. Returns error if insufficient funds. Handles fractional borrow.
- **transfer**: Atomic debit from `from` + credit to `to`. Returns error if insufficient balance.
- **compareBalance**: Returns -1/0/1 comparing account balance to given amount.

#### Test Coverage

| Test | Description |
|------|-------------|
| `init` | New account has zero balance, nonce 0 |
| `credit` | Balance increases correctly, fractional carry |
| `debit` | Balance decreases correctly, fractional borrow |
| `debit insufficient` | Error on overdraft |
| `transfer` | Atomic transfer between accounts |
| `transfer insufficient` | Error on insufficient funds |
| `nonce increment` | Nonce increments after operations |
| `address round-trip` | Address → hex → address |
| `large balance` | Q128.128 large number handling |
| `fractional precision` | Sub-cent precision preserved |

---

### `transaction.zig`

#### Types

```zig
pub const TxType = enum {
    transfer,
    stake,
    unstake,
    reward,
    slash,
    contract_call,
};

pub const Transaction = struct {
    tx_type: TxType,
    from: Address,
    to: Address,
    amount_int: i128,
    amount_frac: u128,
    nonce: u64,
    data: []const u8,        // Optional payload (contract call data)
    signature: [64]u8,       // Ed25519 signature
    timestamp: u64,
};
```

#### Key Functions

```zig
pub fn createTransfer(from: Address, to: Address, amount_int: i128, amount_frac: u128, nonce: u64) Transaction
pub fn sign(tx: *Transaction, secret_key: [64]u8) void
pub fn verify(tx: *const Transaction) bool
pub fn hash(tx: *const Transaction) [32]u8  // Blake2b-256
pub fn serialize(alloc: Allocator, tx: *const Transaction) ![]u8
pub fn deserialize(alloc: Allocator, data: []const u8) !Transaction
pub fn validate(tx: *const Transaction) bool  // Basic field validation
```

#### Signing Flow

1. **createTransfer**: Initialize unsigned transaction with fields
2. **sign**: Compute Blake2b-256 hash of serialized transaction (excluding signature field), sign with Ed25519 private key
3. **verify**: Recompute hash, verify Ed25519 signature against `from` public key
4. **hash**: Blake2b-256 of full serialized transaction (including signature) for Merkle tree

#### Serialization Format

```
Offset  Size    Field
0       1       TxType (u8)
1       32      From address
33      32      To address
65      16      Amount integer (i128)
81      16      Amount fractional (u128)
97      8       Nonce (u64)
105     8       Timestamp (u64)
113     4       Data length (u32)
117     ...     Data bytes
...     64      Signature
```

#### Test Coverage

| Test | Description |
|------|-------------|
| `create + sign + verify` | Full signing flow |
| `verify invalid signature` | Tampered transaction rejected |
| `serialize/deserialize` | Round-trip serialization |
| `validate` | Field validation (non-negative amounts, valid addresses) |
| `hash determinism` | Same transaction → same hash |
| `hash sensitivity` | 1-bit change → different hash |
| `nonce ordering` | Nonce prevents replay |

---

### `block.zig`

#### Types

```zig
pub const BlockHeader = struct {
    version: u32,
    prev_hash: [32]u8,      // Blake2b-256 of previous block
    merkle_root: [32]u8,    // Merkle root of transactions
    timestamp: u64,
    height: u64,
    difficulty: u64,
    nonce: u64,             // PoW nonce
    defect_charge: i128,   // Topological phase variance
    state_root: [32]u8,    // Root hash of account state tree
};

pub const Block = struct {
    header: BlockHeader,
    transactions: []Transaction,
};

pub const AccountEntry = struct {
    address: Address,
    balance_int: i128,
    balance_frac: u128,
    nonce: u64,
};
```

#### Key Functions

```zig
pub fn computeMerkleRoot(alloc: Allocator, txs: []const Transaction) ![32]u8
pub fn hashBlock(hdr: *const BlockHeader) [32]u8  // Blake2b-256
pub fn validatePoW(hdr: *const BlockHeader) bool
pub fn computeDefectCharge(alloc: Allocator, txs: []const Transaction) i128
pub fn computeStateRoot(alloc: Allocator, accounts: []const AccountEntry) ![32]u8
```

#### Merkle Tree

Binary Merkle tree over transaction hashes:
1. Hash each transaction with `transaction.hash()` → leaf nodes
2. Pairwise concatenate and hash → internal nodes
3. If odd number of nodes, duplicate last node
4. Repeat until single root
5. Root stored in `BlockHeader.merkle_root`

#### Defect Charge

Topological phase variance computed from transaction set:
1. For each transaction, compute a phase value from amount + nonce + type
2. Sum phase values as Q128.128 fixed-point
3. Result is `defect_charge: i128` — represents topological winding number
4. Non-zero defect charge locks phase angle of inner core, preventing drift
5. Used by consensus for double-spend resolution

#### Test Coverage

| Test | Description |
|------|-------------|
| `Merkle root` | Correct root for known transactions |
| `Merkle tamper detection` | Modified tx → different root |
| `block hash` | Deterministic block hashing |
| `PoW validation` | Valid/invalid difficulty |
| `defect charge` | Correct charge for transaction set |
| `state root` | Correct root for account set |
| `empty block` | Zero transactions handled |

---

### `ledger.zig`

#### Types

```zig
pub const AccountStore = struct {
    accounts: std.AutoHashMap(Address, AccountState),
    alloc: Allocator,
};

pub const Ledger = struct {
    chain: std.ArrayList(Block),
    accounts: AccountStore,
    alloc: Allocator,
    genesis_hash: [32]u8,
};
```

#### Key Functions

```zig
pub fn init(alloc: Allocator, genesis_alloc: Address, genesis_amount_int: i128, genesis_amount_frac: u128) !Ledger
pub fn addBlock(ledger: *Ledger, block: Block) !void
pub fn validateBlock(ledger: *const Ledger, block: *const Block) !bool
pub fn applyTransactions(ledger: *Ledger, txs: []const Transaction) !void
pub fn getBalance(ledger: *const Ledger, addr: Address) ?struct { int: i128, frac: u128 }
pub fn getAccount(ledger: *const Ledger, addr: Address) ?*AccountState
pub fn getHeight(ledger: *const Ledger) u64
pub fn getBlock(ledger: *const Ledger, height: u64) ?*const Block
pub fn getChainHead(ledger: *const Ledger) ?*const Block
```

#### Ledger Lifecycle

1. **init**: Create genesis block with initial allocation to genesis address
2. **validateBlock**: Check:
   - `prev_hash` matches chain head hash
   - `height` = chain height + 1
   - Merkle root matches computed root
   - PoW valid for difficulty
   - All transactions valid (signature, nonce, sufficient balance)
3. **addBlock**: Validate block, then:
   - Apply all transactions to account store
   - Update state root
   - Append block to chain
4. **applyTransactions**: For each transaction:
   - Verify signature
   - Check nonce matches account nonce
   - Check sufficient balance
   - Execute transfer (debit from, credit to)
   - Increment account nonce

#### Test Coverage

| Test | Description |
|------|-------------|
| `genesis` | Correct genesis block creation |
| `add valid block` | Block added, transactions applied |
| `reject invalid prev_hash` | Forked block rejected |
| `reject invalid height` | Wrong height rejected |
| `reject invalid Merkle` | Tampered transactions rejected |
| `reject insufficient balance` | Overspending transaction rejected |
| `nonce replay protection` | Replayed transaction rejected |
| `multi-block chain` | Chain of 3+ blocks, correct state |
| `get balance` | Correct balance after transactions |
| `state root` | State root changes after transactions |

---

### `consensus.zig`

#### Types

```zig
pub const PhaseVector = struct {
    real: q128,      // Real component (Q128.128)
    imaginary: q128,  // Imaginary component (Q128.128)
    magnitude: q128,  // |phase| = sqrt(re² + im²)
    variance: q128,   // Phase variance measure
};

pub const ChainCandidate = struct {
    blocks: []const Block,
    phase: PhaseVector,
    total_defect_charge: i128,
    height: u64,
};
```

#### Key Functions

```zig
pub fn computePhaseVector(alloc: Allocator, blocks: []const Block) PhaseVector
pub fn selectCanonicalChain(chains: []const ChainCandidate) usize  // Returns index
pub fn detectDoubleSpend(alloc: Allocator, chains: []const []const Block) []const usize
pub fn resolveDoubleSpend(alloc: Allocator, chains: []const []const Block) []const Block
pub fn convergeStateRoot(alloc: Allocator, candidates: []const []const AccountEntry) [32]u8
```

#### Phase-Lock Consensus

1. **computePhaseVector**: For each block in chain:
   - Sum defect charges as Q128.128 complex values
   - Real part = sum of charges, imaginary part = sum of phase rotations
   - Magnitude = sqrt(re² + im²) via Q128.128 sqrt
   - Variance = magnitude / chain_length
2. **selectCanonicalChain**: Among competing chains:
   - Lowest phase variance wins (most stable)
   - Tie-break by highest height (longest chain)
   - Tie-break by lowest total defect charge
3. **detectDoubleSpend**: Find transactions spending same UTXO across different chains
4. **resolveDoubleSpend**: Keep transactions from canonical chain, discard from others
5. **convergeStateRoot**: Majority vote across candidate state roots

#### Double-Spend Resolution

When two chains contain conflicting transactions (same nonce, same from-address):
1. Compute phase vector for each chain
2. Chain with lower phase variance is canonical
3. Non-canonical chain's conflicting transaction is rejected
4. The e9 boundary absorbs the phase variance as a topological defect charge
5. No centralized coordination needed — all nodes converge to same canonical chain

#### Test Coverage

| Test | Description |
|------|-------------|
| `phase vector` | Correct computation for known blocks |
| `canonical chain selection` | Lowest variance wins |
| `tie-break by height` | Equal variance → longest chain |
| `double-spend detection` | Conflicting transactions identified |
| `double-spend resolution` | Non-canonical tx rejected |
| `state root convergence` | Majority vote produces correct root |
| `empty chain` | Zero blocks handled |
| `single chain` | No conflict → chain is canonical |

---

## Build Configuration (`build.zig`)

### Test Targets

| Name | Source | Description |
|------|--------|-------------|
| `test-account` | `account.zig` | Balance operations, transfers |
| `test-transaction` | `transaction.zig` | Signing, verification, serialization |
| `test-block` | `block.zig` | Merkle tree, defect charge, PoW |
| `test-ledger` | `ledger.zig` | Chain management, block validation |
| `test-consensus` | `consensus.zig` | Phase vector, chain selection |

### Build Commands

```bash
# Run all blockchain tests
cd blockchain/ && zig build test

# Run specific test
cd blockchain/ && zig build test-ledger
```

---

## Integration Points

- **Q128.128 Core** (`zig/`): Fixed-point arithmetic for all balance computations
- **ISG Transcoder** (`isg/`): Chain history packed into RGB video frames for storage
- **Transport** (`transport/`): Air-gapped transaction submission via polyglots/FSK
- **VFS Interceptor** (`vfs/`): Folded models can include chain state
- **Runtime** (`runtime/`): Hardware-agnostic consensus execution
- **Holo-FS** (`holo-fs/`): Persistent chain storage via FUSE filesystem

**ATMA mapping:** Karma ledger — deterministic state transitions recorded without noise (see docs/16-atma-fano1.md).
