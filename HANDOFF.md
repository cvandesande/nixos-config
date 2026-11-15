# HANDOFF — nomad strata: prefill (and what decode already told us)

Written 2026-11-14 from a session that measured nomad's serving setup end to end.
Goal for the next session: **attack prefill (TTFT)**, with decode's ceiling already pinned down so
nobody re-derives it.

Repo note: this file lives in a **public** repo. No API key, no serials, no host-specific secrets
here. The key is read at runtime (see *Talking to the engine*).

---

## 1. TL;DR

| | value | source |
| --- | --- | --- |
| Decode ceiling (theory) | **~46 tok/s** | 2.4 GiB/token floor ÷ 119.5 GB/s bus |
| Decode measured | **16.6–22.0, median 18.2** | `strata bench` standard-v1, this session |
| Effective bandwidth used by decode | ~42 GB/s (**35% of peak**) | 17.4 tok/s × 2.58 GB |
| **Prefill measured** | **207 tok/s @4K, 334 tok/s @16K** | same run |
| **TTFT measured** | **4.2 s / 19.8 s / 49.2 s** (short / 4K / 16K) | same run |
| Prefill on a discrete Arc Pro B70, same model | **888–1,006 tok/s** | `/tmp/strata-docs/INTEL.md` |

Decode is ~2/3 of the way to a realistic target and is bounded by a hard bytes floor — there is not
much left there. **Prefill is 3–5× behind a discrete Arc card and it is what the user actually feels**
(49 s to the first token on a 16K prompt). Attack prefill.

---

## 1b. Update, same evening — prefill moved +31% / +9.5% with two env vars

E3 was the answer, E1/E2 were not. The fused int8 prompt experts are gated in `INTEL.md` on *"a
Battlemage GPU (B70, B580, B570, detected by device architecture)"*. Xe3 / Panther Lake is none of
those, so `STRATA_PREFILL_MMQ` `auto` leaves the FP16 chain running here. Forcing it, plus zeroing the
prompt loan so it does not cost expert slots:

```text
STRATA_PREFILL_MMQ=1  STRATA_PREFILL_LEND_PCT=0
```

Fresh engine per arm, frozen synthetic corpus, 2-3 interleaved reps, engine's own `timings`
(harness `~/strata-bench/probe.py`, one line per arm in `probes.jsonl`):

| arm | 4K tok/s | 4K TTFT | 16K tok/s | 16K TTFT | decode tok/s | expert slots | mirror |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| defaults today (`--prefill auto`, MMQ auto) | 328.9 | 12.88 s | 394.9 | 42.63 s | 16.6 | 23358 | 3.25 GiB |
| `MMQ=1` alone | 421.2 | 10.23 s | 431.5 | 38.50 s | 16.4 | 19057 | 9.04 GiB |
| **`MMQ=1` + `LEND_PCT=0`** | **431.9** | **9.88 s** | **432.4** | **38.41 s** | **16.9** | **24576** | **1.61 GiB** |
| `MMQ=1` + `--prefill auto:16384` (E2) | 424.3 | 9.8 s | 423.1 | 38.89 s | – | 20303 | 7.36 GiB |
| `MMQ=1` + `STREAM_ALL=1` + `FIRST=256` | 350.6 | 15.85 s | 396.4 | 44.77 s | 16.7 | 20084 | 7.65 GiB |

Read it as: 4K prompt +31% and TTFT −23%, 16K +9.5% and TTFT −10%, decode unmoved, and E1's success
criterion met by `LEND_PCT=0` rather than by `--no-prefill-borrow` (that flag is not in this engine;
`STRATA_PREFILL_LEND_PCT=0` is what #5943 used and it drops the `the prompt path borrows N slots`
line entirely, back to the residual 1200 mirrored experts). Bigger chunks are worthless here and
forced `STREAM_ALL` is a real regression: with the int8 path pushing gigabytes into the mirror,
walking the whole mirror per chunk costs more than it saves.

Caveats, all of them cost me an arm:
- **`--set` merges into the preset in the volume and an empty value cannot clear it**, so arms leak.
  Prune `~/strata-data/config/strata/launch-presets/docker.json`'s `extra` between arms
  (`ab.sh` now does this) or you are benchmarking the previous arm.
