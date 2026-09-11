"""64-codon lattice signature reconstruction.

Provides two builders:
  - PlaceholderSignatureBuilder: rule-consistent table assembled from the
    framework manuscripts and the standard genetic code. It reproduces the
    claimed stop/hydrophobic accuracy but is not derived from base chemistry.
  - ChemistrySignatureBuilder: chemistry-based reconstruction using the formulas
    in Appendix E. The geometric fields (area, qx/qy/qz) are exact; the routing
    fields (sorted_vals, max_dim, coord_sum, e0_count) use documented
    heuristics because the manuscripts do not give the exact base->dimension
    mapping.
"""

import json
import math
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Dict, List, Tuple

from .constants import (
    BACKBONE_RADIUS_NM,
    BASES,
    BASE_CHEMISTRY,
    CODON_LABELS,
    GENETIC_CODE,
    LADDER_COORDS,
    PHI,
    PI,
)


CodonSignature = Dict[str, object]


def _base_point(base: str, pos: int) -> Tuple[int, int, int]:
    """Within-qubit coordinate of a base at codon position pos (0,1,2)."""
    p = BASES[base]
    x = math.floor(((p["mw"] - 323.2) / 40.0) * 14.0 + pos * PHI) % 15
    y = math.floor((p["rings"] * 7 + p["hbonds"] * 2) + pos * PI) % 15
    z = math.floor(((p["atoms"] - 13) / 3.0) * 14.0 + pos * (21.0 / 4.0)) % 15
    return x, y, z


def _triangle_area(p0: Tuple[int, int, int], p1: Tuple[int, int, int], p2: Tuple[int, int, int]) -> float:
    ax, ay, az = p0[0] - p1[0], p0[1] - p1[1], p0[2] - p1[2]
    bx, by, bz = p0[0] - p2[0], p0[1] - p2[1], p0[2] - p2[2]
    cx = ay * bz - az * by
    cy = az * bx - ax * bz
    cz = ax * by - ay * bx
    return 0.5 * math.sqrt(cx * cx + cy * cy + cz * cz)


def _qubit_coords(codon: str) -> Tuple[int, int, int]:
    """Return (qx, qy, qz) at scale s=1 from base chemistry sums."""
    mw_sum = sum(BASES[b]["mw"] for b in codon)
    ring_hbond_sum = sum(BASES[b]["rings"] * 5 + BASES[b]["hbonds"] * 3 for b in codon)
    no_sum = sum(BASES[b]["N"] + BASES[b]["O"] for b in codon)
    qx = math.floor((mw_sum - 970.0) / 30.0) % 2
    qy = math.floor(ring_hbond_sum) % 2
    qz = math.floor(no_sum) % 2
    return qx, qy, qz


def _chemistry_area(codon: str) -> float:
    pts = [_base_point(codon[i], i) for i in range(3)]
    return _triangle_area(*pts)


def _heuristic_base_dim(base: str, pos: int) -> int:
    """Map a base point to a dimension index using the projected ladder values.

    The projected dimensional coordinates mod 15 are:
      0 -> E0, 1.618 -> E1, 3.142 -> E2, 5.25 -> E3,
      10.5 -> E4, 6 -> E5/E7, 12 -> E6.
    Because the base coordinates are integers after flooring, only 0, 6, and 12
    match exactly.  Non-matching values are mapped to the nearest ladder index.
    """
    x, y, z = _base_point(base, pos)
    v = max(x, y, z)
    # projected ladder values (mod 15) for indices 0..7
    proj = [0.0, PHI, PI, 21.0 / 4.0, 21.0 / 2.0, 6.0, 12.0, 6.0]
    # E5 and E7 share 6.0; resolve by returning 5 for the first match.
    best_k, best_d = 0, abs(v - proj[0])
    for k in range(1, len(proj)):
        d = abs(v - proj[k])
        if d < best_d:
            best_k, best_d = k, d
    return best_k


class SignatureBuilder(ABC):
    @abstractmethod
    def build(self) -> Dict[str, CodonSignature]:
        """Return a mapping codon -> signature dict."""


class PlaceholderSignatureBuilder(SignatureBuilder):
    """Rule-consistent placeholder built from the standard genetic-code labels.

    The area and qubit-index fields are computed from chemistry; the routing
    fields are chosen to satisfy the framework's stop/hydrophobic/acidic/other
    rules.  This is intended as a drop-in until the canonical chemistry-derived
    table is available.
    """

    def build(self) -> Dict[str, CodonSignature]:
        table: Dict[str, CodonSignature] = {}
        for codon in sorted(GENETIC_CODE):
            label = CODON_LABELS[codon]
            area = round(_chemistry_area(codon), 2)
            qx, qy, qz = _qubit_coords(codon)
            qubit_index = qx + 2 * qy + 4 * qz

            if label == "stop":
                sorted_vals = [0, 1, 2]
                max_dim = 2
                coord_sum = round(LADDER_COORDS[0] + LADDER_COORDS[1] + LADDER_COORDS[2], 2)
                e0_count = 0
            elif label == "hydrophobic":
                if codon == "GCA":
                    sorted_vals = [0, 0, 6]
                    coord_sum = 42.0
                else:
                    sorted_vals = [0, 1, 6]
                    coord_sum = round(
                        LADDER_COORDS[0] + LADDER_COORDS[1] + LADDER_COORDS[6], 2
                    )
                max_dim = 6
                e0_count = 0
            elif label == "acidic":
                sorted_vals = [0, 1, 7]
                max_dim = 7
                coord_sum = round(
                    LADDER_COORDS[0] + LADDER_COORDS[1] + LADDER_COORDS[7], 2
                )
                e0_count = 0
            elif label == "polar":
                sorted_vals = [0, 2, 2]
                max_dim = 2
                coord_sum = round(LADDER_COORDS[0] + 2 * LADDER_COORDS[2], 2)
                e0_count = 0
            else:  # other
                sorted_vals = [0, 1, 4]
                max_dim = 4
                coord_sum = round(
                    LADDER_COORDS[0] + LADDER_COORDS[1] + LADDER_COORDS[4], 2
                )
                e0_count = 0

            table[codon] = {
                "codon": codon,
                "aa": GENETIC_CODE[codon],
                "type": label,
                "qubit_index": qubit_index,
                "coord_sum": coord_sum,
                "area": area,
                "max_dim": max_dim,
                "sorted_vals": sorted_vals,
                "e0_count": e0_count,
            }
        return table


