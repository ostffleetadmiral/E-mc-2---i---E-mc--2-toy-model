# 15 — Polyglot Runtime (`zig/poly/`)

## Architecture Overview

### Purpose

The polyglot runtime embeds real language runtimes behind one Zig API so every FANO-1 subsystem can call guest languages in-process (or via a child process) without leaving the Q128.128 numeric domain. The universal cross-language numeric is the FANO i256: a 256-bit two's-complement integer carrying a Q128.128 fixed-point value scaled by 2^-128. Values cross language boundaries exactly — through decimal strings for arbitrary-precision hosts (Python, JavaScript) and through the canonical little-endian 32-byte ABI for C-ABI guests (Rust, C, .NET).

### Module Structure

| File | Lines | Purpose |
|------|-------|---------|
| `poly.zig` | 1400+ | Runtime core: i256 ABI, Python/QuickJS/Rust/C/.NET/Q#/Java/Node guests, unit tests |
| `poly_smoke.zig` | 110 | Standalone smoke exe (same build env as tests) for crash isolation; verifies Java + Node |
| `fanop.zig` | 540 | `.fanop` polyglot project parser + codegen + tests |
| `fanop_main.zig` | 185 | `fano-poly` CLI entry point (build/run/repl) |
| `demo.fanop` | 23 | Demo `.fanop` project (py + js + zig orchestration) |
| `c_guest/guest.c` | 128 | C guest: i256 echo/add/mulraw + Q128.128 fixed-point mul |
| `rust_guest/src/lib.rs` | 189 | Rust guest (`fano-poly-rs` staticlib, C ABI) |
| `dotnet_guest/Guest.cs` | 86 | C# guest with `UnmanagedCallersOnly` exports |
| `java_guest/FanoPoly.java` | 60 | Java guest (`fanopoly.FanoPoly`, static methods on byte[] i256) |
| `node_guest/guest.js` | 70 | Node guest (BigInt i256 over stdin/stdout protocol) |
| `qs_guest/Operations.qs` | 56 | Q# operations: QRandom, BellCorrelated, CoinOnes |
| `qs_guest/Guest.cs` | 34 | Q# C-ABI exports (reserved for a future AOT path) |
| `qs_guest/Runner.cs` | 66 | Q# CLI runner dispatched by the subprocess bridge |
| `qs_guest/FanoQs.csproj` | 14 | QDK 0.28 project (net8.0, offline NuGet cache) |
| `vendor/` | dir | Vendored QuickJS sources (quickjs.c, libregexp, libunicode, libbf, cutils) |

### Dependencies

- **Internal**: `q128_128` module (`../q128_128.zig`)
- **External**: CPython 3.11 (`libpython3.11`), .NET 8 SDK (`dotnet` host), cargo (Rust stable), QDK NuGet packages (cached, offline), bundled JDK 17 (`os/fano-langs/jdk-17.0.20.1+1`), bundled Node 20 (`os/fano-langs/node20`)
- **Vendored**: QuickJS 2024-01-13 (C sources, compiled into the binary)

### Guest Integration Matrix

| Guest | Hosting model | Boundary | Init |
|-------|--------------|----------|------|
| CPython 3.11 | In-process (CPython C API, linked libpython) | decimal strings → i256 | `Py_Initialize` (process-lifetime, no re-init) |
| QuickJS | In-process (vendored C) | BigInt decimal strings → i256 | runtime + context per `QuickJS.init` |
| Rust | Static link (`libfano_poly_rs.a`) | C ABI on 32-byte i256 | none (stateless) |
| C | Compiled into the binary | C ABI on 32-byte i256 | none (stateless) |
| C#/.NET | `dlopen` NativeAOT `libFanoPolyCs.so` | C ABI on 32-byte i256 | `DynLib.open` + export lookup |
| Q# | Child process (`dotnet FanoQs.dll <op> [arg]`) | bare integers on stdout | path registration (`Qs.init`) |
| Java/JVM | In-process (HotSpot JNI, `dlopen libjvm.so`) | `byte[]` i256 via JNI | `Java.init(classpath)` boots the JVM once |
| Node | Child process (`node guest.js <op> <args>`) | 64-char hex i256 on stdout | `Node.initAuto` discovers vendored/system node |

---

## I256: Canonical Cross-Language Numeric ABI

`I256 = [32]u8` — plain little-endian 256-bit two's complement (matches Rust `i256`, .NET `BigInteger` and Python `int.to_bytes`). The WASM runtime's limb-swapped layout is a separate convention converted at that boundary.

