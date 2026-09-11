# Codon DNA → 6D Jordan Algebra Routing Test

**Project:** E=mc²-i-E=mc⁻² (toy-model) — Codon subsystem
**Organization:** Open Sentience Technology Foundation
**License:** CC BY-NC-SA 4.0 (see [../LICENSE](../LICENSE))

This is a dedicated, self-contained test suite for the strongest empirical
claim in the Engineered Universe v6.1 framework: that the 64 RNA codons route
through the dimensional ladder, with stop codons channeling through E2
(phase space) and hydrophobic amino acids channeling through E6 (Jordan mirror).

## Layout

| Path | Purpose |
|------|---------|
| `codon/constants.py` | Base chemistry, genetic code, labels, dimensional ladder |
| `codon/signature.py` | Reconstruct or load the 64-codon signature table |
| `codon/rules.py` | Framework routing rules (stop, hydrophobic, acidic) |
| `codon/genome.py` | Reference-genome download and FASTA parsing |
| `codon/evaluate.py` | Confusion-matrix metrics and falsification controls |
| `harness.py` | Main command-line entry point |
| `run.sh` | Convenience wrapper for *E. coli* |
| `run_cross_species.sh` | Run validation across E. coli, yeast, and human |
| `tools/download_genomes.py` | Download reference genomes from NCBI |
| `tests/test_signature.py` | Unit tests for reconstruction and rules |
| `data/` | Generated signature tables and genomes (created on demand) |
| `results/ncbi/` | Genomic test outputs (created on demand) |

## Quick start

Run against *E. coli* K-12 MG1655:

```bash
cd codon
./run.sh
```

Or directly:

```bash
python3 harness.py --output results/ncbi/codon_routing_test.json --control
```

With a custom genome (DNA or RNA FASTA, `.gz` accepted):

```bash
python3 harness.py --genome /path/to/genome.fna.gz --output results/ncbi/my_genome.json --control
```

## Signature builders

Two builders are provided because the framework manuscripts define the
base-chemistry coordinate formulas but do not give the exact base→dimension
mapping.

- **`ChemistrySignatureBuilder`** (default): derives signatures from base
  chemistry using van der Waals radii, a 6-bit base-4 qubit encoding, and
  amino-acid class routing. DNA input (with `T`) is normalized to RNA (`U`).
- **`PlaceholderSignatureBuilder`**: rule-consistent table built from the
  standard genetic-code labels. It reproduces the framework's claimed
  stop/hydrophobic accuracy and is kept as a fallback.

To use the placeholder builder:

```bash
python3 harness.py --builder placeholder --output results/ncbi/codon_placeholder.json --control
```

## Tests

```bash
python3 -m pytest tests/
# or
python3 -m unittest discover -s tests
```

The unit tests verify:
- The chemistry-derived qubit encoding matches the 6-bit base-4 specification.
- The surface-area formula is consistent with van der Waals radii.
- Both builders satisfy the stop/hydrophobic rules.
- All 64 codons are present in both builders.

## Cross-species validation

Download yeast and human reference genomes and run the test on all three
species:

```bash
./run_cross_species.sh
```

This produces `results/ncbi/{ecoli_k12,yeast_s288c,human_grch38}_routing.json`
and prints a summary table.

## Output format

`results/ncbi/codon_routing_test.json` contains:
- `framework_test`: stop/hydrophobic accuracy, precision, recall, binomial p-values.
- `control_test`: same metrics after shuffling signatures (if `--control` was used).
- `predicted_type_counts`: per-class codon usage in the genome.

## Citation

The underlying framework is described in:
- `../Foundation/engineered_universe_v6.1.txt`
- `../Foundation/appendix_e_supplemental_math.txt`
