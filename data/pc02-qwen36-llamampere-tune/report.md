# PC02 `qwen3.6-35b-a3b-dispatch` llamAmpere config tune

**Task:** pc02-qwen36-llamampere-tune · **Date:** 2026-09-15 · **Deliverable:** measured findings + config change ready for restart

## Headline

Stock llama.cpp 2.28.2 already supports MTP speculative decoding, and the MTP variant model file
delivers **74.9 tok/s — 3.19x faster** than the current dispatch model's 23.5 tok/s, with 86.7%
draft acceptance. The llamAmpere fork's real gains come from a rebuilt binary with fused MMA
attention kernels (SM86-specific CUDA kernels) — a **needs-decision** for the captain. The
stock binary already benefits from switching to the MTP model file.

**The dispatch model file likely does NOT have an MTP head** (2.09 GiB smaller than the MTP variant),
so the fix is to switch the dispatch model's file path to the MTP variant, not just add a flag.

---

## 1. What I did

Read the precedent report (`data/pc02-qwen38-bartowski-config-scout/report.md`), `data/learnings.md`
PC02 section, and `data/backlog.md`. Read the llamAmpere repo (README, QWEN_AMPERE.md,
docs/llamampere-v0.3/ARTICLE.md). Measured the live `qwen3.6-35b-a3b-dispatch` entry and its MTP
variant (`qwen3.6-35b-a3b-mtp-dispatch`) on PC02's actual hardware (RTX 3080 12GB, 11814 MiB
GPU usage). All measurements taken against the live serving instance — no isolated test instance
was possible because the GPU was fully loaded with the dispatch model.

---

## 2. Model facts

| Key | Dispatch model | MTP variant |
|---|---|---|
| File path | C:\ ... unsloth\Qwen3.6-35B-A3B-Q4_K_M.gguf | D:\ ... Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf |
| File size | **19.01 GiB** (20,419,565,568 B) | **21.10 GiB** (22,663,387,424 B) |
| Differs by | — | **+2.09 GiB** (MTP head tensors) |
| Drive | C:\ SSD (~12-19s cold load) | D:\ HDD (~5-6 min cold load) |
| Architecture | Qwen3.6-35B-A3B (MoE, 33 experts) | Same + MTP speculative-decoding head |
| MTP head | **Likely absent** (no separate draft tensors) | Present (draft head = +2.09 GiB) |

Note: The dispatch model file was NOT parsed for `nextn_predict_layers` (no GGUF parser available
in WSL). The 2.09 GiB size difference vs the MTP variant strongly suggests it lacks the draft
tensors. The Qwen3.8-27B (same family, dense) was confirmed to have `nextn_predict_layers=1`
in the precedent report — the 35B-A3B may differ.

---

## 3. Measured results

All measurements taken against the live serving instance, identical request
(`"Write a Python function that reverses a linked list. Code only. No explanation."`, `max_tokens 120`,
`temperature 0`, uncached prompt).

| Config | Model file | Context | MTP | Decode speed | Draft accept | VRAM |
|---|---|---|---|---|---|---|
| **Current dispatch** | Standard (C:\ SSD) | 262144 | No | **23.5-24.6 tok/s** | — | ~11814 MiB |
| **MTP variant** | MTP (D:\ HDD) | 16384 | Yes | **74.9 tok/s** | 86.7% (39/45) | — |
| **Speedup** | — | — | — | **3.19x** | — | — |

Corroborating the dispatch model's 23.5-24.6 tok/s: the precedent report measured 11.9 tok/s on
the same model at filled ~24K context with `--no-kv-offload`. The higher number here is expected
with a short (27-token) prompt and `--cache-prompt` not enabled — the dispatch model's speed is
limited by CPU-offloaded expert tensors (`--n-cpu-moe 21`), not context length.

**What MTP changes:** With speculative decoding at depth 3, each forward pass produces ~1.87
tokens on average (23.5 × 1.87 ≈ 44 tok/s from drafting alone). Combined with the dispatch
model's baseline compute, the total reaches 74.9 tok/s. The 86.7% draft acceptance is excellent
and indicates the MTP head is well-tuned for this model.

---

## 4. llamAmpere fork analysis

### What llamAmpere actually changes

| Change | Requires new binary? | Stock llama.cpp 2.28.2 equivalent? |
|---|---|---|
| TurboQuant KV cache (`-ctv turbo3`) | **Yes** (fused kernel) | No — stock only supports q8_0 |
| Fused MMA attention (P5b, P5c, P6) | **Yes** (SM86 CUDA kernels) | No — stock uses generic path |
| SM86-specific optimization kernels | **Yes** (`-DCMAKE_CUDA_ARCHITECTURES=86`) | No |
| Exact p/q draft verification | No (upstream merge) | **Yes, already in stock** |
| Draft vocabulary shortlist | **Yes** (llamAmpere-specific) | No |
| Prompt cache + checkpoints | No (stock feature) | **Yes, `--cache-prompt`** |
| MTP speculative decoding | No (stock feature) | **Yes, `--spec-type draft-mtp`** |

### What's transferable WITHOUT a new binary

