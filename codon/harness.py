#!/usr/bin/env python3
"""Run the codon routing test against a reference genome."""

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

# Allow running from the package directory without installation.
package_dir = Path(__file__).parent / "codon"
sys.path.insert(0, str(package_dir))

from codon.constants import CODON_LABELS, GENETIC_CODE
from codon.evaluate import evaluate
from codon.genome import DEFAULT_GENOME_URL, count_codons, download_default_genome, parse_fasta
from codon.signature import (
    ChemistrySignatureBuilder,
    PlaceholderSignatureBuilder,
    load_signatures,
    save_signatures,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Codon → 6D Jordan routing test")
    parser.add_argument(
        "--genome",
        "--fasta",
        dest="fasta",
        type=Path,
        help="FASTA file (DNA/RNA, .gz accepted). Downloads E. coli K-12 if omitted.",
    )
    parser.add_argument(
        "--signatures",
        type=Path,
        help="Optional JSON signature table. If omitted, the chemistry table is generated.",
    )
    parser.add_argument(
        "--builder",
        choices=["placeholder", "chemistry"],
        default="chemistry",
        help="Signature builder to use when --signatures is not provided.",
    )
    parser.add_argument("--output", type=Path, required=True, help="Output JSON path")
    parser.add_argument("--control", action="store_true", help="Run a shuffled-signature control")
    parser.add_argument(
        "--data-dir",
        type=Path,
        default=Path(__file__).parent / "data",
        help="Directory containing reference genomes and signature tables (default: script directory / data)",
    )
    args = parser.parse_args()

    if args.signatures:
        signatures = load_signatures(args.signatures)
    else:
        builder = (
            ChemistrySignatureBuilder()
            if args.builder == "chemistry"
            else PlaceholderSignatureBuilder()
        )
        signatures = builder.build()

    fasta_path = args.fasta
    if fasta_path is None:
        fasta_path = args.data_dir / "ecoli_k12.fna.gz"
        if not fasta_path.exists():
            fasta_path = args.data_dir / "ecoli_k12_mg1655.fna.gz"
        download_default_genome(fasta_path)
    elif not fasta_path.exists():
        print(f"Error: FASTA not found: {fasta_path}")
        return 1

    print(f"[*] Parsing {fasta_path} ...")
    codon_counts: Counter = Counter()
    total_bases = 0
    for seq in parse_fasta(fasta_path):
        codon_counts.update(count_codons(seq))
        total_bases += len(seq)

    if not codon_counts:
        print("Error: no valid codons parsed.")
        return 1

    num_codons = sum(codon_counts.values())
    print(f"[+] Parsed {num_codons:,} valid codons from {total_bases:,} bases")

    results = {
        "fasta": str(fasta_path),
        "signature_source": str(args.signatures) if args.signatures else f"{args.builder} builder",
        "num_codons": num_codons,
        "framework_test": evaluate(signatures, codon_counts),
    }

    if args.control:
        results["control_test"] = evaluate(signatures, codon_counts, control=True)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "w") as f:
        json.dump(results, f, indent=2)

    print(f"\nResults written to {args.output}")
    ft = results["framework_test"]
    print(
        f"  Stop codons:      {ft['stop']['tp']}/{ft['stop']['tp']+ft['stop']['fn']} "
        f"recall={ft['stop']['recall']:.3f}  precision={ft['stop']['precision']:.3f}  "
        f"p={ft['stop']['p_value']:.3e}"
    )
    print(
        f"  Hydrophobic:      {ft['hydrophobic']['tp']}/{ft['hydrophobic']['tp']+ft['hydrophobic']['fn']} "
        f"recall={ft['hydrophobic']['recall']:.3f}  precision={ft['hydrophobic']['precision']:.3f}  "
        f"p={ft['hydrophobic']['p_value']:.3e}"
    )
    if args.control:
        ct = results["control_test"]
        print("\nControl (randomized signatures):")
        print(
            f"  Stop recall={ct['stop']['recall']:.3f}  "
            f"Hydrophobic recall={ct['hydrophobic']['recall']:.3f}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
