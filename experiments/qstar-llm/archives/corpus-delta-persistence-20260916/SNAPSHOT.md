Corpus delta-append persistence + 2.9GB corpus rebuild.

What changed:
- agent.zig: session_learned delta buffer, flushCorpusDelta() watermark API,
  trim gating so bounded-window eviction never discards unflushed delta.
- training.zig: saveCorpusToFile now appends session delta (never truncates);
  resolveCorpusDeltaPath() routes .qsc sources to "<base>.learned.txt"
  sidecars; loadCorpusSidecar(); countSentencesInFile(); trainBatchHybrid
  falls back to OpenAI when Ollama is unavailable; partitionFailures bounds
  fix + deep-copy ownership fix; analyzeFailures deinit fix.
- main.zig: corpus stream --out; file-level vs window sentence reporting;
  persistCorpusDelta helper; sidecar auto-load in chat/run/serve.
- build.zig: test-training step.

Verified:
- test-training 31/31, agent 173/173, main 29/29, heartbeat 9/9,
  server 19/19, turing 6/6.
- Live scratch run: 2-sentence fixture -> +112 appended, sentinels intact.
- Corpus rebuilt: qstar_corpus_full.qsc -> 2,919,253,227 B / 65,787,307
  lines restored to basic/qstar-llm/qstar_corpus.txt (symlink target).

Known: onnx_runtime OrtApiBase field-order abort is a pre-existing
environmental ABI mismatch (ONNX Runtime 1.23.2), unrelated.
