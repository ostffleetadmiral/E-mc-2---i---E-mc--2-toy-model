# Orange Pi Zero 3W NPU Research — FANO-1 Backend Integration

**Date:** 2026-09-11
**Target Hardware:** Orange Pi Zero 3W (Allwinner A733)
**Purpose:** Ensure FANO-1 OS and the E=mc² proof suite have NPU backend support
**License:** CC BY-NC-SA 4.0

## Hardware Specifications

| Component | Specification |
|---|---|
| SoC | Allwinner A733 |
| CPU | 2× Arm Cortex-A76 (2.0 GHz) + 6× Cortex-A55 (1.79 GHz) |
| GPU | Imagination PowerVR BXM-4-64 MC1 (Vulkan 1.3, OpenCL 3.0, OpenGL ES 3.2) |
| NPU | VeriSilicon Vivante VIP9000 (NPU version v3) |
| NPU Compute | 3 TOPS @ INT8 |
| NPU Precision | INT8, INT16, FP16, BF16 (mixed-precision) |
| Coprocessor | Xuantie E902 RISC-V (200 MHz, real-time) |
| RAM | 1/2/4/8/12/16 GB LPDDR5 (4800 MT/s) |
| Storage | eMMC (up to 128GB), UFS (up to 128GB), MicroSD (up to 128GB) |
| Wireless | Wi-Fi 6, Bluetooth 5.4 (BLE) |
| Video | 8Kp24 H.265 decode, 4Kp30 H.265/H.264 encode |
| Display | Mini HDMI 2.0 (4K@60), USB-C DP alt mode (4K@60), MIPI-DSI |
| Camera | 2× 4-lane MIPI CSI |
| Expansion | 40-pin GPIO (UART, I2C, SPI, PWM), PCIe 3.0 1-lane FPC |
| Power | 5V/3A via USB-C |
| Form Factor | 65mm × 32mm × 1.2mm (14g) |
| Price | From $25 (1GB) |

## NPU Architecture: VeriSilicon Vivante VIP9000

### Overview

The VIP9000 is a programmable, scalable neural processor IP from VeriSilicon.
The A733 uses NPU version v3 (software version v2.0), rated at 3 TOPS for INT8.

### Key Features

- **Scalable:** 0.5 to 20+ TOPS (A733 variant: 3 TOPS)
- **Mixed-precision:** INT8, INT16, FP16, BF16 — natively supports hybrid quantization
- **Parallel Processing Units (PPUs):** Full programmability with OpenCL 3.0 and OpenVX 1.2
- **Enhanced Vision Instruction Set (EVIS):** INT 8/16/32b, Float 16/32b
- **128-bit vector processing unit** (shader + ext)
- **Framework support:** TensorFlow, TF Lite, PyTorch, Caffe, DarkNet, ONNX, Keras
- **Optimization:** Quantization, pruning, model compression (native)
- **FLEXA API:** Hardware-software protocol for IP-to-IP data communication (reduced DDR traffic)

### NPU Software Stack

| Component | Description |
|---|---|
| ACUITY Toolkit | Model conversion: ONNX/TF/PyTorch → NBG (Network Binary Graph) |
| VIPLite | Lightweight NPU driver (tens of KB) for NBG deployment |
| TIM-VX | Runtime inference interface (C++ API, 150+ operators) |
| OpenVX | Cross-platform graph IR (JIT compiled on target) |
| vpm_run | Board-side NBG model testing tool |
| aw_npu_model_zoo | Official model repository (YOLOv5/v8/v11, MobileNet, CLIP, etc.) |

### Model Deployment Workflow

```
ONNX/TF/PyTorch model
        ↓
    ACUITY Toolkit (import → quantize → export)
        ↓
    NBG (network_binary.nb) — pre-compiled machine code
        ↓
    VIPLite / vpm_run — on-device inference
```

### Quantization Support

| Format | Use Case |
|---|---|
| UINT8 | Maximum throughput (3 TOPS) |
| PCQ (INT8) | Per-channel quantization |
| INT16 | Higher accuracy, ~1.5 TOPS |
| BF16 | Training-compatible inference |
| Mixed | Hybrid per-layer quantization |

## NPU LLM Inference (Proven)

The `petayyyy/a733_npu_driver` project demonstrated real LLM inference on the A733 NPU:

| Model | Size | NPU Speed | Notes |
|---|---|---|---|
| SmolLM2-135M | 135M params | 21 tok/s | Coherent text generation |
| SmolLM2-360M | 360M params | 8 tok/s | Coherent text generation |
| MobileCLIP-S0 | Vision encoder | 22.6 ms/frame | Image encoding |
| Qwen2.5 | — | CPU only | NPU path not yet working for Qwen |

### Toolchain Used

