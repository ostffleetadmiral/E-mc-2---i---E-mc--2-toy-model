#!/usr/bin/env python3
"""Download reference genomes from NCBI FTP for cross-species validation."""

import os
import urllib.request

GENOMES = {
    "ecoli_k12": {
        "url": (
            "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/005/845/"
            "GCF_000005845.2_ASM584v2/GCF_000005845.2_ASM584v2_genomic.fna.gz"
        ),
        "file": "ecoli_k12.fna.gz",
    },
    "yeast_s288c": {
        "url": (
            "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/146/045/"
            "GCF_000146045.2_R64/GCF_000146045.2_R64_genomic.fna.gz"
        ),
        "file": "yeast_s288c.fna.gz",
    },
    "human_grch38": {
        "url": (
            "https://ftp.ncbi.nlm.nih.gov/genomes/all/GCF/000/001/405/"
            "GCF_000001405.40_GRCh38.p14/GCF_000001405.40_GRCh38.p14_genomic.fna.gz"
        ),
        "file": "human_grch38.fna.gz",
    },
}


def download_genome(name: str, outdir: str = "data") -> str:
    info = GENOMES[name]
    os.makedirs(outdir, exist_ok=True)
    outpath = os.path.join(outdir, info["file"])

    if os.path.exists(outpath):
        print(f"Already have {outpath}")
        return outpath

    print(f"[*] Downloading {name}...")
    print(f"    {info['url']}")
    urllib.request.urlretrieve(info["url"], outpath)
    size_mb = os.path.getsize(outpath) / 1_048_576
    print(f"[+] Saved {outpath} ({size_mb:.2f} MiB)")
    return outpath


if __name__ == "__main__":
    import sys

    names = sys.argv[1:] if len(sys.argv) > 1 else list(GENOMES.keys())
    for name in names:
        if name not in GENOMES:
            print(f"Unknown genome: {name}. Choose from {list(GENOMES.keys())}")
            continue
        download_genome(name)
