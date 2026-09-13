// Q# guest runner: CLI dispatch for the Zig host's subprocess bridge.
//
// Usage: dotnet FanoQs.dll <op> [arg]
//   version            -> prints ABI version (1)
//   qrandom <n>        -> n Hadamard coins packed little-endian (n in 0..63)
//   bell <shots>       -> Bell-pair correlation count (ideal: == shots)
//   coin <shots>       -> Hadamard coin One-count (ideal: ~ shots/2)
//
// Results are printed as bare integers on stdout; the Zig guest parses them.
using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using Microsoft.Quantum.Simulation.Simulators;

namespace FanoQs;

public static class Program
{
    private static T Wait<T>(Task<T> task) => task.GetAwaiter().GetResult();

    public static int Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine("usage: FanoQs <version|qrandom|bell|coin> [arg]");
            return 2;
        }

        switch (args[0])
        {
            case "version":
                Console.WriteLine(1);
                return 0;

            case "qrandom":
            {
                int n = int.Parse(args[1]);
                if (n < 0 || n > 16)
                {
                    Console.Error.WriteLine("qrandom: n must be in 0..16 (simulator memory grows as 2^n)");
                    return 2;
                }
                Console.WriteLine(Wait(QRandom.Run(new QuantumSimulator(), n)));
                return 0;
            }

            case "bell":
            {
                int shots = int.Parse(args[1]);
                Console.WriteLine(Wait(BellCorrelated.Run(new QuantumSimulator(), shots)));
                return 0;
            }

            case "coin":
            {
                int shots = int.Parse(args[1]);
                Console.WriteLine(Wait(CoinOnes.Run(new QuantumSimulator(), shots)));
                return 0;
            }

            default:
                Console.Error.WriteLine($"unknown op '{args[0]}'");
                return 2;
        }
    }
}
