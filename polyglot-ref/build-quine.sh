#!/bin/bash
# build-quine.sh — Build and test the FANO-1 + space-agent quine integration
#
# This script:
#   1. Builds all Zig binaries (engine, holo-fs, quine-server)
#   2. Runs all Zig tests
#   3. Verifies the quine server is functional
#   4. Checks space-agent API endpoint exists
#   5. Verifies the quine page shell is present
#
# Usage: ./build-quine.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
ZIG="${ZIG:-/home/admpaul/.local/bin/zig}"

echo "=== FANO-1 Space-Agent Quine Build ==="
echo ""

# ─── 1. Build and test Zig engine ─────────────────────────────────────

echo "[1/5] Building Zig engine..."
cd "$PROJECT_ROOT/zig"
$ZIG build || { echo "FAIL: zig build"; exit 1; }
$ZIG build test || { echo "FAIL: zig build test"; exit 1; }
echo "  Engine: PASS"

# ─── 2. Build and test holo-fs ────────────────────────────────────────

echo "[2/5] Building holo-fs..."
cd "$PROJECT_ROOT/holo-fs"
$ZIG build || { echo "FAIL: holo-fs build"; exit 1; }
$ZIG build test || { echo "FAIL: holo-fs test"; exit 1; }
echo "  Holo-FS: PASS"

# ─── 3. Build and test quine server ───────────────────────────────────

echo "[3/5] Building quine server..."
cd "$PROJECT_ROOT/quine-server"
$ZIG build || { echo "FAIL: quine-server build"; exit 1; }
$ZIG build test || { echo "FAIL: quine-server test"; exit 1; }
echo "  Quine Server: PASS"

# ─── 4. Verify quine server functionality ─────────────────────────────

echo "[4/5] Testing quine server..."
cd "$PROJECT_ROOT/quine-server"
./zig-out/bin/quine-server /tmp/quine_build_test.taskpaper 18099 &
QUINE_PID=$!
sleep 2

# Test version endpoint
VERSION=$(echo -e "GET /api/version HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc -w2 127.0.0.1 18099 2>/dev/null)
if echo "$VERSION" | grep -q "FANO-1 Quine Server"; then
    echo "  Version endpoint: PASS"
else
    echo "  Version endpoint: FAIL"
    kill $QUINE_PID 2>/dev/null
    exit 1
fi

# Test save endpoint
SAVE=$(echo -e "POST /api/doc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 25\r\n\r\n{\"content\":\"build test\"}" | nc -w2 127.0.0.1 18099 2>/dev/null)
if echo "$SAVE" | grep -q '"saved":true'; then
    echo "  Save endpoint: PASS"
else
    echo "  Save endpoint: FAIL"
    kill $QUINE_PID 2>/dev/null
    exit 1
fi

# Test load endpoint
LOAD=$(echo -e "GET /api/doc HTTP/1.1\r\nHost: localhost\r\n\r\n" | nc -w2 127.0.0.1 18099 2>/dev/null)
if echo "$LOAD" | grep -q "build test"; then
    echo "  Load endpoint: PASS"
else
    echo "  Load endpoint: FAIL"
    kill $QUINE_PID 2>/dev/null
    exit 1
fi

kill $QUINE_PID 2>/dev/null
wait $QUINE_PID 2>/dev/null || true
echo "  Quine Server Functional: PASS"

# ─── 5. Verify space-agent integration ───────────────────────────────

echo "[5/5] Checking space-agent integration..."

# Check API endpoint
if [ -f "$PROJECT_ROOT/space-agent/server/api/fano_quine.js" ]; then
    echo "  API endpoint (fano_quine.js): PRESENT"
else
    echo "  API endpoint: FAIL"
    exit 1
fi

# Check page shell
if [ -f "$PROJECT_ROOT/space-agent/server/pages/fano_quine.html" ]; then
    echo "  Page shell (fano_quine.html): PRESENT"
else
    echo "  Page shell: FAIL"
    exit 1
fi

# Check that the API endpoint exports the right handlers
if grep -q "export async function get" "$PROJECT_ROOT/space-agent/server/api/fano_quine.js" && \
   grep -q "export async function post" "$PROJECT_ROOT/space-agent/server/api/fano_quine.js"; then
    echo "  API handlers (get/post): PASS"
else
    echo "  API handlers: FAIL"
    exit 1
fi

# Check that the page shell references the API
if grep -q "/api/fano_quine" "$PROJECT_ROOT/space-agent/server/pages/fano_quine.html"; then
    echo "  Page-to-API linkage: PASS"
else
    echo "  Page-to-API linkage: FAIL"
    exit 1
fi

echo ""
echo "=== FANO-1 Space-Agent Quine Build Complete ==="
echo ""
echo "Components:"
echo "  - Zig engine: $PROJECT_ROOT/zig/zig-out/bin/fano-sh"
echo "  - Scale CLI:  $PROJECT_ROOT/zig/zig-out/bin/fano-scale"
echo "  - Holo-FS:    $PROJECT_ROOT/holo-fs/zig-out/bin/holo-fs"
echo "  - Quine:      $PROJECT_ROOT/quine-server/zig-out/bin/quine-server"
echo "  - API:        /api/fano_quine (space-agent)"
echo "  - Page:       /fano_quine (space-agent)"
echo ""
echo "To run the full stack:"
echo "  1. Start quine server: quine-server/zig-out/bin/quine-server doc.taskpaper 8080"
echo "  2. Start space-agent:  cd space-agent && npm start"
echo "  3. Open: http://localhost:7681/fano_quine"