Key operations in `poly.zig`:

- `i256FromQ128` / `i256ToQ128` — pack/unpack Q128.128 values
- `i256FromDecimal` / `i256ToDecimal` — exact decimal parse/format with mod 2^256 wraparound
- `i256FromHex` — hex parse (Python `hex(int(...))` repr path)
- `q128ToBytes` / `q128FromI256` — Q128.128 ↔ i256 aliases

Decimal parsing wraps modulo 2^256 (Zig `u256` arithmetic wraps naturally), so guests can return any integer and the host masks deterministically.

---

## Python Guest (CPython C API)

Embedded interpreter linked against `libpython3.11`.

- `Python.init()` — idempotent boot; CPython cannot re-init after `Py_FinalizeEx`, so teardown is process-exit only
- `run(code)` — `PyRun_SimpleString`
- `eval(expr)` — `PyRun_String` in `Py_eval_input` mode, returns `repr()`
- `evalI256(expr)` — evaluates `hex(int(expr))` and parses the exact hex back into i256 (no precision loss for any Python int)
- `evalQ128(expr)` — raw-mantissa fixed-point: the Python side computes on integers scaled by 2^128

## QuickJS Guest

Vendored C sources compiled into the binary; ES2020 + BigInt.

- `eval(expr)` — `JS_Eval`, returns string conversion
- `evalI256(expr)` — strips the BigInt `n` suffix, dispatches on `0x` prefix to hex or decimal parsing
- `evalQ128(expr)` — raw-mantissa fixed-point via BigInt (`3n<<127n` style expressions)

## Rust Guest (staticlib)

`cargo build --release` produces `libfano_poly_rs.a`, linked into the Zig binary. Exports: `poly_rs_version`, `poly_rs_echo`, `poly_rs_mulraw`, `poly_rs_add128`, `poly_rs_mul128`. `mul128` computes the Q128.128 product through the exact 512-bit intermediate.

## C Guest

`guest.c` compiled directly into the binary (same C ABI surface as Rust: version/echo/add128/mulraw/mul128).

## .NET Guest (NativeAOT)

`dotnet_guest` publishes to `libFanoPolyCs.so` via NativeAOT (`PublishAot=true`); the Zig host `dlopen`s it and resolves `fano_poly_version`, `fano_poly_echo`, `fano_poly_add128`, `fano_poly_mulraw`, `fano_poly_mul128` into typed C-ABI pointers. Unavailable (missing .so / exports) → guests return `DotNetGuestUnavailable` and tests skip.

## Q# Guest (QDK subprocess bridge)

The QDK compiles `.qs` sources offline from cached NuGet packages (`Microsoft.Quantum.Sdk/0.28.302812`). In-process hosting was evaluated and rejected:

- **hostfxr**: broken on the build machine
- **NativeAOT**: ILC exceeds 27 min CPU on the QDK dependency tree with no completion (killed); impractical for the build

The documented fallback mirrors the Node bridge model: the guest runs the framework-dependent runner as a child process and exchanges bare integers on stdout.

### Runner protocol (`qs_guest/Runner.cs`)

```
dotnet FanoQs.dll version        -> 1
dotnet FanoQs.dll qrandom <n>    -> n Hadamard coins packed little-endian (n in 0..16)
dotnet FanoQs.dll bell <shots>   -> correlated Bell outcomes (ideal: == shots)
dotnet FanoQs.dll coin <shots>   -> Hadamard coin One-count (ideal: ~ shots/2)
```

Non-zero exit or unparseable stdout maps to `QsError` / `NotAnInteger`; spawn failure maps to `QsGuestUnavailable`. `qrandom` caps n at 16 (simulator memory grows as 2^n).

### Q# operations (`Operations.qs`)

- `QRandom(n)` — H on n qubits, `MultiM`, bit-packed little-endian (q0 → bit 0)
- `BellCorrelated(shots)` — H + CNOT per shot, counts `ra == rb` (ideal simulator: every shot correlated)
- `CoinOnes(shots)` — single-qubit Hadamard coin, counts One (converges to shots/2)

`Guest.cs` additionally carries `UnmanagedCallersOnly` exports (`fano_qs_version`, `fano_qs_qrandom`, `fano_qs_bell_correlated`, `fano_qs_coin_ones`) kept for a future NativeAOT path; they are not used by the subprocess bridge.

---

## Java/JVM Guest (HotSpot JNI embed)

