# System Hardware Documentation

**System Name:** ostf-digit  
**Documentation Date:** May 22, 2026 (Updated)  
**Operating System:** Kali Linux (Kernel 6.19.14+kali-amd64)

---

## System Overview

| Property | Value |
|----------|-------|
| Architecture | x86_64 |
| Platform | Kali Linux |
| Kernel Version | 6.19.14+kali-amd64 #1 SMP PREEMPT_DYNAMIC |
| Kernel Build Date | 2026-05-05 |
| Byte Order | Little Endian |
| SMBIOS Version | 3.2.0 |

---

## CPU (Central Processing Unit)

### Processor Details
- **Manufacturer:** AMD
- **Model:** Ryzen 5 3500U with Radeon Vega Mobile Gfx
- **Family:** 23
- **Model Number:** 24
- **Stepping:** 1
- **Microcode:** 0x810810e

### Core Configuration
- **Physical Cores:** 4
- **Threads per Core:** 2
- **Total Logical Processors:** 8
- **Sockets:** 1
- **NUMA Nodes:** 1

### Clock Speeds
- **Base Frequency:** 1400 MHz
- **Maximum Frequency:** 2100 MHz
- **Current Frequency:** 3686 MHz (variable)
- **Frequency Boost:** Enabled
- **Scaling:** 150%

### Cache Hierarchy
- **L1 Data Cache:** 128 KiB (4 instances)
- **L1 Instruction Cache:** 256 KiB (4 instances)
- **L2 Cache:** 2 MiB (4 instances)
- **L3 Cache:** 4 MiB (1 instance)

### CPU Features
- **Virtualization:** AMD-V
- **AES Instructions:** Yes
- **AVX/AVX2:** Yes
- **SSE4.1/4.2:** Yes
- **FMA:** Yes
- **SHA Extensions:** Yes
- **RDRAND:** Yes

### Security Vulnerabilities
- **Gather Data Sampling:** Not affected
- **Ghostwrite:** Not affected
- **Indirect Target Selection:** Not affected
- **ITLB Multihit:** Not affected
- **L1TF:** Not affected
- **MDS:** Not affected
- **Meltdown:** Not affected
- **MMIO Stale Data:** Not affected
- **Old Microcode:** Not affected
- **Reg File Data Sampling:** Not affected
- **Retbleed:** Mitigation; untrained return thunk; SMT vulnerable
- **Spec Rstack Overflow:** Mitigation; Safe RET
- **Spec Store Bypass:** Mitigation; Speculative Store Bypass disabled via prctl
- **Spectre V1:** Mitigation; usercopy/swapgs barriers and __user pointer sanitization
- **Spectre V2:** Mitigation; Retpolines; IBPB conditional; STIBP disabled; RSB filling; PBRSB-eIBRS Not affected; BHI Not affected
- **SRBDS:** Not affected
- **TSA:** Not affected
- **TSX Async Abort:** Not affected
- **VMScape:** Mitigation; IBPB before exit to userspace

---

## Memory (RAM)

### Memory Configuration
- **Total Memory:** 30 GiB
- **Used Memory:** 5.0 GiB
- **Free Memory:** 19 GiB
- **Shared Memory:** 97 MiB
- **Buffer/Cache:** 5.8 GiB
- **Available Memory:** 25 GiB

### Swap Configuration
- **Total Swap:** 30 GiB
- **Used Swap:** 0 B
- **Free Swap:** 30 GiB

---

## Storage

### Primary Storage (NVMe SSD)
- **Device:** nvme0n1
- **Model:** Micron MTFDKCD1T0TFK
- **Controller:** Micron 2450 NVMe SSD [HendrixV] (DRAM-less)
- **Total Capacity:** 953.9 GiB
- **Interface:** NVMe PCIe

### Partition Layout
| Partition | Size | Type | Filesystem | Mount Point |
|-----------|------|------|------------|-------------|
| nvme0n1p1 | 976 MiB | EFI System | vfat | /boot/efi |
| nvme0n1p2 | 922 GiB | Linux Filesystem | ext4 | / |
| nvme0n1p3 | 30.9 GiB | Linux Swap | swap | [SWAP] |

### SATA Controller
- **Controller:** AMD FCH SATA Controller [AHCI mode]
- **Mode:** AHCI 1.0
- **Status:** Enabled

---

## Graphics (GPU)

### Integrated Graphics
- **Manufacturer:** AMD/ATI
- **Model:** Picasso/Raven 2 [Radeon Vega Series / Radeon Vega Mobile Series]
- **Revision:** 71
- **VRAM:** Shared with system memory
- **Driver:** amdgpu
- **Memory Mappings:**
  - 256 MiB prefetchable at e0000000
  - 2 MiB prefetchable at f0000000
  - 512 KiB non-prefetchable at fcc00000
- **I/O Ports:** e000 (size 256)

