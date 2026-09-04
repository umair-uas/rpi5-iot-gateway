# AI Acceleration 101 — NPUs, model compilers, and this layer

A conceptual primer for developers new to AI accelerators and on-device/edge
inference, using the DEEPX DX-M1 as the worked example. If you already know
what an NPU, a model compiler, and a runtime are, skip to
[AI_ACCELERATION_ARCHITECTURE.md](AI_ACCELERATION_ARCHITECTURE.md) for the
pipeline diagram, or [DEEPX_DXM1.md](DEEPX_DXM1.md) for this layer's actual
build gates and traps.

**Status note:** the target half of this pipeline is now demonstrated on the
Raspberry Pi 5. The project image loads a signed DX-M1 driver, runs the DX-RT
service without root privileges, executes the bundled YOLOv5s model on the
NPU, and checks utilization to rule out CPU fallback. The host-side DX-COM
compile-your-own-model workflow remains vendor-documented but unverified here.
See [DEEPX_DXM1.md](DEEPX_DXM1.md) for the measured baseline and remaining
production work.

---

## 1. Why a separate chip for this at all

A CPU can run a neural network. It's just slow and power-hungry at it,
because a CPU is built to do one arithmetic operation at a time, fast and
flexibly. Inference is the opposite kind of workload: millions of small,
*identical*, independent multiply-accumulate operations (that's what a
convolution or a matrix multiply is underneath). A chip built to do that one
shape of math in parallel — and nothing else — does it at a fraction of the
energy per operation. That chip is the NPU (Neural Processing Unit), also
called an AI accelerator or an inference accelerator.

That trade only makes sense at the edge (on the device, rather than in a
datacenter) when at least one of these is true:

- **Latency** — a round trip to a cloud GPU is too slow for the task
  (control loops, real-time video).
- **Power** — the device is battery- or thermally-constrained, and a CPU
  running inference continuously would burn the budget.
- **Bandwidth/connectivity** — streaming raw sensor data off-device costs
  more than sending the model's *conclusions*, or the device can't assume
  connectivity at all.
- **Privacy/data residency** — the raw input (a camera frame, audio) should
  never leave the device.

A gateway product is usually all four at once, which is why this repo has an
accelerator story at all.

## 2. Vocabulary you'll see everywhere in this space

| Term | Plain meaning |
|---|---|
| **NPU** | The accelerator silicon. Here: the DEEPX DX-M1 chip, attached over PCIe. |
| **TOPS** | Trillion Operations Per Second — the NPU's raw throughput ceiling. A spec-sheet number, not a guarantee of real-world FPS. |
| **Quantization** | Shrinking a model's numbers (usually 32-bit floats) down to 8-bit integers before it runs on the NPU. Trades a small amount of accuracy for a large amount of speed and power — the NPU is often *built* to only do integer math fast. |
| **ONNX** | Open Neural Network Exchange — a standard file format most training frameworks (PyTorch, TensorFlow) can export a trained model *to*. It's the universal hand-off point between "how the model was trained" and "how it gets compiled for a specific chip." |
| **Model compiler** | Vendor-specific tool that takes an ONNX model and produces a binary the NPU can actually execute, quantizing and optimizing along the way. For DX-M1 this is DX-COM — vendor-documented as x86_64-host-only and not exercised by this repo. |
| **Runtime** | The on-device library/service that loads the compiled model and drives the NPU at inference time. For DX-M1 this is DX-RT (`dxrtd`, `dxrt-cli`). |
| **Driver** | The kernel-level piece that actually talks to the chip over its bus (here, PCIe) — memory mapping, DMA, interrupts. The runtime sits on top of it; you don't call the driver directly. |
| **Inference** | Running the already-trained, already-compiled model against real input and getting a prediction back. This is the *only* thing that happens on the device — training happens elsewhere, once, ahead of time. |

## 3. The two-machine mental model

Every accelerator vendor in this space (DeepX included) splits the world into
two machines, and understanding *why* explains most of what looks
overcomplicated at first:

```
HOST (your dev machine, x86_64)          TARGET (the device, aarch64)
────────────────────────────────         ──────────────────────────────
trained model (PyTorch/ONNX)             signed driver
      │                                        │
      ▼                                        ▼
vendor model compiler                    runtime loads the model
(DX-COM: quantize, optimize,             and drives the NPU
 hardware-specific instruction
 scheduling)
      │
      └──────── compiled model file ─────────────►
                (the ONLY thing that crosses)
```

**Why split it this way, rather than compile on-device?** Compilation is
expensive (real optimization search, not a quick pass) and needs the vendor's
full proprietary toolchain — shipping that onto every device would bloat the
image with tooling nothing on the device ever runs twice, and would mean
distributing the compiler's IP to every unit in the field. So: compile once,
on a workstation, and ship only the small compiled artifact. This is not
DX-M1-specific — it's how essentially every NPU vendor's SDK is shaped
(Hailo, Google Coral/EdgeTPU, Rockchip's RKNN toolchain all follow the same
split).

