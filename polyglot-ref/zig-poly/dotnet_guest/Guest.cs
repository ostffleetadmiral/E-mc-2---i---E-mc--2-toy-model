// Guest.cs - C# guest for the FANO polyglot runtime.
//
// Loaded by the Zig host through hostfxr's load-assembly-and-get-function-
// pointer delegate. Every exported method is [UnmanagedCallersOnly] on the
// canonical FANO i256 C ABI: 32-byte little-endian two's-complement
// integers carrying Q128.128 fixed-point values (scaled by 2^-128).
// System.Numerics.BigInteger(byte[]) is little-endian two's complement,
// which matches the ABI byte-for-byte.

using System;
using System.Numerics;
using System.Runtime.InteropServices;

namespace FanoPolyCs;

public static class Guest
{
    private const int Width = 32;

    // Crate ABI version.
    [UnmanagedCallersOnly(EntryPoint = "fano_poly_version")]
    public static uint Version() => 1u;

    // Identity probe: copies 32 bytes, used by link/ABI smoke tests.
    [UnmanagedCallersOnly(EntryPoint = "fano_poly_echo")]
    public static unsafe void Echo(byte* vin, byte* outp)
    {
        for (int i = 0; i < Width; i++) outp[i] = vin[i];
    }

    // Q128.128 fixed-point add: plain 256-bit two's-complement addition.
    [UnmanagedCallersOnly(EntryPoint = "fano_poly_add128")]
    public static unsafe void Add128(byte* a, byte* b, byte* outp)
    {
        var av = Load(a);
        var bv = Load(b);
        Store(outp, av + bv);
    }

    // Raw 256-bit two's-complement multiply (low 256 bits of the product).
    [UnmanagedCallersOnly(EntryPoint = "fano_poly_mulraw")]
    public static unsafe void MulRaw(byte* a, byte* b, byte* outp)
    {
        var av = Load(a);
        var bv = Load(b);
        Store(outp, av * bv);
    }

    // Q128.128 fixed-point multiply: (a * b) >> 128 with round-to-nearest-
    // even, computed through the exact product. BigInteger >> is an
    // arithmetic (floor) shift, matching the Rust/C guests.
    [UnmanagedCallersOnly(EntryPoint = "fano_poly_mul128")]
    public static unsafe void Mul128(byte* a, byte* b, byte* outp)
    {
        var p = Load(a) * Load(b);
        var q = p >> 128;                       // floor for negatives
        BigInteger dropped = p & ((BigInteger.One << 128) - 1);
        bool round = dropped >= (BigInteger.One << 127);
        bool sticky = (dropped & ((BigInteger.One << 127) - 1)) != 0;
        if (round && (sticky || !q.IsEven))
        {
            q += 1;
        }
        Store(outp, q);
    }

    private static unsafe BigInteger Load(byte* p)
    {
        // BigInteger(byte[]) interprets the span as LE two's complement.
        Span<byte> tmp = stackalloc byte[Width];
        for (int i = 0; i < Width; i++) tmp[i] = p[i];
        return new BigInteger(tmp);
    }

    private static unsafe void Store(byte* o, BigInteger v)
    {
        // ToByteArray() is LE two's complement; length varies (32..33).
        // Truncate to 32 / sign-extend as needed to keep the ABI exact.
        Span<byte> tmp = stackalloc byte[Width];
        tmp.Fill((byte)(v.Sign < 0 ? 0xFF : 0x00));
        byte[] bytes = v.ToByteArray();
        int n = Math.Min(bytes.Length, Width);
        for (int i = 0; i < n; i++) tmp[i] = bytes[i];
        for (int i = 0; i < Width; i++) o[i] = tmp[i];
    }
}