The Java guest embeds HotSpot in-process through JNI. `libjvm.so` is `dlopen`ed at run time from the bundled JDK (`os/fano-langs/jdk-17.0.20.1+1/lib/server/libjvm.so`), `JAVA_HOME` is derived from the libjvm path so HotSpot can locate `libjava.so`/`libjli.so`/the modules image, and `JNI_CreateJavaVM` boots a 1.8-compatible JVM with `-Djava.class.path`/`-Djava.library.path`/`-Xrs` options. `-Xrs` reduces JVM signal usage so it does not fight the host's signal handlers.

### JNI pointer convention

`JNIEnv` is `[*c]const struct_JNINativeInterface_` (a pointer to the function table). `JNI_CreateJavaVM` writes the **address of the per-thread JNIEnv handle** (a double pointer) into `*penv`, so the Zig state holds `env: *jni.JNIEnv` (the double pointer). The function table is reached by dereferencing once: `table() = @ptrCast(env.*)`; JNI calls receive the handle itself: `envp() = @ptrCast(env)`. Treating `env` as the table pointer directly (a common mistake) reads fields from the wrong address and crashes inside `FindClass`.

### API

- `Java.init(classpath)` — `dlopen` libjvm, boot the JVM, `FindClass("fanopoly/FanoPoly")`, pin a global ref, resolve `version`/`echo`/`add128`/`mulraw`/`mul128` method IDs
- `Java.version()`, `Java.echo`, `Java.add128`, `Java.mulraw`, `Java.mul128` — marshal i256 through JNI `NewByteArray`/`SetByteArrayRegion`/`CallStaticObjectMethod`
- `Java.mulQ128(a, b)` — Q128.128 fixed-point product via `mul128`
- `Java.deinit()` — `DestroyJavaVM`

### Test-runner safety

HotSpot's signal-based runtime conflicts with the Zig test runner's signal handlers. In-process Java unit tests are therefore disabled under the test runner (they print a skip line and return `SkipZigTest`); Java is verified by the standalone `poly-smoke` executable, which the `test-poly` step builds and runs with `LD_LIBRARY_PATH` pointing at the JDK lib dirs. `poly-smoke` reports `java version`, `java q128: 1.5*2.5 = …`, and `java agrees: true`.

## Node Guest (subprocess bridge)

The Node guest runs the vendored Node 20 binary (`os/fano-langs/node20/bin/node`, falling back to system `node`) as a child process. `node_guest/guest.js` implements the i256 ABI over a stdin/stdout protocol: each invocation is `node guest.js <op> <hex...>` and the guest prints a 64-char hex i256 on stdout. BigInt handles arbitrary-precision; results wrap mod 2^256.

### Protocol

```
node guest.js version              -> 1
node guest.js echo <hex>           -> <hex>
node guest.js add128 <a> <b>       -> <hex>
node guest.js mulraw <a> <b>       -> <hex>
node guest.js mul128 <a> <b>       -> <hex>   (Q128.128 fixed-point: (a*b)>>128)
```

### API

- `Node.initAuto()` — discovers the vendored node via `std.fs.cwd().access` (relative path from `poly/`), falls back to `node` on PATH
- `Node.version()`, `Node.echo`, `Node.add128`, `Node.mulraw`, `Node.mul128`, `Node.mulQ128`
- Spawn failure → `NodeGuestUnavailable`; non-zero exit → `NodeError`; unparseable hex → `NotAnInteger`

Node unit tests run under the test runner (no signal conflict) and cover echo, version, fixed-point mul (positive and negative), and raw-mul wraparound. `poly-smoke` additionally reports `node version`, `node q128`, `node agrees`, and `node raw`.

---

## fano-poly CLI (`.fanop` project front end)

`fano-poly` is the user-facing polyglot project tool. A `.fanop` file is a set of language-tagged function blocks (`py`/`js`/`zig`) sharing the canonical i256 ABI, plus one `zig fn main` orchestration block.

### Grammar

```
# comment
name: <project-name>

<lang> fn <name>(<params>) { <body> }
```

`<lang>` is `py`, `js`, or `zig`. `py`/`js` bodies are literal source in the target language (Python bodies are author-indented inside the braces; the braces are stripped on emit). `zig` has exactly one block named `main`. py/js functions take and return i256; the generated Zig bindings marshal each argument through its exact decimal form (`i256ToDecimal`) so arbitrary-precision guests see the full value.

### Commands