### Display/Audio
- **HDMI/DP Audio Controller:** AMD Raven/Raven2/Fenghuang
- **Driver:** snd_hda_intel

---

## Network

### Wireless Network
- **Controller:** Realtek RTL8852BE PCIe 802.11ax Wireless Network Controller
- **Standard:** 802.11ax (Wi-Fi 6)
- **Interface:** wlan0
- **MAC Address:** 3c:3b:ad:f9:0b:1a
- **Status:** UP, LOWER_UP
- **MTU:** 1500
- **Driver:** rtw89_8852be
- **I/O Ports:** f000 (size 256)
- **Memory:** fce00000 (1 MiB)

### Loopback
- **Interface:** lo
- **Status:** UP, LOWER_UP
- **MTU:** 65536

### Onboard LAN
- **Device:** Onboard LAN Broadcom
- **Status:** Disabled
- **Type:** Ethernet

---

## Audio

### HD Audio Controller
- **Device:** AMD Ryzen HD Audio Controller
- **Subsystem:** Conexant Systems, Inc. Device 03cc
- **Driver:** snd_hda_intel
- **Memory:** fcc80000 (32 KiB)

### HDMI/DP Audio
- **Device:** AMD Raven/Raven2/Fenghuang HDMI/DP Audio Controller
- **Driver:** snd_hda_intel
- **Memory:** fcc88000 (16 KiB)

---

## USB Controllers

### USB 3.1 Controllers
- **Controller 1:** AMD Raven USB 3.1 (XHCI)
  - Bus Address: 03:00.3
  - Driver: xhci_hcd
  - Memory: fca00000 (1 MiB)
  
- **Controller 2:** AMD Raven USB 3.1 (XHCI)
  - Bus Address: 03:00.4
  - Driver: xhci_hcd
  - Memory: fc900000 (1 MiB)

### Connected USB Devices
| Device | ID | Description |
|--------|-----|-------------|
| Root Hub | 1d6b:0002 | Linux Foundation 2.0 root hub |
| Card Reader | 0bda:0129 | Realtek RTS5129 Card Reader Controller |
| Root Hub | 1d6b:0003 | Linux Foundation 3.0 root hub |
| Root Hub | 1d6b:0002 | Linux Foundation 2.0 root hub |
| USB Hub | 05e3:0608 | Genesys Logic Hub |
| Bluetooth | 0bda:b85b | Realtek Bluetooth Radio |
| Webcam | 0c45:6366 | Microdia Webcam Vitade AF |
| Fingerprint | 2808:c652 | FocalTech Fingerprint Device |
| Root Hub | 1d6b:0003 | Linux Foundation 3.0 root hub |

---

## Motherboard / System Board

### System Information
- **Manufacturer:** Default string
- **Product Name:** Default string
- **Version:** Version 1.0
- **Serial Number:** Default string
- **UUID:** 9b067200-7890-11f0-b89f-3fc1e8c13600
- **Wake-up Type:** Power Switch
- **SKU Number:** Default SKU
- **Family:** Default string

### Base Board Information
- **Manufacturer:** Default string
- **Product Name:** Default string
- **Version:** Version 1.0
- **Serial Number:** APNTU085813K0634
- **Asset Tag:** Default string
- **Type:** Motherboard
- **Features:**
  - Board is a hosting board
  - Board is replaceable
- **Location in Chassis:** Default string

### Onboard Devices
- **Video:** Enabled (To Be Filled By O.E.M.)
- **LAN:** Disabled (Onboard LAN Broadcom)
- **Audio:** Enabled (HD Audio Controller)

---

## Security & Encryption

### Platform Security Processor
- **Device:** AMD Raven/Raven2/FireFlight/Renoir/Cezanne Platform Security Processor
- **Type:** Encryption Controller
- **Driver:** ccp
- **Memory:**
  - fcb00000 (1 MiB)
  - fcc8c000 (8 KiB)

---

## PCI Devices Summary

### Host Bridge (AMD)
- **Device:** Raven/Raven2 Device 24: Function 0-7
- **Functions:** 8 (00:18.0 - 00:18.7)
- **Driver:** k10temp (function 3)

### SMBus Controller
- **Device:** AMD FCH SMBus Controller
- **Revision:** 61
- **Driver:** piix4_smbus

### ISA Bridge
- **Device:** AMD FCH LPC Bridge
- **Revision:** 51

### PCIe Bridge
- **Device:** AMD Raven PCIe Root Port
- **Revision:** 00
- **Driver:** pcieport

### NVMe Controller
- **Device:** Micron 2450 NVMe SSD [HendrixV]
- **Type:** DRAM-less
- **Revision:** 01
- **Driver:** nvme
- **Memory:** fcf00000 (16 KiB)

---

## System Boot Information
- **Status:** No errors detected

---

## Graphics Drivers

