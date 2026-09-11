#!/bin/bash
# build-emc2-pet.sh — build the E=mc² proof suite .pet package for FANO-1.
#
# This script compiles the Zig proof binary and WASM module, then
# assembles the .pet package skeleton under os/pet/.
#
# Usage: ./os/build-emc2-pet.sh [--no-wasm] [--no-qsharp]
#
# License: CC BY-NC-SA 4.0

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PET_DIR="$SCRIPT_DIR/pet"

BUILD_WASM=true
BUILD_QSHARP=true

while [ $# -gt 0 ]; do
    case "$1" in
        --no-wasm)   BUILD_WASM=false; shift ;;
        --no-qsharp) BUILD_QSHARP=false; shift ;;
        --help|-h)
            echo "Usage: $0 [--no-wasm] [--no-qsharp]"
            echo ""
            echo "Build the E=mc² proof suite .pet package for FANO-1."
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

echo "[build-emc2-pet] Project: $PROJECT_DIR"
echo "[build-emc2-pet] PET dir: $PET_DIR"

# 1. Compile the Zig proof binary
echo "[build-emc2-pet] Compiling Zig proof binary..."
cd "$PROJECT_DIR"
zig build -Doptimize=ReleaseSafe
cp zig-out/bin/emc2-i-emc2 "$PET_DIR/usr/lib/emc2/emc2-i-emc2"
chmod +x "$PET_DIR/usr/lib/emc2/emc2-i-emc2"
echo "[build-emc2-pet] Proof binary: $(ls -la "$PET_DIR/usr/lib/emc2/emc2-i-emc2" | awk '{print $5}') bytes"

# 2. Build the WASM module
if [ "$BUILD_WASM" = true ]; then
    echo "[build-emc2-pet] Building WASM module (wasm32-wasi)..."
    cd "$PROJECT_DIR/wasm"
    if zig build -Doptimize=ReleaseSmall 2>/dev/null; then
        cp zig-out/bin/emc2-proofs.wasm "$PET_DIR/usr/lib/emc2/wasm/emc2-proofs.wasm" 2>/dev/null || \
        cp zig-out/lib/emc2-proofs.wasm "$PET_DIR/usr/lib/emc2/wasm/emc2-proofs.wasm" 2>/dev/null || \
        find zig-out -name "*.wasm" -exec cp {} "$PET_DIR/usr/lib/emc2/wasm/emc2-proofs.wasm" \; 2>/dev/null || \
        echo "[build-emc2-pet] WARNING: WASM build succeeded but output not found"
        echo "[build-emc2-pet] WASM module: $(ls -la "$PET_DIR/usr/lib/emc2/wasm/emc2-proofs.wasm" 2>/dev/null | awk '{print $5}') bytes"
    else
        echo "[build-emc2-pet] WARNING: WASM build failed (wasm32-wasi target may not be available)"
    fi
    cd "$PROJECT_DIR"
fi

# 3. Copy Q# witnesses
if [ "$BUILD_QSHARP" = true ] && [ -d "$PROJECT_DIR/qsharp" ]; then
    echo "[build-emc2-pet] Copying Q# witnesses..."
    mkdir -p "$PET_DIR/usr/lib/emc2/qsharp"
    cp "$PROJECT_DIR/qsharp"/*.qs "$PET_DIR/usr/lib/emc2/qsharp/" 2>/dev/null || true
    cp "$PROJECT_DIR/qsharp"/*.csproj "$PET_DIR/usr/lib/emc2/qsharp/" 2>/dev/null || true
fi

# 4. Copy sidecar
if [ -d "$PROJECT_DIR/sidecar" ]; then
    echo "[build-emc2-pet] Copying sidecar..."
    mkdir -p "$PET_DIR/usr/lib/emc2/sidecar"
    cp "$PROJECT_DIR/sidecar"/*.zig "$PET_DIR/usr/lib/emc2/sidecar/" 2>/dev/null || true
fi

# 5. Copy documentation
echo "[build-emc2-pet] Copying documentation..."
cp "$PROJECT_DIR/cross-project-map.md" "$PET_DIR/usr/share/emc2/" 2>/dev/null || true
cp "$PROJECT_DIR/AGENTS.md" "$PET_DIR/usr/share/emc2/" 2>/dev/null || true

# 6. Make CLI wrappers executable
chmod +x "$PET_DIR/usr/bin/emc2-proofs"
chmod +x "$PET_DIR/usr/bin/emc2-neuraleak"
chmod +x "$PET_DIR/usr/bin/emc2-codon"

# 7. Create the .pet package
echo "[build-emc2-pet] Creating .pet package..."
cd "$PET_DIR"
PET_NAME="emc2-toy-model-1.0"
tar -czf "$PET_NAME.pet" pet.spec usr/
echo "[build-emc2-pet] Package: $(ls -la "$PET_NAME.pet" | awk '{print $5}') bytes"
echo "[build-emc2-pet] Done: $PET_DIR/$PET_NAME.pet"
