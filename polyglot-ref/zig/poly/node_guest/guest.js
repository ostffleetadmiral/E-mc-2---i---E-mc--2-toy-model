#!/usr/bin/env node
// guest.js - Node.js guest for the FANO polyglot runtime.
//
// Subprocess bridge (mirrors the Q# runner protocol): the Zig host spawns
// `node guest.js <op> [args...]` and reads one bare value from stdout.
// All i256 values are 64-char lowercase hex, two's complement, carrying
// Q128.128 fixed-point values (128.128, scaled by 2^-128).
//
// Ops:
//   version              -> 1
//   echo <hex>           -> hex
//   add128 <a> <b>       -> hex
//   mulraw <a> <b>       -> hex
//   mul128 <a> <b>       -> hex
//   eval <expr>          -> hex of the BigInt result (or raw value)

'use strict';

const MASK256 = (1n << 256n) - 1n;
const MASK128 = (1n << 128n) - 1n;

function fromHex(h) {
  if (!/^[0-9a-fA-F]{64}$/.test(h)) throw new Error(`bad i256 hex: ${h}`);
  let v = BigInt('0x' + h);
  if ((v >> 255n) & 1n) v -= 1n << 256n;
  return v;
}

function toHex(v) {
  return (v & MASK256).toString(16).padStart(64, '0');
}

function add128(a, b) {
  return toHex(a + b);
}

function mulraw(a, b) {
  return toHex(a * b);
}

// Q128.128 fixed-point multiply: (a * b) >> 128 with round-to-nearest-even,
// through the exact product. BigInt >> is an arithmetic (floor) shift,
// matching the Rust/C/.NET guests.
function mul128(a, b) {
  const p = a * b;
  let q = p >> 128n;
  const dropped = p & MASK128;
  const round = (dropped >> 127n) & 1n;
  const sticky = (dropped & ((1n << 127n) - 1n)) !== 0n;
  if (round === 1n && (sticky || (q & 1n) === 1n)) q += 1n;
  return toHex(q);
}

function run(op, args) {
  switch (op) {
    case 'version':
      return '1';
    case 'echo':
    case 'add128':
    case 'mulraw':
    case 'mul128': {
      const a = fromHex(args[0]);
      const b = op === 'echo' ? 0n : fromHex(args[1]);
      if (op === 'echo') return toHex(a);
      if (op === 'add128') return add128(a, b);
      if (op === 'mulraw') return mulraw(a, b);
      return mul128(a, b);
    }
    case 'eval': {
      // Evaluate one JS expression; BigInt/integer results come back as
      // canonical i256 hex, anything else as its string form.
      const r = eval(args[0]);
      if (typeof r === 'bigint') return toHex(r);
      if (typeof r === 'number' && Number.isInteger(r)) return toHex(BigInt(r));
      return String(r);
    }
    default:
      throw new Error(`unknown op: ${op}`);
  }
}

module.exports = { fromHex, toHex, add128, mulraw, mul128, run };

if (require.main === module) {
  try {
    const op = process.argv[2];
    if (!op) throw new Error('usage: guest.js <op> [args...]');
    process.stdout.write(run(op, process.argv.slice(3)) + '\n');
  } catch (err) {
    process.stderr.write(String(err && err.message ? err.message : err) + '\n');
    process.exit(1);
  }
}