- The plan is **not reproducible run to run**: identical flags landed the cache at both 24576 and
  22020 slots, tracking the RAM the driver is holding (`/proc/meminfo` `GPUActive` reads 44 GB with
  45 GB of RAM, the #2412 accounting oddity). `page_pool_size` is already 0 here, so #2412's TTM
  cap is not the lever on this box.
- Quality: four spot checks (code, German, arithmetic, a needle at ~2.5K) came back **identical** to
  the FP16 chain, including the same wrong `36` on the arithmetic one. Not a KL measurement —
  `strata bench` sanity is still the thing to run before trusting this in anger.
- Env propagation is confirmed end to end (read `/proc/<pid>/environ` of the engine in the container:
  every `STRATA_SET` key is there). That closes the open question in *Changing a knob* — the missing
  `strata-sycl.sh` does not block env, only the wrapper's own defaults.

Still open, and now the only real remaining gap: 432 tok/s against the Arc Pro B70's 888-1,006 on the
same pack. The SYCL port never got `qsa_prompt_attn`, `qsa_select`'s block scores or
`native_qsa_score` (inline PTX, "takes the older card fallback the CUDA build uses below sm_80") and
prompt attention plus QSA select were 19.2% + 6.8% of B70 prompt time — so the rest of the gap is
kernels, not knobs. `STRATA_PREFILL_TIMING=1` would say where the time actually goes on this GPU.

## 1c. 2026-11-15 — the Q2_0 switch was a loss: the kernel, not the byte count

Q2_0 was expected to be faster (MODELS.md lists it as *fastest*) and measured slower. Same engine,
same `STRATA_SET`, same frozen corpus, `probe.py` on the live engine, 2 reps:

| pack | 4K tok/s | 4K TTFT | 16K tok/s | decode tok/s | slots | mirror |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| IQ2_XS (`MMQ=1` + `LEND_PCT=0`, §1b) | 431.9 | 9.88 s | 432.4 | 16.9 | 24576 | 1.61 GiB |
| **Q2_0, same flags** | **355.3** | **11.76 s** | **360.0** | **12.9** | 24576 | 1.54 GiB |

(`probes.jsonl` label `q2_0-live`.) The byte saving is real but small: shard 1 is 35.88 GB against
37.41 GB, shard 2 is byte-identical, and per routed expert it is 1.382 MB against 1.443 MB — 4%.

The mechanism is the format coverage, not memory. The fused int8 prompt path covers gate/up
`IQ3_S, IQ3_XXS, IQ2_S` and down `IQ4_NL, Q2_0` (`INTEL.md:227`). Q2_0's gate/up rows are ggml type 42
and are not in that list, so every layer answers `int8 path no` and takes the FP16 chain, which reads
each expert as ~10 MB of FP16 (`QUANTS.md`):

```text
Q2_0   gate/up type 42, down type 42 -> int8 path no   (all 48 layers)
IQ2_XS gate/up type 22, down type 42 -> int8 path yes  (34 layers; 11 type 16, 3 type 29 answer no)
```

So `STRATA_PREFILL_MMQ=1` is inert for a Q2_0 pack even though the engine prints "int8 prompt experts
are on" — the decision is logged per layer afterwards. Decode also fell (12.9 against 16.9), which is
not explained by any kernel note I have; the Q2_0 CPU row kernel is AVX2 `q2_0_gguf_rows_multi`.

Confounding factor for any rerun: the 11:24 Q2_0 start landed 17,978 slots / 10.04 GiB mirror and read
a fresh 16K prompt at 190-265 tok/s; the 11:31 start landed the full 24576 / 1.54 GiB. Measure on a
start that got the whole cache (`ab.sh` waits for MemAvailable >= 38 GB for this reason).

Back to IQ2_XS in `hosts/nomad/strata.nix`. Both packs stay on disk.

## 2. The box and the running config

Framework Laptop 13 Pro, Core Ultra X7 358H (Panther Lake, **no AVX-512**), Arc B390 **iGPU**
(`8086:b082`, `xe` driver), 64 GB LPCAMM2.

```text
Memory Device  LPDDR5 Micron MTD32C20326N8FN023F1  64 GiB  128-bit (one CAMM, 2x64)
  Speed: 8533 MT/s                     <- module rating
  Configured Memory Speed: 7467 MT/s   <- what the firmware runs (Framework/Intel cap for 358H)
  => theoretical bus = 7467 * 16 = 119.5 GB/s, shared by CPU and iGPU (no discrete VRAM)
```

Check with `nix-shell -p dmidecode --run 'sudo $(which dmidecode) -t17'` (`dmidecode` is not
installed in the system). Achieved bus bandwidth measured with a 16-thread `zlib.crc32` probe:
**~60–64 GB/s** — but that probe swings ±2× between runs and is CPU-limited (~4.5 GB/s/core), so
treat it as a floor on the bus, not a number.

Engine (`hosts/nomad/strata.nix`, rootless podman via the system unit `podman-strata.service`):

```text
image ghcr.io/niko1221/strata:latest-sycl     engine 0.1.59-linux-x86_64-sycl (strata 628f749)
--pack packs/iq2_xs --native <shard1> --ple-gguf <shard2>
--expert-profile expert-profile.bin --expert-cache 24576 --stream-experts
--prefill auto --spec 6 --spec-min-p 0.5 --max-context 262144 --kv k8v4 --vram-reserve-mib 2048
env STRATA_VERIFY_NO_HOST=1 STRATA_VERIFY_DEVICE_PLAN=1 STRATA_KV_GROW=1
    STRATA_WATCHDOG_S=600 SYCL_CACHE_PERSISTENT=0
```

Model (`qwen4exp` in the GGUF header): 48 layers, 512 experts/layer, **10 active/token**, expert FFN
640, hidden 2560, `full_attention_interval = 4` (12 of 48 layers are full attention), KV heads 2 ×
head_dim 256, sparse indexer (4 heads × 128, `top_k = 2048`), ctx 262144. Files: 36.5 GiB native
shard + 25.6 GiB PLE shard (320,001,536 rows ≈ 86 B/row).

Startup facts worth knowing (from `~/strata-data/state/strata/launch/docker.engine.log`):

```text
PCIe probe: 13.1 GB/s host->device -> pcie_frac 0.36   <- a FICTION on an iGPU, there is no link
expert cache 24576 slots, 33.02 GiB of VRAM           <- 512 x 48 = 24576 = EVERY expert
pre-filled 24576 of 24576 slots from the profile in 23.5 s
1200 of 0 experts missing from VRAM (+ 1200 in the prompt loan's slots)
        mirrored in pinned host memory (1.61 GiB); the GPU reads them over PCIe
the prompt path borrows 2419 CUDA0 cache slots (3.25 GiB)
300 native projection matrices, 1474.85 MiB of weights
experimental native Q5_K head, 337715200 bytes
token embedding IQ4_XS in mapped host memory (322 MiB)
prompt chunk auto: 8192 tokens, a 96-slot ring
```

Note `expert cache auto ... (+0 MiB for the draft head)` in older starts and `drafting: mtp` in the
launch config, while `INTEL_ARC.md` says *"the draft layer (MTP) is not built for Intel cards"*.
So the drafter that is actually running is the suffix/n-gram one — see experiment E5.

## 3. Talking to the engine

```sh
llm-start / llm-stop / llm-status     # systemctl unit, start+stop need sudo
llm-logs                              # journalctl -u podman-strata -f
llm-engine                            # engine log, follow
llm-key                               # prints the current API key (do NOT paste it into the repo)
```

Server: `http://127.0.0.1:8081/v1` (container binds 0.0.0.0:8080, only loopback is published).
Non-secret way to use the key without putting it in a file:

```sh
export STRATA_API_KEY=$(python3 -c 'import json;print(json.load(open(
  "/home/cvandesande/strata-data/state/strata/launch/docker.json"))["api_key"])')
```

**This agent session is NOT served by this engine** — pi runs on `halogen` (`http://liltig:8731/v1`),
so benchmarking nomad's strata cannot starve the session doing the benchmarking. Verify with
`ss -tnp | grep 8081` before a run if unsure.

Docs (the project's own, cloned here): `/tmp/strata-docs/{DETAILS.md,INTEL.md,INTEL_ARC.md,
SETTINGS.md,DOCKER.md,QUANTS.md,...}` — `/tmp` is on the root fs but systemd-tmpfiles will age them
out; no persistent copy exists under `~`. **Copy them somewhere durable before you need them.**

### Changing a knob

Two routes, and the second is unverified:

1. **Declarative**: `STRATA_SET` in `hosts/nomad/strata.nix` (`--set` keys only: `expert-cache`,
   `spec`, ...), then rebuild. `--set` merges per key; an empty value cannot clear a stored one
   (`--delete-preset` does).
2. **Live, for experiments**: the launch config is
   `~/strata-data/state/strata/launch/docker.json` (→ `/data/...` in the container); it has
   `user_args` (currently `["--expert-cache","24576","--spec","6"]`) and `env` (the `STRATA_*`
   list above). Add a flag/entry there, then `llm-stop; llm-start`.
   **Verify it survives** — the entrypoint rewrites the config from the container environment on
   every start, so your edit may be reverted; confirm with `cat` after the restart. `strata profile`
   and `strata presets` (inside the container: `podman exec strata strata ...`) are the supported
   editors of the same stored settings. The image has **no `strata-sycl.sh`** (upstream #515), so
   the documented "the config's `env` block reaches the engine" path may not apply here — test that
   a `STRATA_*` var you set actually shows up as a log line before believing an A/B.

## 4. The bench that produced these numbers

```sh
mkdir -p ~/strata-bench && cd ~/strata-bench
export STRATA_API_KEY=$(python3 -c '...')   # as above
strata bench run --url http://127.0.0.1:8081 --credential-env STRATA_API_KEY \
  --quantization IQ2_XS \
  --custom-pack "ISTA-DASLab Qwen3.8-Flash-Next-GSQ-RCO IQ2_XS, expert-profile.bin, expert-cache 24576, kv k8v4, spec 6, 262144 ctx" \
  --track custom --track-notes "nomad: Framework Laptop 13 Pro, X7 358H, Arc B390 iGPU (SYCL), 64GB LPCAMM2 LPDDR5x @7467, engine 0.1.59, balanced profile"
```

Took **14 min 24 s** for 22 requests. Output:
`~/strata-bench/bench-results/2026-11-14-standard-cpu-84a87415/{README.md,results.json,outputs.jsonl}`

| Case | Prompt tok/s | Decode tok/s | TTFT | First answer | Total |
| --- | --- | --- | --- | --- | --- |
| short (~80 tok) | n/a | 16.7 (16.6–16.7) | 4.19 s | 11.7 s | 21.9 s |
| prompt-4k | 207.1 (203.6–207.5) | 16.8 (16.6–17.2) | 19.8 s | 45.7 s | 50.3 s |
| prompt-16k | 333.6 (323.9–336.5) | 17.4 (17.1–18.9) | 49.2 s | 65.0 s | 78.6 s |

All 22 requests: decode min 16.6, **median 18.2**, p75 20.0, max 22.0. Sanity **12/12 pass**.
Marked *nonconforming* for two cosmetic reasons only: the model files could not be hashed (read-only
`/models` in the container) and hardware inventory printed `GPU: not measured` (folder name
`...-standard-cpu-...`). Both are the bench not knowing this is an iGPU.

Side observation from the same logs: decode barely depends on context (16.7 at ~80 tokens, 17.4 at
16K, and 16–20 in existing 100k+ chat traffic) → per-token traffic is context-independent, the
top_k=2048 indexer is doing its job, and **weights are the whole cost**.

## 5. Why decode is where it is (done, don't redo)

Per generated token:

| | bytes |
| --- | --- |
| 480 expert blobs (10 × 48 layers) × 1.37 MiB avg | 0.64 GiB |
| 300 native projection matrices (delta-net, attention, indexer, shared experts) | 1.44 GiB |
| Q5_K output head | 0.32 GiB |
| PLE rows (~86 B × a few dozen) + one embedding row | negligible |
| **floor** | **~2.4 GiB = 2.6 GB** |

Speculation amortizes almost none of that: a 900-token request reported
`predicted_n: 900, draft_n: 10, draft_n_accepted: 8` — essentially one full weight read per token.

`119.5 GB/s ÷ 2.6 GB = 46 tok/s` is the wall. At 16–17 tok/s strata moves ~42 GB/s, i.e. **35% of
the bus**, so the gap is engine-side gather/launch efficiency on a path `INTEL_ARC.md` explicitly
lists as untested ("integrated Arc GPUs (the B390 / Panther Lake in #515; shared-memory planning
does not exist)"), not memory bandwidth. Corroboration from the docs, same IQ2_XS pack: Arc Pro B70
51–64 tok/s (560 GB/s), 2×B60 58–61 tok/s, B580 ~21 tok/s — nomad's 17 sits on the bandwidth line.

The one decode lever with real headroom is **hit rate on the 13 GB/s mirror path** — see E1, which
is also a prefill experiment.

## 6. The problem to attack: prefill / TTFT

- 207 tok/s at 4K, 334 tok/s at 16K, and long real prompts run 248–277 tok/s.
- Reference for the same model on one Arc Pro B70: **888–1,006 tok/s** (128K/256K, `INTEL.md`).
- TTFT 4.2 s / 19.8 s / 49.2 s is the daily irritant, and long-context agents pay it on every cold
  prompt (prompt reuse helps: a repeat reuses ~131k of 134k tokens at ~250–330 tok/s for the tail).
- The first request after a start sometimes stalls 40–61 s at prompt layer 0 and aborts
  (SIGABRT, exit −6); warm it up and keep the container up (already noted in `strata.nix`).
- Cold start is ~24 s just to fill the 33 GiB cache at 1.51 GB/s, and `SYCL_CACHE_PERSISTENT=0`
  (required, the persistent JIT cache segfaults on Xe2) means kernels JIT each start.

### Hypotheses, ranked by expected payoff

**E1 — the prompt path is evicting experts onto the 13 GB/s mirror path.**
The cache is *exactly* the model size (24576 slots = every expert) and `the prompt path borrows
2419 CUDA0 cache slots (3.25 GiB)` — and the log shows `1200 ... experts missing from VRAM
(+ 1200 in the prompt loan's slots) mirrored in pinned host memory`. `INTEL.md`: without borrow,
~1,000–2,300 experts move to the pinned mirror, prompt +2–5% and decode 10–23% slower **on a card
whose mirror is real PCIe**; nomad's mirror path probes at 13.1 GB/s and its miss rates in chat logs
run 95.6–99.9%. Try, one at a time:
  - `--no-prefill-borrow` in `user_args`;
  - free room for prompt buffers instead: `--max-context 131072` (KV 5.6 → ~2.8 GiB) or
    `--vram-reserve-mib 4096`, then check whether the "missing from VRAM" line goes to 0.
  Metric: `grep -o "decode expert cache hit rate: [0-9.]*%" <engine log>` before/after, plus
  decode tok/s. A 3–4% miss rate is ~21 experts × 1.51 MB ≈ 30 MB/token on a 13 GB/s path ≈
  2.4 ms/token ≈ **−30% decode**. This is the single most promising experiment on the box.

**E2 — prefill chunk size.** `--prefill auto` picks 8192 here. `DETAILS.md` shows chunk changes
worth 12–146% on 20K prompts on other cards (`--prefill 16384` / `32768`, or
`STRATA_PREFILL_AUTO_MAX`; Intel Arc is listed as honouring it). Chunk buffers cost cache slots
(~700 at 4096, and 2419 borrowed at 8192 today), so this interacts with E1 — measure them together.
Also look at `--prefill-head-alias` (+128% prefill on a VRAM-starved card in the docs) and
`--prefill-borrow`.

**E3 — Intel-Arc prefill switches, all currently at defaults:** `STRATA_PREFILL_MMQ` (auto on
Battlemage = fused int8 prompt experts), `STRATA_PREFILL_FIRST` (256 only when the cache holds
every expert — which is true here), `STRATA_PREFILL_STREAM_ALL` (on above 90% residency),
`STRATA_PREFILL_ISSUER`, `STRATA_PREFILL_STREAM_MIN`, `STRATA_PF_FUSED` (+12% at 4K on IQ2_XS on
CUDA, unknown on SYCL), `STRATA_PF_GEMM`. Force each to `0`/`1` and measure prompt tok/s at 4K/16K.
First prove env propagation (see *Changing a knob*).

**E4 — the fake PCIe model.** `pcie_frac 0.36` came from a 13.1 GB/s probe of a path that does not
exist. `--pcie-frac N` "always wins" per `DETAILS.md`; `STRATA_PCIE_FRAC_DEFAULT`,
`STRATA_PCIE_K_RULE=0`, `STRATA_PCIE_SHARE_MAX` also exist. Only meaningful once mirror traffic
exists, so do this after E1.

**E5 — the drafter.** MTP is reportedly not built for Intel cards and the log shows `+0 MiB for the
draft head`, so we are on suffix drafts with `--spec 6`. Sweeping `--spec 2..8` and trying
`STRATA_SPEC_COUPLED` / `STRATA_SPEC_GUMBEL` (+9% in the docs) is cheap. `strata drafting` documents
a DFlash2 drafter, but `strata.nix` already notes a dflash2 start collapses the cache to
6012–10169 slots here — on this box that means experts onto the slow path, so almost certainly a net
loss unless E1 says otherwise.

**E6 — let the tool sweep.** `strata tune auto` finds the fastest settings for the PC and saves a
preset (~20 min). Snapshot the config first:
`cp ~/strata-data/state/strata/launch/docker.json ~/strata-bench/snap-$(date +%F)/`, and be ready
with `strata tune rollback`. Use `strata bench run` as the yardstick and `strata bench compare` for
two saved runs.

## 7. Measurement rules (so A/Bs mean something)

1. **One engine at a time.** Decode keeps 47 GiB resident, 15 GiB free — a second engine will not fit.
2. Warm up first (throwaway request); never compare against a cold engine.
3. Interleave pairs, ≥3 reps, same frozen prompts. `strata bench run --url ...` is ~14 min; the
   serving suites (`--suite serving-smoke --repeat 2`) are quicker for a single knob.
4. Record hit rates and the `missing from VRAM` line with every number:
   `grep -oE "(expert cache hit rate: [0-9.]+%|[0-9]+ of [0-9]+ experts missing)" <log>`.
5. Per-request timings come free from the SSE `timings` block
   (`prompt_per_second`, `predicted_per_second`, `draft_n`, `draft_n_accepted`).
6. Do **not** trust a home-made bandwidth probe: my `zlib.crc32` probe varied 10→64 GB/s depending on
   thread count and CPU state, and a probe with all cores busy starves the engine (decode fell to
   ~0.1 tok/s while a 16-thread probe ran). A proper STREAM test needs a compiler; there is no
   `cc`/`gcc` on this box (`nix-shell -p ...` instead).
7. Power: `powerprofilesctl get` should be `balanced` or `performance` on AC; the unit drops to
   `power-saver` on battery and memory/GPU clocks go down with it.

## 8. Known constraints (do not rediscover the hard way)

- `SYCL_CACHE_PERSISTENT=0` is mandatory (persistent JIT cache segfaults on Xe2).
- Never ask for more "VRAM" than fits: on `xe` an over-allocation evicts buffers to host RAM and can
  livelock the machine until the watchdog resets it. Leave ~1.5–2 GiB free (`--vram-reserve-mib 2048`).
- `--stream-experts` + `STRATA_VERIFY_NO_HOST=1`: no SSD expert tier — every expert must be in the
  cache or the pinned mirror or the engine refuses to start.
- IQ packs refuse `--spec 0/1`; speculative decoding cannot be disabled.
- The image entrypoint only reads a fixed env list (`MODEL FAMILY MODEL_PATH CONTEXT PARALLEL KV
  VISION GPUS GPU_ROLES TUNE TUNE_ALLOW_SMALL PRESET PORT STRATA_SET`); `--access` and `--drafting`
  are not settable through env here.
- 256K is real but expensive to first token; `k8v4` costs 2–5% on prompts and buys ~1100 expert
  slots — if you lower `--max-context` for E1, re-check the quality of long-context behaviour you
  were relying on.

## 9. What would count as an answer

- E1 succeeds if the `missing from VRAM` line reaches 0 and hit rate is ≥99.9% — then report the
  decode delta; if decode moves >5%, the eviction is real and worth a permanent config change.
- A prefill win is prompt-4k/prompt-16k tok/s and TTFT from two `strata bench` runs compared with
  `strata bench compare`; ≥10% with 3 reps and matching sanity (12/12) counts.
- If nothing moves, the honest conclusion is that the SYCL engine's Xe3 prefill path is simply ~3×
  behind CUDA/MMQ and the fix is upstream (shared-memory planning for the B390), not a knob.