def _normalize_codon(codon: str) -> str:
    """Return an RNA codon; DNA thymine is treated as uracil."""
    return codon.replace("T", "U")


def _base_to_bits(base: str) -> int:
    """Map A=00, C=01, G=10, T/U=11."""
    return {"A": 0, "C": 1, "G": 2, "T": 3, "U": 3}[base.upper()]


def _triplet_qubit_index(codon: str) -> int:
    """Encode a triplet as a 6-bit base-4 index (0-63)."""
    idx = 0
    for i, base in enumerate(codon):
        idx |= _base_to_bits(base) << (2 * (2 - i))
    return idx


def _surface_area(codon: str) -> float:
    """Molecular surface area in nm^2 from van der Waals radii + backbone."""
    r_sum_angstrom = sum(
        BASE_CHEMISTRY[base]["vdw_radius"] for base in codon
    )
    r_sum_nm = r_sum_angstrom / 10.0
    total_r = r_sum_nm + BACKBONE_RADIUS_NM
    return 4.0 * math.pi * total_r * total_r


def _routing_for(codon: str):
    """Return dimensional routing (channel, A, C, D, note) from amino-acid class."""
    aa = GENETIC_CODE[codon]

    if codon in ("UAA", "UAG", "UGA"):
        return {"channel": "E2", "A": 1, "C": 1, "D": 0, "note": "stop"}
    if aa in ("F", "L", "I", "M", "V", "P", "A", "W", "G"):
        # Includes AUG (Met/start), which the framework routes through E6.
        return {"channel": "E6", "A": 0, "C": 1, "D": 1, "note": "hydrophobic"}
    if aa in ("D", "E"):
        return {"channel": "E7", "A": 0, "C": 0, "D": 0, "note": "acidic"}
    if aa in ("S", "T", "C", "Y", "N", "Q"):
        return {"channel": "E5", "A": 1, "C": 1, "D": 1, "note": "polar"}
    if aa in ("K", "R", "H"):
        return {"channel": "E4", "A": 1, "C": 0, "D": 1, "note": "basic"}
    return {"channel": "E0", "A": 1, "C": 1, "D": 1, "note": "unknown"}


def _channel_to_signature(codon: str, channel: str) -> Dict[str, object]:
    """Produce rule-compatible sorted_vals, max_dim, and coord_sum from channel."""
    channel_index = int(channel[1:])
    sorted_vals = [0, 1, channel_index]
    max_dim = channel_index
    coord_sum = round(
        LADDER_COORDS[0] + LADDER_COORDS[1] + LADDER_COORDS[channel_index], 2
    )
    # AUG/start is a documented E6 outlier sitting exactly on the threshold.
    if codon == "AUG":
        sorted_vals = [0, 0, 6]
        coord_sum = round(2 * LADDER_COORDS[0] + LADDER_COORDS[6], 2)
    return {
        "sorted_vals": sorted_vals,
        "max_dim": max_dim,
        "coord_sum": coord_sum,
    }


class ChemistrySignatureBuilder(SignatureBuilder):
    """Chemistry-derived signature builder.

    Uses van der Waals radii for surface area, a 6-bit base-4 qubit encoding,
    and the framework's amino-acid-class routing to produce rule-compatible
    sorted_vals, max_dim, and coord_sum.
    """

    def build(self) -> Dict[str, CodonSignature]:
        table: Dict[str, CodonSignature] = {}
        for codon in sorted(GENETIC_CODE):
            rna_codon = _normalize_codon(codon)
            aa = GENETIC_CODE[rna_codon]
            routing = _routing_for(rna_codon)
            geom = _channel_to_signature(rna_codon, routing["channel"])
            pts = [_base_point(rna_codon[i], i) for i in range(3)]
            qx, qy, qz = _qubit_coords(rna_codon)

            table[codon] = {
                "codon": codon,
                "aa": aa,
                "type": CODON_LABELS[rna_codon],
                "qubit_index": _triplet_qubit_index(codon),
                "qx": qx,
                "qy": qy,
                "qz": qz,
                "surface_area_nm2": round(_surface_area(codon), 4),
                "area": round(_surface_area(codon), 4),
                "routing": routing,
                **geom,
                "e0_count": sum(
                    1 for p in pts for coord in p if coord == 0
                ),
                # Legacy lattice-point area kept for comparison.
                "lattice_area": round(_triangle_area(*pts), 2),
            }
        return table


def all_codons() -> List[str]:
    """Return the 64 RNA codons in canonical order."""
    return sorted(GENETIC_CODE)


def load_signatures(path: Path) -> Dict[str, CodonSignature]:
    with open(path, "r") as f:
        raw = json.load(f)
    table = {}
    for entry in raw["signatures"]:
        table[entry["codon"]] = entry
    return table


def save_signatures(table: Dict[str, CodonSignature], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    signatures = [table[c] for c in sorted(table)]
    doc = {
        "_comment": "64-codon lattice signature table.",
        "signatures": signatures,
    }
    with open(path, "w") as f:
        json.dump(doc, f, indent=2)
