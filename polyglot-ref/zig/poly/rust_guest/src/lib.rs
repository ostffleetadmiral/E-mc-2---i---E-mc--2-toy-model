//! fano-poly-rs - Rust guest for the FANO polyglot runtime.
//!
//! Compiled to a staticlib and linked into the Zig host. All functions use
//! the canonical FANO i256 C ABI: 32-byte little-endian two's-complement
//! integers carrying Q128.128 fixed-point values (128.128, scaled by 2^-128).
//! Rust core has no i256, so arithmetic runs on 4x u64 limbs.
#![no_std]

use core::panic::PanicInfo;

#[panic_handler]
fn rs_panic(_: &PanicInfo) -> ! {
    // The guest performs no fallible operations; a panic here is a hard
    // contract violation. Halt instead of unwinding (no libunwind dep).
    loop {
        core::hint::spin_loop();
    }
}

/// Personality stub: the crate never unwinds (panic = abort), but the
/// prebuilt compiler_builtins object emits a DW.ref.rust_eh_personality
/// reference that the linker needs resolved.
#[no_mangle]
pub extern "C" fn rust_eh_personality(
    _version: i32,
    _actions: u32,
    _exception_class: u64,
    _exception_object: *mut core::ffi::c_void,
    _context: *mut core::ffi::c_void,
) -> core::ffi::c_int {
    0
}

/// Crate ABI version.
#[no_mangle]
pub extern "C" fn poly_rs_version() -> u32 {
    1
}

/// Identity probe: copies 32 bytes, used by link/ABI smoke tests.
#[no_mangle]
pub extern "C" fn poly_rs_echo(v: *const u8, out: *mut u8) {
    unsafe {
        core::ptr::copy_nonoverlapping(v, out, 32);
    }
}

/// Load a 32-byte LE two's-complement value into 4 u64 limbs.
unsafe fn load256(p: *const u8) -> [u64; 4] {
    let b: &[u8; 32] = &*(p as *const [u8; 32]);
    let mut limbs = [0u64; 4];
    for i in 0..4 {
        let mut v: u64 = 0;
        for k in 0..8 {
            v |= (b[i * 8 + k] as u64) << (8 * k);
        }
        limbs[i] = v;
    }
    limbs
}

/// Store 4 u64 limbs LE into a 32-byte buffer.
unsafe fn store256(limbs: &[u64; 4], out: *mut u8) {
    for i in 0..4 {
        for k in 0..8 {
            *out.add(i * 8 + k) = (limbs[i] >> (8 * k)) as u8;
        }
    }
}

/// Limb-wise wrapping add with carry out.
fn add256(a: &[u64; 4], b: &[u64; 4]) -> [u64; 4] {
    let mut out = [0u64; 4];
    let mut carry: u64 = 0;
    for i in 0..4 {
        let (s1, c1) = a[i].overflowing_add(b[i]);
        let (s2, c2) = s1.overflowing_add(carry);
        out[i] = s2;
        carry = (c1 as u64) | (c2 as u64);
    }
    out
}

/// Two's-complement negate (limb-wise).
fn neg256(a: &[u64; 4]) -> [u64; 4] {
    let mut out = [0u64; 4];
    let mut carry = 1u64;
    for i in 0..4 {
        let (s, c) = (!a[i]).overflowing_add(carry);
        out[i] = s;
        carry = c as u64;
    }
    out
}

/// Magnitude of a two's-complement 256-bit value as unsigned limbs.
fn mag256(limbs: &[u64; 4]) -> [u64; 4] {
    if limbs[3] >> 63 != 0 {
        neg256(limbs)
    } else {
        *limbs
    }
}

/// 4x4 -> 8 limb schoolbook multiply (unsigned magnitudes).
fn mul_limbs(a: &[u64; 4], b: &[u64; 4]) -> [u64; 8] {
    let mut out = [0u64; 8];
    for i in 0..4 {
        let mut carry: u128 = 0;
        for j in 0..4 {
            let cur = out[i + j] as u128 + (a[i] as u128) * (b[j] as u128) + carry;
            out[i + j] = cur as u64;
            carry = cur >> 64;
        }
        let mut k = i + 4;
        while carry > 0 {
            let cur = out[k] as u128 + carry;
            out[k] = cur as u64;
            carry = cur >> 64;
            k += 1;
        }
    }
    out
}

/// Negate an 8-limb 512-bit two's-complement value.
fn neg512(limbs: &mut [u64; 8]) {
    let mut carry = 1u128;
    for limb in limbs.iter_mut() {
        let v = (!*limb) as u128 + carry;
        *limb = v as u64;
        carry = v >> 64;
    }
}

/// Raw 256-bit two's-complement multiply (low 256 bits of the product).
#[no_mangle]
pub extern "C" fn poly_rs_mulraw(a: *const u8, b: *const u8, out: *mut u8) {
    unsafe {
        let a = load256(a);
        let b = load256(b);
        let p = mul_limbs(&a, &b);
        store256(&[p[0], p[1], p[2], p[3]], out);
    }
}

/// Q128.128 fixed-point add: plain 256-bit two's-complement addition.
#[no_mangle]
pub extern "C" fn poly_rs_add128(a: *const u8, b: *const u8, out: *mut u8) {
    unsafe {
        let a = load256(a);
        let b = load256(b);
        store256(&add256(&a, &b), out);
    }
}

/// Q128.128 fixed-point multiply: (a * b) >> 128 with round-to-nearest-even,
/// computed through the exact 512-bit signed product.
#[no_mangle]
pub extern "C" fn poly_rs_mul128(a: *const u8, b: *const u8, out: *mut u8) {
    unsafe {
        let al = load256(a);
        let bl = load256(b);
        let p = mul_widen(&al, &bl); // 512-bit two's complement, 8 u64 limbs LE
        // q = P >> 128 (arithmetic): limbs 2..6 of the product.
        let mut q = add256(&[p[2], p[3], p[4], p[5]], &[0; 4]);
        // Round-to-nearest-even on the dropped 128 bits:
        // round bit = bit 127 of P (limb 1 top bit), sticky = bits 126..0.
        let round = (p[1] >> 63) & 1;
        let sticky = (p[0] & !(1u64 << 63)) != 0;
        if round == 1 && (sticky || (q[0] & 1) == 1) {
            q = add256(&q, &[1, 0, 0, 0]);
        }
        store256(&q, out);
    }
}

/// 256x256 -> 512-bit signed multiply, two's complement, 8 u64 limbs LE.
fn mul_widen(a: &[u64; 4], b: &[u64; 4]) -> [u64; 8] {
    let neg = (a[3] >> 63 != 0) != (b[3] >> 63 != 0);
    let am = mag256(a);
    let bm = mag256(b);
    let mut out = mul_limbs(&am, &bm);
    if neg {
        neg512(&mut out);
    }
    out
}

