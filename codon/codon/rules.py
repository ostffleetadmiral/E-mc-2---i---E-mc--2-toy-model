"""Framework routing rules applied to codon signatures."""

from .signature import CodonSignature


def predicts_stop(entry: CodonSignature) -> bool:
    """E2 phase-space stop-codon rule."""
    sv = tuple(entry["sorted_vals"])
    return sv == (0, 1, 2) or (sv == (1, 2, 2) and entry["area"] > 30)


def predicts_hydrophobic(entry: CodonSignature) -> bool:
    """E6 Jordan-mirror hydrophobic rule."""
    return entry["coord_sum"] > 42 and entry["max_dim"] >= 6


def predicts_acidic(entry: CodonSignature) -> bool:
    """E7 color-charge acidic rule (max_dim reaches E7)."""
    return entry["max_dim"] >= 7


def predicted_label(entry: CodonSignature) -> str:
    if predicts_stop(entry):
        return "stop"
    if predicts_hydrophobic(entry):
        return "hydrophobic"
    if predicts_acidic(entry):
        return "acidic"
    return "other"
