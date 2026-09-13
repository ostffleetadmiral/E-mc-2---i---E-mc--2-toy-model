#!/bin/bash
# run_tests.sh — Run all Qstar test specs sequentially.
# Workaround for Zig 0.13.0 --listen protocol deadlock when running many test binaries.
set -e

cd "$(dirname "$0")/.."

ZIG=${ZIG:-zig}
PASS=0
FAIL=0
FAILED_TESTS=()

run_test() {
    local label="$1"
    shift
    local result
    result=$("$@" 2>&1)
    if echo "$result" | grep -q "All .* tests passed"; then
        echo "PASS: $label"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $label"
        echo "$result" | tail -5
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$label")
    fi
}

# === Standalone tests (no module deps) ===
for f in \
    src/fixed_point.zig \
    src/lattice.zig \
    src/metacognition_engine.zig \
    src/trivium.zig \
    src/codon.zig \
    src/memory.zig \
    src/sampling.zig \
    src/compress.zig \
    src/collapse.zig \
    src/qr_nest.zig \
    src/p2p_types.zig \
    src/nat.zig \
    src/webrtc.zig \
    src/transport_p2p.zig \
    src/transport_wifi.zig \
    src/transport_quine.zig \
    src/transport_polyglot.zig \
    src/transport_stega.zig \
    src/transport_qr.zig \
    src/transport_audio.zig \
    src/transport_cassette.zig \
    src/transport_convert.zig \
    src/transport_lora.zig \
    src/transport_optar.zig \
    src/transport_paperback.zig \
    src/transport_video.zig \
; do
    run_test "$f" $ZIG test "$f"
done

# === Tests with fixed_point dep ===
for f in \
    src/cognitive_cloud.zig \
    src/quadrivium.zig \
    src/perception.zig \
    src/face_sync.zig \
    src/voice_codec.zig \
    src/holographic.zig \
    src/mesh.zig \
; do
    run_test "$f" $ZIG test --dep fixed_point -Mroot="$f" -Mfixed_point=src/fixed_point.zig
done

# === Tests with multiple deps ===
run_test "src/knowledge_graph.zig" $ZIG test --dep fixed_point --dep lattice -Mroot=src/knowledge_graph.zig -Mfixed_point=src/fixed_point.zig -Mlattice=src/lattice.zig
run_test "src/relay_router.zig" $ZIG test --dep p2p_types -Mroot=src/relay_router.zig -Mp2p_types=src/p2p_types.zig
run_test "src/virtual_transport.zig" $ZIG test --dep mesh -Mroot=src/virtual_transport.zig -Mmesh=src/mesh.zig
run_test "src/prompt_generator.zig" $ZIG test --dep ollama_client -Mroot=src/prompt_generator.zig -Mollama_client=src/ollama_client.zig

# === Tests requiring full agent module ===
# These hang due to generateLongForm being CPU-intensive.
# Run manually with: zig build test-turing / zig build test-agent
# run_test "src/turing_test.zig (via zig build test-turing)" $ZIG build test-turing
# run_test "src/agent.zig (via zig build test-agent)" $ZIG build test-agent

# === Summary ===
echo ""
echo "==============================="
echo "Tests passed: $PASS"
echo "Tests failed: $FAIL"
if [ $FAIL -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
echo "All tests passed!"
