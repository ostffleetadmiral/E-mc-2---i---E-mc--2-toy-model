# WASM fixed-point wave — Knuth-D i512 division (2026-10-10)

Retrograde wave: the `wasm/emc2-proofs.wasm` module previously exported only
10 integer-identity checks because `src/fixed_point.zig` used i512
`@divTrunc`/`@mod` and LLVM has no i512 division libcall on wasm32
("Unsupported library call operation"). That limitation is now removed.

## Changes

- `src/fixed_point.zig` — added `udiv512rem`: Knuth Algorithm D over u64
  digits (up to 9-limb dividend, trimmed divisor, u128 intermediates —
  u128 div has a libcall on every target) plus `divTruncI512` sign
  wrapper. `div`, `fromRatio`, and `sqrt` (Newton iterate) now route
  through it. Bit-identical semantics: truncating division, floored mod,
  Newton iterate uses identical floor division.
- `wasm/build.zig` — wired `../src/fixed_point.zig` into the wasm module
  as named import `fixed_point`.
- `wasm/wasm_main.zig` — `verify_rne_multiply` upgraded from an
  integer-identity stand-in to real Q128.128 RNE checks (below-half,
  tie-to-even, above-half, identity); added `verify_fp_division`
  (both signs), `verify_fp_from_ratio` (half-away-from-zero boundaries),
  `verify_fp_sqrt` (exact + few-ulp bounds). 10 → 14 exported proofs.
- `coherent-system.md` — export list updated.

## Verification

- `zig test -Mroot=src/fixed_point.zig`: 37/37.
- `zig build test`: 576/576 (full suite, post-change binary re-run).
- `cd wasm && zig build`: clean.
- `k3w zig-out/bin/emc2-proofs.wasm` → "All 14 proofs passed in WASM."
- Node WASI `wasi.start` → identical output (bit-identical runtimes).

## Related

Same LLVM gap fixed in `basic/qstar-llm` (i256 div → `udiv256x128`,
archive `~/.archives/qstar-wasm-freestanding-knuthd-20261010`). The
hardware variant generalizes to u512 dividends/divisors and preserves
the Knuth remainder for `fromRatio`'s round-half-away-from-zero.