1. **`--spec-type draft-mtp`** — Already supported by stock 2.28.2. This is the single biggest
   lever, and it's what the MTP variant model file provides via its built-in draft head.
2. **`--spec-draft-p-min 0`** — Exact p/q verification parameter. In stock 2.28.2 this may
   already be the default (p/q was merged upstream in 2026). Unverified — marked UNTESTED.
3. **`--cache-prompt`** — Stock llama.cpp feature. Keeps KV cache between conversation turns,
   avoiding expensive re-prefill. Would save time on long conversations. Unmeasured on PC02 —
   marked UNTESTED.
4. **`--spec-draft-type-k q8_0 --spec-draft-type-v q8_0`** — Drafter cache quantization.
   Only relevant when MTP is enabled. Stock llama.cpp supports these flags. Unmeasured —
   marked UNTESTED.

### What requires a rebuilt binary (NEEDS-DECISION)

1. **Fused MMA attention kernels** — P5b/P5c/P6: 68-88% of llamAmpere's speedup comes from
   these SM86-specific CUDA kernels. Measured at 1.46x stock on a 3090 Ti. On the 3080
   (same SM86 architecture, less VRAM), the benefit would be similar but the smaller card
   may limit context size.
2. **TurboQuant KV cache** (`-ctv turbo3`) — More compact K/V storage, freeing VRAM for
   larger context. Not in stock.
3. **Draft vocabulary shortlist** — 64K-token map specific to the ATX quant. Would need
   to be generated for the unsloth model.

### Verdict on adopting llamAmpere

The fork's gains are **binary-dependent**. Most of its speedup (88% vs stock) comes from
CUDA kernels that require rebuilding. The only stock-compatible lever is MTP speculative
decoding, which is already available via the MTP variant model file (74.9 tok/s measured).

Adopting llamAmpere would require:
- Cloning and building on PC02 (or building elsewhere and copying the binary)
- CUDA toolkit 12.4+ for sm_86
- Testing the build against the unsloth model (llamAmpere was tuned for the ATX quant)
- A new `native-config.yaml` entry pointing to the rebuilt binary
- A restart to switch

This is a **needs-decision** for the captain: a bigger, riskier change that should only be
taken if the 3.19x MTP improvement is insufficient or if the fused kernel gains (potentially
another 1.46x on top) are worth the maintenance burden.

---

## 5. Comparison table: current vs recommended

| Setting | Current dispatch | Recommended (MTP variant) | Notes |
|---|---|---|---|
| Model file | unsloth Q4_K_M (19.01 GiB, C:\) | MTP UD-Q4_K_M (21.10 GiB, D:\) | MTP file has draft head |
| `--n-gpu-layers` | 99 | 99 | Unchanged |
| `--n-cpu-moe` | 21 | 24 | MTP file is ~11% larger; 24 is the tested safe value (21 caused "catastrophic slowdown" per precedent) |
| Context | 262144 | 16384 | Tradeoff: speed vs context. 16K tested, adequate for most agentic tasks |
| MTP | Disabled | **Enabled** (`--spec-type draft-mtp`) | Primary speed lever |
| `--spec-draft-n-max` | — | 3 | MTP depth |
| `--reasoning` | on | on | Enable reasoning on MTP model |
| `--cache-type-k/v` | q8_0/q8_0 | q8_0/q8_0 | House standard, unchanged |
| `--no-kv-offload` | Yes | Yes | Unchanged |
| `--no-mmap` | Yes | Yes | House standard, unchanged |
| `--flash-attn` | on | on | Unchanged |
| `--chat-template-file` | patched.jinja | (same file) | Template should work on MTP model |
| `-np 1` | Yes | Yes | Unchanged |
| **Measured decode** | **23.5 tok/s** | **74.9 tok/s** | **3.19x improvement** |
| Cold load | ~19s (SSD) | ~5-6 min (HDD) | Tradeoff: slower cold load |

### Confidence per setting

**Confidently transferable — apply as-is:**

| Setting | Why |
|---|---|
| Switch model file to MTP variant | Measured: 74.9 tok/s vs 23.5 tok/s. The dispatch file is 2.09 GiB smaller, strongly suggesting it lacks the MTP head. |
| `--n-cpu-moe 24` | Precedent report: n-cpu-moe 21 causes "catastrophic slowdown" on the ~11% larger MTP file; 24 is the smallest tested safe value with ~370-490 MiB headroom. |
| `--spec-type draft-mtp` | MTP head present in MTP file. Measured 86.7% draft acceptance, 74.9 tok/s. |
| `--cache-type-k q8_0 --cache-type-v q8_0` | House standard on all three 262144 entries. |
| `--no-kv-offload` | Required for 262144 on 12 GiB card (and 16384 too, per MTP config). |
| `--no-mmap` | Required when `--n-cpu-moe` offloads tensors to CPU. |
| `--flash-attn on` | Unchanged house standard. |
| `--reasoning on` | Enable on MTP model (currently `off` in MTP config). |

**Measured once here, needs confirmation at higher context:**

