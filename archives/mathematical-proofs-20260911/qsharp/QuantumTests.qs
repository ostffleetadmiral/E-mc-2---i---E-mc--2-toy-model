namespace HardwareProofs {
    open Microsoft.Quantum.Canon;
    open Microsoft.Quantum.Intrinsic;

    operation TestB_OctonionPropagation() : Unit {
        use q = Qubit[3] {
            H(q[0]);
            H(q[1]);
            H(q[2]);
            ResetAll(q);
        }
    }

    operation TestC_SmithMobiusBoundary() : Unit {
        use q = Qubit() {
            X(q);
            Reset(q);
        }
    }

    operation TestF_QEDCorrection() : Unit {
        use q = Qubit() {
            H(q);
            S(q);
            Reset(q);
        }
    }
}
