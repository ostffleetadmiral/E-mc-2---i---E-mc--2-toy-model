"""Evaluation metrics and falsification controls for codon routing tests."""

import math
import random
from collections import Counter
from typing import Dict, Mapping

from scipy import stats

from .constants import CODON_LABELS, GENETIC_CODE
from .rules import predicts_hydrophobic, predicts_stop
from .signature import CodonSignature


def _binomial_p(k: int, n: int, p: float) -> float:
    if n == 0 or p <= 0 or p >= 1:
        return 1.0
    mean = n * p
    if n > 1000:
        z = (k - mean) / math.sqrt(n * p * (1 - p))
        return 2.0 * (1.0 - stats.norm.cdf(abs(z)))
    p_obs = stats.binom.cdf(k, n, p)
    p_tail = min(p_obs, 1.0 - p_obs)
    return 2.0 * p_tail


def _metrics_from_counts(
    counts: Mapping[str, int],
    actual_fn,
    pred_fn,
    signatures: Dict[str, CodonSignature],
) -> Dict[str, float]:
    tp = fp = tn = fn = 0
    for codon, n in counts.items():
        entry = signatures.get(codon)
        if entry is None:
            continue
        actual = actual_fn(codon)
        pred = pred_fn(entry)
        if actual and pred:
            tp += n
        elif pred and not actual:
            fp += n
        elif not actual and not pred:
            tn += n
        else:
            fn += n
    total = tp + fp + tn + fn
    return {
        "n": total,
        "tp": tp,
        "fp": fp,
        "tn": tn,
        "fn": fn,
        "accuracy": (tp + tn) / total if total else 0.0,
        "precision": tp / (tp + fp) if (tp + fp) else 0.0,
        "recall": tp / (tp + fn) if (tp + fn) else 0.0,
    }


def evaluate(
    signatures: Dict[str, CodonSignature],
    codon_counts: Mapping[str, int],
    control: bool = False,
    seed: int = 42,
) -> Dict:
    if control:
        rng = random.Random(seed)
        sig_items = list(signatures.items())
        shuffled = rng.sample(sig_items, len(sig_items))
        signatures = {
            orig_codon: sig_dict
            for (orig_codon, _), (_, sig_dict) in zip(sig_items, shuffled)
        }

    stop = _metrics_from_counts(
        codon_counts,
        lambda c: GENETIC_CODE[c] == "STOP",
        predicts_stop,
        signatures,
    )
    stop["p_value"] = _binomial_p(stop["tp"], stop["tp"] + stop["fn"], 3 / 64)

    hydro = _metrics_from_counts(
        codon_counts,
        lambda c: CODON_LABELS[c] == "hydrophobic",
        predicts_hydrophobic,
        signatures,
    )
    hydro["p_value"] = _binomial_p(hydro["tp"], hydro["tp"] + hydro["fn"], 18 / 64)

    pred_counts: Dict[str, int] = {}
    for codon, n in codon_counts.items():
        entry = signatures.get(codon)
        if entry is None:
            continue
        label = (
            "stop"
            if predicts_stop(entry)
            else "hydrophobic"
            if predicts_hydrophobic(entry)
            else entry.get("type", "other")
        )
        pred_counts[label] = pred_counts.get(label, 0) + n

    return {
        "num_codons": sum(codon_counts.values()),
        "stop": stop,
        "hydrophobic": hydro,
        "predicted_type_counts": pred_counts,
        "control": control,
    }