For DX-M1 concretely: a trained model gets exported to **ONNX**, then
DX-COM compiles it into a **`.dxnn`** file — DeepX's own binary format,
tuned for this specific chip. That `.dxnn` file is the entire hand-off; the
target device never sees the ONNX file, the training code, or the compiler.

See [AI_ACCELERATION_ARCHITECTURE.md](AI_ACCELERATION_ARCHITECTURE.md) for
the full pipeline diagram, including exactly what this project's Yocto layer
does with the target side of that split.

## 4. "Bring your own model" — the general shape

This is the conceptual workflow the DX-M1 SDK is built around (design, as
documented by the vendor — not something exercised by this repo's current
demo, which ships a pre-compiled sample model instead; see the caveat in
§5):

1. Train or obtain a model in PyTorch or TensorFlow.
2. Export it to **ONNX**.
3. Run DX-COM on a host machine with a representative **calibration
   dataset** (a handful of real input samples) — quantization needs to see
   real data to decide how to shrink the numbers without wrecking accuracy.
4. DX-COM emits a `.dxnn` file.
5. Copy that file onto the device, in whatever location the runtime expects.
6. Point `dxrt-cli` / the DX-RT API at it and run inference.

Steps 1–4 happen entirely on your workstation and are **out of scope for
this Yocto layer** — DX-COM is x86_64-only vendor tooling and is never built
or run as part of this repo's image. Steps 5–6 are what the target-side
runtime (`dx-rt`, packaged by this layer) is for.

## 5. What's real right now, and what's the general capability

Be precise about which of the above is *this repo, today* versus *the
DX-M1 platform in general* — conflating the two is the most common mistake
when reading vendor documentation against a specific integration:

- **General DX-M1 capability** (vendor-documented, not independently
  verified against this host or repo): the DX-COM compile-your-own-model
  workflow described in §4.
- **What this repo's current dev image actually ships**: a **pre-compiled
  vendor sample model** (`YoloV5S_PPU.dxnn`, bundled in `dx-stream-sample`)
  as an external input — nothing is compiled from source as part of this
  layer's build.
- **What's actually been demonstrated on hardware**: driver autoload and bind,
  enforced module signatures, `/dev/dxrt0`, an unprivileged `dxrtd`, device
  telemetry, real inference with the bundled sample, and non-zero utilization
  on all three NPU cores. The acceptance gate passed 25 checks with no failures
  from a clean full-FIT RAUC installation on slot B, with no target-side hand
  edits. See
  [DEEPX_DXM1.md](DEEPX_DXM1.md#2-hardware-acceptance-milestone) for the
  precise versions and caveats.

## 6. Where this layer's responsibility starts and ends

- `meta-deepx-m1` (upstream, vendor-provided): the kernel driver source, the
  DX-RT runtime source, the GStreamer plugin, demo apps. None of it is
  written or maintained here.
- `meta-iot-gateway` (this repo, project-specific): everything needed to
  make that upstream layer work *on this hardened distro* — signature
  verification for the driver, the symbol-whitelist fix, Raspberry Pi MSI
  mode, deterministic PCIe initialization, ASPM policy, service/device
  ownership, the feature gate, acceptance tooling, and matched full-FIT OTA
  packaging. This is the delta a hardened Yocto BSP has to pay that a generic
  Debian installation doesn't.
- Off this device entirely: DX-COM, the training pipeline, the calibration
  dataset. Host-side, x86_64, out of scope by design (see the operator
  constraints recorded in
  [AI_ACCELERATION_ARCHITECTURE.md](AI_ACCELERATION_ARCHITECTURE.md)).
- **Also off this device, and not documented here on purpose**: the rest of
  DeepX's desktop SDK — **DX-TRON**, a GUI that visualizes a compiled
  `.dxnn`'s NPU/CPU workload split, and **DX-ModelZoo**, their catalogue of
  pre-trained, pre-compiled models. Both are host-side developer tooling
  this repo neither ships nor verifies; if you need them, go to
  [DeepX's own documentation](https://github.com/DEEPX-AI) rather than
  looking for a local write-up — duplicating vendor docs we can't test
  against would just go stale.

## 7. Next

- [AI_ACCELERATION_ARCHITECTURE.md](AI_ACCELERATION_ARCHITECTURE.md) — the
  pipeline diagram and "what gets built where," plus how this same shape
  would extend to a second accelerator vendor.
- [DEEPX_DXM1.md](DEEPX_DXM1.md) — the technical reference: build gates,
  signing authority, firmware boundary, acceptance evidence, licensing,
  hardware notes, and remaining production work. Read this before touching
  any recipe.
- [FIT_BOOT_SIGNING.md](FIT_BOOT_SIGNING.md) — the signing-key model a future
  persistent module-signing key is meant to mirror.
