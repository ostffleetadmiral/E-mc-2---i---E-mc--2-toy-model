namespace FanoQs {
    open Microsoft.Quantum.Intrinsic;
    open Microsoft.Quantum.Measurement;
    open Microsoft.Quantum.Arrays;

    /// Quantum random number: measures `n` Hadamard coins and packs the
    /// outcomes into one little-endian integer (q0 -> bit 0).
    operation QRandom(n : Int) : Int {
        use register = Qubit[n];
        for q in register {
            H(q);
        }
        let bits = MultiM(register);
        ResetAll(register);
        mutable acc = 0;
        for (i, r) in Enumerated(bits) {
            if r == One {
                set acc = acc + (1 <<< i);
            }
        }
        return acc;
    }

    /// Run the Bell circuit (H + CNOT) `shots` times and count the
    /// correlated outcomes (00 or 11). For an ideal simulator every
    /// shot is correlated, so the result equals `shots`.
    operation BellCorrelated(shots : Int) : Int {
        mutable correlated = 0;
        for _ in 1..shots {
            use (a, b) = (Qubit(), Qubit());
            H(a);
            CNOT(a, b);
            let (ra, rb) = (M(a), M(b));
            ResetAll([a, b]);
            if ra == rb {
                set correlated += 1;
            }
        }
        return correlated;
    }

    /// Estimate the probability of observing One from a single Hadamard
    /// coin flipped `shots` times (ideal simulator: converges to 0.5).
    operation CoinOnes(shots : Int) : Int {
        mutable ones = 0;
        for _ in 1..shots {
            use q = Qubit();
            H(q);
            if M(q) == One {
                set ones += 1;
            }
            Reset(q);
        }
        return ones;
    }
}
