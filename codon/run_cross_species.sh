#!/usr/bin/env bash
# Cross-species codon routing validation: E. coli, yeast, human.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

mkdir -p results/ncbi

# Download genomes.
python3 tools/download_genomes.py ecoli_k12 yeast_s288c human_grch38

# Run tests.
for species in ecoli_k12 yeast_s288c human_grch38; do
    echo "=== Testing ${species} ==="
    python3 harness.py \
        --genome "data/${species}.fna.gz" \
        --builder chemistry \
        --output "results/ncbi/${species}_routing.json" \
        --control
done

# Aggregate results.
python3 - <<'PY'
import json
import glob

fmt = "{:<15} {:<12} {:<12} {:<16} {:<16} {:<12} {:<12}"
print(fmt.format(
    "Species", "Stop Rec", "Stop Prec",
    "Hydro Rec", "Hydro Prec",
    "Ctrl Stop", "Ctrl Hydro"
))
print("-" * 100)
for path in sorted(glob.glob("results/ncbi/*_routing.json")):
    species = path.split("/")[-1].replace("_routing.json", "")
    with open(path) as f:
        data = json.load(f)
    fw = data["framework_test"]
    ctrl = data["control_test"]
    print(fmt.format(
        species,
        f"{fw['stop']['recall']:.3f}",
        f"{fw['stop']['precision']:.3f}",
        f"{fw['hydrophobic']['recall']:.3f}",
        f"{fw['hydrophobic']['precision']:.3f}",
        f"{ctrl['stop']['recall']:.3f}",
        f"{ctrl['hydrophobic']['recall']:.3f}",
    ))
PY
