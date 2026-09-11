#!/usr/bin/env bash
# Convenience wrapper for the codon routing harness.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${PROJECT_DIR}/results/ncbi"
FASTA="${1:-}"

mkdir -p "${OUTDIR}"

if [[ -n "${FASTA}" ]]; then
    python3 "${PROJECT_DIR}/harness.py" \
        --genome "${FASTA}" \
        --output "${OUTDIR}/codon_routing_test.json" \
        --control
else
    python3 "${PROJECT_DIR}/harness.py" \
        --output "${OUTDIR}/codon_routing_test.json" \
        --control
fi

echo "[+] Codon routing test complete. Results in ${OUTDIR}/codon_routing_test.json"
