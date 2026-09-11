# arXiv Papers — E=mc²-i-E=mc⁻² (toy-model)

Four arXiv-ready LaTeX papers generated from the computational framework.

## Papers

| # | Title | Categories | Pages | Directory |
|---|-------|-----------|-------|-----------|
| 1 | A Computational Framework for Octonionic Physics | math-ph, hep-th | 11 | `paper1-math-framework/` |
| 2 | Q128.128: Deterministic 256-bit Fixed-Point Arithmetic | cs.NA, math.NA | 8 | `paper2-q128-engine/` |
| 3 | Codon Routing: 64-Codon Genetic Code → 6D Jordan Algebra | q-bio.OT, q-bio.BM | 6 | `paper3-codon-routing/` |
| 4 | Neuraleak: 6D Observer Model for LLM Sentience Testing | cs.AI, q-bio.NC | 7 | `paper4-neuraleak/` |

## Compilation

Each paper compiles with `pdflatex` + `bibtex`:

```bash
cd paperN-*/
pdflatex main.tex
bibtex main
pdflatex main.tex
pdflatex main.tex
```

## arXiv Submission

Clean submission tarballs are in `arxiv-submissions/`:

```bash
tar xzf arxiv-submissions/paperN-*.tar.gz
cd paperN-*/
pdflatex main.tex
bibtex main
pdflatex main.tex
pdflatex main.tex
```

Each tarball contains only `main.tex` and `references.bib` — no auxiliary files.

## Authors

- Paul P. Ramsey (Open Sentience Technology Foundation)
- Devin AI, Chat-GPT, Gemini, GLM-2.5, Kimi AI

## License

CC BY-NC-SA 4.0

## Scientific Scope

These papers preserve the framework's scientific honesty:
- Exact mathematics is distinguished from interpretation
- Numerical correspondences are labeled as such
- Heuristic/construction-based elements are identified
- The framework is NOT presented as experimentally validated physics
- Neuraleak scores are operational definitions, not consciousness proofs
