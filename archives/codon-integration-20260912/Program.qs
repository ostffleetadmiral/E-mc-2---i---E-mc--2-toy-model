namespace HardwareProofs {
    open Microsoft.Quantum.Canon;
    open Microsoft.Quantum.Intrinsic;

    @EntryPoint()
    operation Main() : Unit {
        let results = [
            Chunk01FixedPoint(), Chunk02Hydrogen(), Chunk03Triad(),
            Chunk04AlphaFailure(), Chunk05Propagation(), Chunk06Graph(),
            Chunk07Consistency(), Chunk08Axiom(), Chunk09Constants(),
            Chunk10Recurrence(), Chunk11QED(), Chunk12Octonion(),
            Chunk13Generative(), Chunk14Matrix(), Chunk15E8(), Chunk16Shell(),
            Chunk17Mobius(), Chunk18Smith(), Chunk19FineStructure(),
            Chunk20Architecture(), Chunk21EMChain(), Chunk22Integration()
        ];
        for result in results {
            Message(result);
        }
        TestB_OctonionPropagation();
        TestC_SmithMobiusBoundary();
        TestF_QEDCorrection();
        // Codon integration witnesses
        Message(CodonCodeSize());
        Message(CodonAUGIndex());
        Message(CodonFullWitness());
        Message(CodonStopWitness());
        Message(CodonAcidicWitness());
        Message(CodonOctonionCrossWire());
        Message("Q# quantum proof suite completed");
    }
}
