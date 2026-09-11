"""Physical constants and biological lookup tables for the codon routing test."""

import math

PHI = (1.0 + math.sqrt(5.0)) / 2.0
PI = math.pi

# Dimensional ladder coordinates c(k) from Engineered Universe v6.1 / Appendix E.
LADDER_COORDS = [
    0.0,          # E0
    PHI,          # E1
    PI,           # E2
    21.0 / 4.0,   # E3
    21.0 / 2.0,   # E4
    21.0,         # E5
    42.0,         # E6
    21.0,         # E7
]

# Base chemistry: mw (g/mol), rings, hbonds, atoms, N, O.
# Values are taken from Appendix E.3 of the framework manuscripts.
BASES = {
    "A": {"mw": 347.2, "rings": 2, "hbonds": 2, "atoms": 15, "N": 5, "O": 1},
    "U": {"mw": 324.2, "rings": 1, "hbonds": 2, "atoms": 13, "N": 2, "O": 3},
    "G": {"mw": 363.2, "rings": 2, "hbonds": 3, "atoms": 16, "N": 5, "O": 2},
    "C": {"mw": 323.2, "rings": 1, "hbonds": 3, "atoms": 13, "N": 3, "O": 2},
}

# Physical parameters used by the chemistry-derived signature builder.
# Radii are in Angstrom; they are converted to nanometers internally.
BASE_CHEMISTRY = {
    "A": {"vdw_radius": 1.88, "bond_length": 1.52, "electronegativity": 2.55},
    "C": {"vdw_radius": 1.75, "bond_length": 1.47, "electronegativity": 3.04},
    "G": {"vdw_radius": 1.96, "bond_length": 1.56, "electronegativity": 3.44},
    "U": {"vdw_radius": 1.80, "bond_length": 1.48, "electronegativity": 3.50},
    "T": {"vdw_radius": 1.80, "bond_length": 1.48, "electronegativity": 3.50},
}

BACKBONE_RADIUS_NM = 0.34

# Standard genetic code (RNA alphabet).
GENETIC_CODE = {
    "UUU": "F", "UUC": "F", "UUA": "L", "UUG": "L",
    "UCU": "S", "UCC": "S", "UCA": "S", "UCG": "S",
    "UAU": "Y", "UAC": "Y", "UAA": "STOP", "UAG": "STOP",
    "UGU": "C", "UGC": "C", "UGA": "STOP", "UGG": "W",
    "CUU": "L", "CUC": "L", "CUA": "L", "CUG": "L",
    "CCU": "P", "CCC": "P", "CCA": "P", "CCG": "P",
    "CAU": "H", "CAC": "H", "CAA": "Q", "CAG": "Q",
    "CGU": "R", "CGC": "R", "CGA": "R", "CGG": "R",
    "AUU": "I", "AUC": "I", "AUA": "I", "AUG": "M",
    "ACU": "T", "ACC": "T", "ACA": "T", "ACG": "T",
    "AAU": "N", "AAC": "N", "AAA": "K", "AAG": "K",
    "AGU": "S", "AGC": "S", "AGA": "R", "AGG": "R",
    "GUU": "V", "GUC": "V", "GUA": "V", "GUG": "V",
    "GCU": "A", "GCC": "A", "GCA": "A", "GCG": "A",
    "GAU": "D", "GAC": "D", "GAA": "E", "GAG": "E",
    "GGU": "G", "GGC": "G", "GGA": "G", "GGG": "G",
}

# External ground-truth labels used for actual class membership.
# These follow the chemistry-derived routing classes in the framework:
#   hydrophobic: F, L, I, M, V, P, A, W, G
#   polar uncharged: S, T, C, Y, N, Q
#   acidic: D, E
#   basic: K, R, H
#   stop: UAA, UAG, UGA
CODON_LABELS = {
    # hydrophobic
    "UUU": "hydrophobic", "UUC": "hydrophobic", "UUA": "hydrophobic", "UUG": "hydrophobic",
    "UGG": "hydrophobic",
    "CUU": "hydrophobic", "CUC": "hydrophobic", "CUA": "hydrophobic", "CUG": "hydrophobic",
    "CCU": "hydrophobic", "CCC": "hydrophobic", "CCA": "hydrophobic", "CCG": "hydrophobic",
    "AUU": "hydrophobic", "AUC": "hydrophobic", "AUA": "hydrophobic", "AUG": "hydrophobic",
    "GUU": "hydrophobic", "GUC": "hydrophobic", "GUA": "hydrophobic", "GUG": "hydrophobic",
    "GCU": "hydrophobic", "GCC": "hydrophobic", "GCA": "hydrophobic", "GCG": "hydrophobic",
    "GGU": "hydrophobic", "GGC": "hydrophobic", "GGA": "hydrophobic", "GGG": "hydrophobic",
    # polar uncharged
    "UCU": "polar", "UCC": "polar", "UCA": "polar", "UCG": "polar",
    "UGU": "polar", "UGC": "polar",
    "UAU": "polar", "UAC": "polar",
    "ACU": "polar", "ACC": "polar", "ACA": "polar", "ACG": "polar",
    "AAU": "polar", "AAC": "polar", "AGU": "polar", "AGC": "polar",
    "CAA": "polar", "CAG": "polar",
    # acidic
    "GAU": "acidic", "GAC": "acidic", "GAA": "acidic", "GAG": "acidic",
    # basic
    "CAU": "other", "CAC": "other", "CGU": "other", "CGC": "other",
    "CGA": "other", "CGG": "other", "AAA": "other", "AAG": "other",
    "AGA": "other", "AGG": "other",
    # stop
    "UAA": "stop", "UAG": "stop", "UGA": "stop",
}
