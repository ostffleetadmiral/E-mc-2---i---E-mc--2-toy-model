"""Reference-genome download and codon extraction utilities."""

import gzip
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Dict, Iterable

import numpy as np

DEFAULT_GENOME_URL = (
    "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/005/845/"
    "GCF_000005845.2_ASM584v2/GCF_000005845.2_ASM584v2_genomic.fna.gz"
)

# A=0, C=1, G=2, U=3; anything else -> 255 (invalid).
_BASE_MAP = {ord("A"): 0, ord("C"): 1, ord("G"): 2, ord("U"): 3}
_REV_MAP = ["A", "C", "G", "U"]
_INVALID = np.uint8(255)


def download_default_genome(dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        return dest
    print(f"[*] Downloading reference genome from NCBI...\n    {DEFAULT_GENOME_URL}")
    urllib.request.urlretrieve(DEFAULT_GENOME_URL, dest)
    print(f"[+] Saved {dest} ({dest.stat().st_size / 1_048_576:.2f} MiB)")
    return dest


def parse_fasta(path: Path) -> Iterable[str]:
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rt", encoding="ascii", errors="ignore") as f:
        seq_parts = []
        for line in f:
            line = line.strip()
            if line.startswith(">"):
                if seq_parts:
                    yield "".join(seq_parts)
                    seq_parts = []
                continue
            seq_parts.append(line.upper().replace("T", "U"))
        if seq_parts:
            yield "".join(seq_parts)


def valid_codons(seq: str) -> Iterable[str]:
    """Yield all 3-base codons containing only A,U,C,G."""
    for i in range(0, len(seq) - 2, 3):
        c = seq[i : i + 3]
        if c[0] in "AUCG" and c[1] in "AUCG" and c[2] in "AUCG":
            yield c


def _index_to_codon(idx: int) -> str:
    return (
        _REV_MAP[idx & 3]
        + _REV_MAP[(idx >> 2) & 3]
        + _REV_MAP[(idx >> 4) & 3]
    )


_CODON_TABLE = [_index_to_codon(i) for i in range(64)]


def count_codons(seq: str) -> Dict[str, int]:
    """Return a Counter of valid 3-base codons (vectorized for speed)."""
    n = len(seq)
    if n < 3:
        return Counter()

    # Translate characters to numeric codes in one pass.
    arr = np.frombuffer(seq.encode("ascii"), dtype=np.uint8)
    mapped = np.full(arr.shape, _INVALID, dtype=np.uint8)
    for ch, code in _BASE_MAP.items():
        mapped[arr == ch] = code

    # Group bases into consecutive triplets starting at positions 0,3,6,...
    trim = (n // 3) * 3
    mapped = mapped[:trim]
    b0 = mapped[0::3]
    b1 = mapped[1::3]
    b2 = mapped[2::3]

    valid = (b0 <= 3) & (b1 <= 3) & (b2 <= 3)
    idx = b0[valid] + 4 * b1[valid] + 16 * b2[valid]

    counts = np.bincount(idx.astype(np.int64), minlength=64)
    return Counter({codon: int(c) for codon, c in zip(_CODON_TABLE, counts) if c})