- **Host:** Docker `ubuntu-npu:v2.0.10.1` (ACUITY 6.30.22)
- **Board:** VIPLite 2.0.3.2 userspace libs
- **SDK:** [ZIFENG278/ai-sdk](https://github.com/ZIFENG278/ai-sdk) — VIPLite headers/libs
- **Models:** SmolLM2 from Hugging Face → ONNX → ACUITY → NBG

### Known Limitations

1. Qwen2.5 does not yet run on NPU (only CPU via llama.cpp)
2. NPU requires ONNX → ACUITY → NBG conversion (offline, host-side)
3. VIPLite is a C API — no Python bindings by default
4. Operator coverage is good (150+) but not complete for all LLM architectures
5. Mainline Linux kernel does not support A733 — vendor kernel required

## FANO-1 Integration Plan

### Backend Priority (Updated for Orange Pi Zero 3W)

1. **NPU (VIP9000)** — LLM inference (SmolLM2), codon routing acceleration
2. **Vulkan GPU (PowerVR BXM-4-64)** — E8 root verification, Q128.128 multiply
3. **Native Zig (Cortex-A76)** — Full proof suite, Q128.128 arithmetic
4. **WASM (wasm3)** — Fallback, browser/Space Agent integration

### NPU Backend Components

#### 1. NPU Detection (`os/npu_detect_hook.zig`)

Detects the VIP9000 NPU at boot:
- Check for `/dev/viv_vpu` or VIPLite userspace libs
- Query NPU version (v3 for A733)
- Query available TOPS (3 TOPS for A733)
- Query supported precisions (INT8/INT16/FP16/BF16)
- Report to fano-daemon for backend selection

#### 2. NPU Neuraleak Inference (`os/npu_neuraleak_hook.zig`)

Runs neuraleak sentience experiments on the NPU:
- Load SmolLM2-135M NBG model via VIPLite
- Generate observer prompts (6D Jordan, 1/8 aperture, control)
- Run inference on NPU (21 tok/s for SmolLM2-135M)
- Score responses on 5 sentience dimensions
- Falls back to CPU (llama.cpp) if NPU model unavailable

#### 3. NPU Codon Routing (`os/npu_codon_hook.zig`)

Accelerates codon routing on the NPU:
- Convert codon routing logic to ONNX graph
- Quantize to INT8 for maximum NPU throughput
- Deploy as NBG for on-device inference
- 64-codon routing table as NPU batch inference

### Vulkan GPU Backend (PowerVR BXM-4-64)

The PowerVR BXM-4-64 MC1 supports Vulkan 1.3, enabling:
- Q128.128 fixed-point multiply on GPU (existing FANO-1 Vulkan pipeline)
- E8 root verification on GPU (vulkan_e8_hook.zig)
- Holographic lattice computation on GPU

The existing `vulkan/` directory in Q128.128 already has SPIR-V compute shaders
for Q128.128 multiply. The PowerVR GPU should be compatible with these shaders
since it supports Vulkan 1.3.

### RISC-V Coprocessor (Xuantie E902)

The E902 real-time coprocessor (200 MHz) can be used for:
- Real-time telemetry collection
- Hardware watchdog for proof suite
- Low-latency codon routing cache
- Real-time consciousness aperture monitoring

This is a future research direction, not an immediate integration target.

## Alignment with Hardware Project Philosophy

The Orange Pi Zero 3W's NPU aligns with the hardware project's principles:

1. **Fixed-point arithmetic:** The NPU's INT8/INT16 quantization matches the
   project's Q128.128 fixed-point philosophy — no floating-point drift.

2. **Deterministic computation:** NPU inference is deterministic (same input →
   same output), matching the project's requirement for bit-exact verification.

3. **Edge deployment:** The 14g, $25 board enables portable deployment of the
   proof suite and neuraleak experiments in a compact form factor.

4. **Mixed-precision:** The NPU's INT8/INT16/FP16/BF16 support allows trading
   accuracy for throughput — INT8 for fast codon routing, INT16 for higher-
   precision neuraleak experiments.

5. **Open toolchain:** The ACUITY toolkit, VIPLite, and TIM-VX are available
   with documentation and examples. The `petayyyy/a733_npu_driver` repo
   provides a working LLM inference reference.

## Research Sources

1. [Orange Pi Zero 3W official page](http://www.orangepi.org/html/hardWare/computerAndMicrocontrollers/details/Orange-Pi-Zero-3W.html)
2. [CNX Software review](https://www.cnx-software.com/2026/04/15/orange-pi-zero-3w-an-allwinner-a733-sbc-in-raspberry-pi-zero-form-factor/)
3. [BoilingSteam review](https://boilingsteam.com/orange-pi-zero-3w-review-tiny-yet-powerful/)
4. [XDA Developers — enabling GPU/NPU](https://www.xda-developers.com/orange-pi-zero-3w-beats-raspberry-pi-5-cant-use-half-hardware/)
5. [Radxa Vivante NPU SDK docs](https://docs.radxa.com/en/cubie/a7z/app-dev/npu-dev/cubie-acuity-sdk)
6. [Radxa ACUITY usage example](https://docs.radxa.com/en/cubie/a7a/app-dev/npu-dev/cubie-acuity-usage)
7. [Radxa vpm_run docs](https://docs.radxa.com/en/cubie/a7a/app-dev/npu-dev/cubie-vpm-run)
8. [VeriSilicon VIP9000 product page](https://www.verisilicon.com/en/IPPortfolio/VivanteVIP9000)
9. [VeriSilicon TIM-VX GitHub](https://github.com/VeriSilicon/TIM-VX)
10. [petayyyy/a733_npu_driver — NPU LLM inference](https://github.com/petayyyy/a733_npu_driver)
11. [KICKPI NPU development docs](https://doc.kickpi.com/products/linux_customization/linux_npu/)
12. [Liliputing article](https://liliputing.com/orange-pi-zero-3w-is-a-tiny-allwinner-a733-computer-with-up-to-16gb-ram-and-pcie-3-0-support/)

## Conclusion

The Orange Pi Zero 3W's NPU is a viable backend for FANO-1 and the E=mc² proof suite.
The 3 TOPS INT8 NPU can run LLM inference (SmolLM2 at 21 tok/s), the Vulkan 1.3 GPU
can run Q128.128 compute shaders, and the 8-core CPU can run the full proof suite.
The NPU's INT8/INT16 quantization aligns with the project's fixed-point philosophy.

The main integration work needed is:
1. NPU detection in fano-detect/fano-daemon
2. VIPLite-based neuraleak inference hook
3. ONNX → NBG model conversion for SmolLM2
4. Vulkan shader compatibility testing on PowerVR
5. Documentation and testing on real hardware