- `fano-poly build <proj>.fanop` — parse + codegen a self-contained Zig project into `<proj>.fanop.out/` + `zig build`
- `fano-poly run <proj>.fanop` — build, then run the generated executable
- `fano-poly repl` — interactive py/js polyglot REPL (`py <expr>` / `js <expr>` / bare = Python)

### Codegen

The generated project (`main.zig` + `polygen.py` + `polygen.js` + `build.zig` + `build.zig.zon`) reuses the FANO poly runtime at `FANO_ZIG_ROOT` (baked into the `fano-poly` binary at build time and forwarded to the generated `zig build` via the env var). `main.zig` boots CPython + QuickJS, execs `polygen.py` into `__main__` (embedded CPython's sys.path does not include the CWD, so a plain `import` is unreliable), evals `polygen.js` once, and exposes `py_<name>`/`js_<name>` bindings that the user's `zig fn main` body calls.

```bash
cd zig && zig build                  # builds poly-smoke + fano-poly
./zig-out/bin/fano-poly run poly/demo.fanop   # py add 1.5+2.5 = 4.0 ; js mul 1.5*2.5 = 3.750
./zig-out/bin/fano-poly repl                  # py 6*7 -> 42 ; js 3n*4n -> 12
```

---

## Tests

`zig build test-poly` builds all guests (cargo staticlib, .NET NativeAOT publish, Q# framework-dependent publish, `javac` of `FanoPoly.java`) and runs the poly test suite, then builds and runs `poly-smoke` to verify the Java and Node guests end-to-end (Java unit tests are skipped under the test runner due to HotSpot signal conflicts — see the Java/JVM section).

- i256 ABI round-trips, decimal parse wraparound, decimal round-trip
- QuickJS eval/BigInt/q128; Python eval/exact-int/q128
- Cross-guest agreement: Python + QuickJS + Rust + C (+ .NET when present) must agree bit-for-bit on the same fixed-point product (1.5 × 2.5 = 3.75 → mantissa 15·2^126)
- Q# guest: version, Bell correlation (128/128), coin fairness band (400..600 of 1000), qrandom range
- Node guest: version, echo, fixed-point mul (positive and negative), raw-mul wraparound
- `poly-smoke` verifies Java (version, q128 mul, agrees) and Node (version, q128 mul, agrees, raw) in addition to the in-process guests

`zig build test-fanop` runs the `fanop.zig` parser/codegen unit tests (block parsing, unclosed-block rejection, unknown-lang rejection, codegen output checks). `zig build test` aggregates every suite.

`poly_smoke.zig` builds the same environment as a normal executable (`poly-smoke`) for crash isolation; it prints per-guest results and the cross-guest agreement matrix, including Java and Node.

```bash
cd zig && zig build test-poly -Doptimize=ReleaseSafe   # poly unit tests + poly-smoke (Java/Node)
cd zig && zig build test-fanop -Doptimize=ReleaseSafe  # fano-poly parser/codegen tests
cd zig && zig build test -Doptimize=ReleaseSafe        # all suites
./zig-out/bin/poly-smoke                               # smoke run
./zig-out/bin/fano-poly run poly/demo.fanop            # fano-poly demo
```

---

## Integration Points

- **Q128.128 Core** (`zig/q128_128.zig`): every guest ultimately produces/consumes `q128` values through the i256 ABI
- **OS build** (`os/`): the ISO language matrix (`os/fano-langs/`) bakes the JDK 17 and Node 20 runtimes (already vendored) plus a .NET 8 runtime so `dotnet` is on PATH for the Q# bridge
- **Local inference** (`os/llama.cpp/`): llama.cpp provides CPU inference for Qwen3.6 models via an OpenAI-compatible server; the Space Agent `_core/local_llama/` module connects the polyglot desktop to the local model (see `docs/17-local-inference.md`)
- **fano-poly**: generated projects reuse the poly runtime via `FANO_ZIG_ROOT`; the CLI supports `py`/`js`/`zig` blocks in v1 (the compiled guests c/rs/cs/java/qs reuse the pre-built FANO guest libraries and are wired in a later phase)
- **NativeAOT status**: QDK NativeAOT is not viable (ILC > 27 min CPU, no completion); the C# guest uses NativeAOT successfully, the Q# guest uses the subprocess bridge

**ATMA mapping:** Law of Assimilation (Nididhyasana) — theoretical parameters compiled into live execution across nine languages (see docs/16-atma-fano1.md).
