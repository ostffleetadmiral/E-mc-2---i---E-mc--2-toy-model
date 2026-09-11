# arXiv Papers — E=mc²-i-E=mc⁻² (toy-model)

**DOI:** [10.5281/zenodo.22715355](https://doi.org/10.5281/zenodo.22715355)

Four arXiv-ready LaTeX papers generated from the computational framework.

## Papers and arXiv Submission Categories

| # | Title | Primary Category | Cross-list | Pages | Directory |
|---|-------|-----------------|------------|-------|-----------|
| 1 | A Computational Framework for Octonionic Physics | **math-ph** | hep-th | 11 | `paper1-math-framework/` |
| 2 | Q128.128: Deterministic 256-bit Fixed-Point Arithmetic | **math.NA** | cs.MS | 8 | `paper2-q128-engine/` |
| 3 | Codon Routing: 64-Codon Genetic Code → 6D Jordan Algebra | **q-bio.OT** | q-bio.BM | 6 | `paper3-codon-routing/` |
| 4 | Neuraleak: 6D Observer Model for LLM Sentience Testing | **cs.AI** | q-bio.NC | 7 | `paper4-neuraleak/` |

### How to submit each paper to arXiv

On the arXiv submit page (https://arxiv.org/submit), you first choose a subject
group (archive), then a category within it. Here is exactly where to find each
category in the arXiv taxonomy:

1. **Paper 1 — Octonionic Physics Framework**
   - Primary: `math-ph` — listed under **Physics → Mathematical Physics**
     (Note: `math-ph` is in the Physics group, NOT the Mathematics group. `math.MP` is an alias for `math-ph`.)
   - Cross-list: `hep-th` — listed under **Physics → High Energy Physics - Theory**
   - Rationale: The paper is primarily mathematical physics (octonions, Jordan algebras, E8), with secondary relevance to theoretical high-energy physics (SO(10), Pati-Salam, GUT structures).

2. **Paper 2 — Q128.128 Deterministic Arithmetic**
   - Primary: `math.NA` — listed under **Mathematics → Numerical Analysis**
     (Note: `cs.NA` is an alias for `math.NA` — they are the same category. You cannot cross-list them together.)
   - Cross-list: `cs.MS` — listed under **Computer Science → Mathematical Software**
   - Rationale: The paper is primarily numerical analysis (deterministic fixed-point arithmetic, error bounds, RNE rounding), with secondary relevance as mathematical software (WASM, GPU compute, polyglot runtime).

3. **Paper 3 — Codon Routing**
   - Primary: `q-bio.OT` — listed under **Quantitative Biology → Other Quantitative Biology**
   - Cross-list: `q-bio.BM` — listed under **Quantitative Biology → Biomolecules**
   - Rationale: The paper maps the genetic code to algebraic structures, which is a non-standard quantitative biology topic (hence "Other"), with secondary relevance to biomolecules (DNA, RNA, codons).

4. **Paper 4 — Neuraleak**
   - Primary: `cs.AI` — listed under **Computer Science → Artificial Intelligence**
   - Cross-list: `q-bio.NC` — listed under **Quantitative Biology → Neurons and Cognition**
   - Rationale: The paper is primarily an AI/LLM testing framework, with secondary relevance to computational neuroscience/cognition.

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
