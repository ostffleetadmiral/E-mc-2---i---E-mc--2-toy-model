// FanoPoly - Java guest for the FANO polyglot runtime.
//
// Loaded in-process by the Zig host through the JNI invocation API
// (JNI_CreateJavaVM). All static methods use the canonical FANO i256
// ABI: 32-byte little-endian two's-complement integers carrying
// Q128.128 fixed-point values (128.128, scaled by 2^-128).
// java.math.BigInteger is big-endian two's complement, so the 32 bytes
// are reversed at each boundary.
package fanopoly;

import java.math.BigInteger;

public final class FanoPoly {

    static final int ABI_VERSION = 1;

    private static final BigInteger MASK256 = BigInteger.ONE.shiftLeft(256).subtract(BigInteger.ONE);
    private static final BigInteger TWO128 = BigInteger.ONE.shiftLeft(128);
    private static final BigInteger MASK127 = BigInteger.ONE.shiftLeft(127).subtract(BigInteger.ONE);

    private FanoPoly() {}

    // Crate ABI version.
    public static int version() {
        return ABI_VERSION;
    }

    // Identity probe: copies 32 bytes, used by link/ABI smoke tests.
    public static byte[] echo(byte[] v) {
        return v.clone();
    }

    // Q128.128 fixed-point add: plain 256-bit two's-complement addition.
    public static byte[] add128(byte[] a, byte[] b) {
        return toLe(fromLe(a).add(fromLe(b)));
    }

    // Raw 256-bit two's-complement multiply (low 256 bits of the product).
    public static byte[] mulraw(byte[] a, byte[] b) {
        return toLe(fromLe(a).multiply(fromLe(b)));
    }

    // Q128.128 fixed-point multiply: (a * b) >> 128 with round-to-nearest-
    // even, computed through the exact product. BigInteger.shiftRight is
    // an arithmetic (floor) shift, matching the Rust/C/.NET guests.
    public static byte[] mul128(byte[] a, byte[] b) {
        BigInteger p = fromLe(a).multiply(fromLe(b));
        BigInteger q = p.shiftRight(128);            // floor for negatives
        BigInteger dropped = p.and(TWO128.subtract(BigInteger.ONE));
        boolean round = dropped.testBit(127);
        boolean sticky = dropped.and(MASK127).signum() != 0;
        if (round && (sticky || !q.testBit(0))) {
            q = q.add(BigInteger.ONE);
        }
        return toLe(q);
    }

    private static BigInteger fromLe(byte[] le) {
        byte[] be = new byte[32];
        for (int i = 0; i < 32; i++) {
            be[i] = le[31 - i];
        }
        return new BigInteger(be);
    }

    private static byte[] toLe(BigInteger v) {
        // Mask to the low 256 bits (two's-complement pattern), then take
        // the minimal big-endian magnitude and reverse it into 32 LE bytes.
        byte[] be = v.and(MASK256).toByteArray();
        byte[] le = new byte[32];
        for (int i = 0; i < 32; i++) {
            int beIdx = be.length - 1 - i;
            le[i] = beIdx >= 0 ? be[beIdx] : 0;
        }
        return le;
    }
}