### Vulkan Support
- **Vulkan Instance Version:** 1.4.341
- **Primary GPU:** AMD Radeon Vega Mobile Gfx (RADV RAVEN)
- **Driver:** RADV (Mesa 26.0.6-1)
- **Driver ID:** DRIVER_ID_MESA_RADV
- **Device Type:** PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU
- **API Version:** 1.4.335
- **Conformance Version:** 1.4.0.0

### OpenGL Support
- **OpenGL Version:** 4.6 (Compatibility Profile)
- **OpenGL Vendor:** AMD
- **OpenGL Renderer:** AMD Radeon Vega Mobile Gfx (radeonsi, raven, ACO, DRM 3.64, 6.19.14+kali-amd64)
- **Mesa Version:** 25.2.6-1
- **Direct Rendering:** Yes

### Installed Graphics Packages
- mesa-vulkan-drivers: 26.0.6-1
- mesa-libgallium: 25.2.6-1
- xserver-xorg-video-amdgpu: 25.0.0-1
- libdrm-amdgpu1: 2.4.131-1+b1
- vulkan-tools: 1.4.341.0+dfsg1-1
- mesa-utils: 9.0.0-2+b3
- mesa-utils-bin: 9.0.0-2+b3

---

## Development Tools & Software

### Programming Languages & Compilers

#### Python
- **Version:** 3.13.12
- **Location:** /usr/bin/python3
- **Status:** Pre-installed with Kali Linux

#### C/C++
- **C Compiler (gcc):** 15.2.0 (Debian 15.2.0-17)
- **C++ Compiler (g++):** 15.2.0 (Debian 15.2.0-17)
- **Location:** /usr/bin/gcc, /usr/bin/g++
- **Status:** Pre-installed with Kali Linux

#### Rust
- **Version:** 1.95.0 (59807616e 2026-04-14)
- **Installation Method:** rustup
- **Toolchain:** stable-x86_64-unknown-linux-gnu
- **Cargo Location:** ~/.cargo/bin
- **PATH Configured:** Yes (in ~/.zshrc)
- **Additional Tools:** rustfmt, cargo

#### Zig
- **Version:** 0.13.0
- **Installation Method:** Binary tarball
- **Location:** /opt/zig
- **PATH Configured:** Yes (in ~/.zshrc)

#### .NET SDK
- **Version:** 9.0.314
- **Installation Method:** dotnet-install script
- **Location:** ~/.dotnet
- **PATH Configured:** Yes (in ~/.zshrc)

#### Q# (Quantum Computing)
- **Package:** Microsoft.Quantum.ProjectTemplates
- **Version:** 0.28.302812
- **Templates Installed:**
  - Class library (classlib)
  - Console Application (console)
  - Quantum Application Honeywell (azq-honeywell)
  - Quantum Application IonQ (azq-ionq)
  - Quantum Application Quantinuum (azq-quantinuum)
  - xUnit Test Project (xunit)

### System Configuration

#### Passwordless Sudo
- **User:** admpaul
- **Configuration:** /etc/sudoers.d/admpaul
- **Status:** Enabled

#### Shell Configuration
- **Shell:** zsh (/usr/bin/zsh)
- **Config File:** ~/.zshrc
- **PATH Additions:**
  - ~/.cargo/bin (Rust)
  - /opt/zig (Zig)
  - ~/.dotnet (.NET)

#### SSH Configuration
- **SSH Server:** OpenSSH Server (openssh-server)
- **Service Status:** Active and running
- **Listening Ports:** 22 (IPv4 and IPv6)
- **Local IP Address:** 192.168.12.3 (wlan0)
- **SSH Key Type:** ED25519
- **SSH Public Key:** ~/.ssh/id_ed25519.pub

#### SSH Two-Way Authentication
- **Remote Server:** osft-sheraton (192.168.12.214)
- **Local → Remote:** Passwordless SSH authentication configured
- **Remote → Local:** Passwordless SSH authentication configured
- **Key Exchange:** Both systems have each other's public keys in authorized_keys

---

## Notes

- This system appears to be a laptop or mobile device based on the "Mobile Gfx" designation and integrated components
- The system is running Kali Linux, a penetration testing distribution
- All hardware components are properly recognized and have appropriate kernel drivers loaded
- The system uses UEFI boot (evidenced by /boot/efi partition)
- The onboard LAN is disabled, suggesting reliance on wireless connectivity
- System includes biometric authentication (fingerprint reader)
- Multiple security mitigations are active for CPU vulnerabilities
- GPU acceleration is fully functional with both Vulkan and OpenGL support via RADV driver
- Development environment is configured with multiple programming languages (Python, C/C++, Rust, Zig, Q#)
- Passwordless sudo is configured for the user admpaul
- All development tools are properly configured on PATH
- SSH server is enabled and running with two-way passwordless authentication to osft-sheraton (192.168.12.214)
