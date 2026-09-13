// Q# guest C-ABI exports: wraps the Q# operations in Operations.qs with
// UnmanagedCallersOnly entry points so the Zig host can call them directly
// (same pattern as the C#/.NET guest).
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Quantum.Simulation.Simulators;

namespace FanoQs;

public static class Guest
{
    private static T Wait<T>(Task<T> task) => task.GetAwaiter().GetResult();

    // Crate ABI version.
    [UnmanagedCallersOnly(EntryPoint = "fano_qs_version")]
    public static uint Version() => 1u;

    // Quantum random number: `n` Hadamard coins measured as one little-
    // endian integer (n in 0..63 keeps the result inside i64).
    [UnmanagedCallersOnly(EntryPoint = "fano_qs_qrandom")]
    public static long QRandom(int n) =>
        Wait(global::FanoQs.QRandom.Run(new QuantumSimulator(), n));

    // Bell-pair correlation count: measures `shots` Bell pairs and counts
    // outcomes where both qubits agree. Ideal simulator: always == shots.
    [UnmanagedCallersOnly(EntryPoint = "fano_qs_bell_correlated")]
    public static long BellCorrelated(int shots) =>
        Wait(global::FanoQs.BellCorrelated.Run(new QuantumSimulator(), shots));

    // Hadamard coin: number of One outcomes in `shots` ideal flips.
    [UnmanagedCallersOnly(EntryPoint = "fano_qs_coin_ones")]
    public static long CoinOnes(int shots) =>
        Wait(global::FanoQs.CoinOnes.Run(new QuantumSimulator(), shots));
}