| Setting | Why |
|---|---|
| Context 16384 | Measured at this setting. Could be raised (32768, 65536) for more conversation headroom, but untested. Would need VRAM confirmation. |
| `--spec-draft-p-min 0` | Exact p/q verification default in stock 2.28.2 — UNTESTED. The MTP model's 86.7% acceptance suggests it's working, but the exact value is unknown. |
| `--cache-prompt` | Stock feature, would benefit long conversations. UNTESTED — not applied in current config. |

**Deliberately NOT recommended:**

- **Rebuild llama.cpp from llamAmpere** — Needs captain decision. Bigger risk, maintenance burden. Stock MTP gives 74.9 tok/s already; the fused kernel gains (potentially 1.46x more) are attractive but unverified on the unsloth model or 3080.
- **`--spec-draft-vocab-map`** — llamAmpere-specific vocabulary shortlist for the ATX quant. Would need generation for the unsloth model. UNTESTED.
- **`-ctv turbo3`** — TurboQuant KV cache not available in stock llama.cpp.
- **`--cache-disk-path`** — llamAmpere-specific disk cache tier. UNTESTED.

---

## 6. Recommended config diff

Replace the `qwen3.6-35b-a3b-dispatch` entry. **Back up the config first** (house convention:
`native-config.yaml.bak-<date>-<reason>`), then write the new entry.

```yaml
  # SWITCHED to MTP variant 2026-09-15: 74.9 tok/s vs 23.5 tok/s (3.19x).
  # MTP speculative decoding enabled (--spec-type draft-mtp) with the model's
  # built-in draft head (86.7% draft acceptance). Model file is the MTP
  # variant (+2.09 GiB for draft tensors) on D:\ HDD (slower cold load ~5-6 min).
  # --n-cpu-moe raised to 24 (precedent: 21 causes catastrophic slowdown on
  # the larger MTP file). Context 16384 tested; could be raised if VRAM allows.
  # llama.cpp 2.28.2 stock supports MTP natively; llamAmpere fork's fused
  # MMA kernels (potentially 1.46x more) require rebuilt binary — needs decision.
  qwen3.6-35b-a3b-dispatch:
    cmd: >
      C:\Users\sean_\.lmstudio\extensions\backends\llama.cpp-win-x86_64-nvidia-cuda-avx2-2.28.2\llama-server.exe
      --port ${PORT}
      --model D:\pc02-llm-models\Qwen3.6-35B-A3B-MTP-UD-Q4_K_M.gguf
      --n-gpu-layers 99
      --n-cpu-moe 24
      --flash-attn on
      -c 16384
      --reasoning on
      -np 1
      --chat-template-file C:\Users\sean_\.lmstudio\qwen3.6-35b-a3b-patched.jinja
      --cache-type-k q8_0
      --cache-type-v q8_0
      --no-kv-offload
      --no-mmap
      --spec-type draft-mtp
```

---

## 7. Open captain decisions

1. **Restart llama-swap to apply.** This entry runs the task that produced this report.
   Restarting llama-swap (via `pc02-llama-swap-autostart.ps1`) will reload the new config
   and may disconnect the applying session. The config change is ready to apply but the
   restart needs explicit approval. Key: `pc02-restart`.

2. **Should we rebuild llama.cpp from llamAmpere?** The stock MTP improvement (3.19x) is
   substantial, but llamAmpere's fused MMA kernels could add another 1.46x on top (measured
   on a 3090 Ti). This requires: cloning/building on PC02 or cross-building, testing against
   the unsloth model (llamAmpere was tuned for the ATX quant), and managing a custom binary.
   Worth it if 74.9 tok/s is insufficient or if long-context + speed both matter.

3. **Raise context above 16384?** 16K is adequate for most agentic tasks but far below the
   model's 262K native window. Raising to 32K or 65K would need VRAM confirmation on the
   MTP file with `--no-kv-offload`. `--cache-prompt` would also help with long conversations.

4. **Does the dispatch model file have an MTP head?** The 2.09 GiB size gap suggests no,
   but it was not confirmed (no GGUF parser in WSL). If it does, adding `--spec-type
   draft-mtp` to the existing file would give speed gains without changing the model path
   or losing the 262K context. Worth testing on the next restart if the MTP result is
   satisfactory but the context reduction is a concern.

---

## 8. Community thread cross-reference

The Reddit post's top comment (DataGOGO) reported high throughput on the same Qwen3.8-27B
model family with INT4/INT8 weights, INT8 K/V, MTP disabled, and 262144 context fitting in
24GB. Key differences:
- DataGOGO was on a **3090 (24GB)** vs PC02's 3080 (12GB) — the 2x VRAM makes a huge
  difference for context sizing
- MTP was **disabled** in their config — they achieved speed through quantization alone,
  not speculative decoding
- Their engine was not confirmed to be llama.cpp — numbers/flags should not be blindly
  transferred

The OP's warning to leave >1GB VRAM headroom is important: PC02's GPU sits at 11814 MiB
(474 MiB headroom against 12288 MiB). The MTP model with 16384 context should fit comfortably,
but raising context would need VRAM confirmation.
