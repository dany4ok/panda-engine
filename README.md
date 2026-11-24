# Inkling 2 Mini — custom NInfer engine + OpenCode integration

Public snapshot of the local setup we built and benchmarked on an **RTX 5070 Ti 16 GB**.

## What this repo contains

- `start.ps1`, `START.bat` — interactive launcher for the NInfer engine (128k context, vision, DSpark off, 10-minute rolling t/s stats, watchdog that stops the server when the terminal closes).
- `START-MINI.bat` — starts the MiniCPM fallback server (set `POLY_DIR` to your Poly-strata install; default here is the original machine path).
- `bench.ps1`, `run/metrics-sampler.ps1` — benchmark and live `/metrics` sampler.
- `config.json`, `config/opencode.json` — engine settings and the OpenCode provider/model entries. `config/opencode.json` is the working config with two adaptations for reuse: `instructions` points at the bundled `AGENT_RULES.md` instead of an absolute path, and the `plugins/agent-journal` entry is now backed by the `plugins/` folder in this repo.
- `AGENT_RULES.md` — agent instructions used in the project config.
- `logs/tool-fix-evidence.txt`, `logs/final-task-evidence.txt`, `logs/bench-results.txt` — root-cause write-up and measurements.
- `benchmarks/` — harness docs and scripts, reports, validation fixtures, capture evidence, and **all** `eval.json` / `metrics.json` results from the A–F comparison. Raw `events.jsonl` transcripts are intentionally **not** included: they are ~6 MB of degenerate garbage loops and full dumps of local files, with no benchmark value. The marker evidence is summarised in `logs/tool-fix-evidence.txt`.

## The fix (short version)

Inkling 2 Mini via NInfer was fast (~150 t/s) but finished only **34/98** agentic tasks: tool calls leaked into text as `<|content_invoke_tool_json|>{...}<|end_message|>` and were never executed.

Root cause (confirmed against upstream GitHub issues): `presence_penalty: 0.5` and `frequency_penalty: 1.0` in the OpenCode request body override NInfer's tool-safe default (see `iamwavecut/ninfer-all#118`) and break multi-tool calls; `--structured-output` additionally does not engage grammar at the Inkling tool opener (`vllm#68692/#69351`).

Fix: set both penalties to **0**, keep `reasoning_effort: low`, drop `post_thinking`, keep `--structured-output --spec none --reasoning-loop conclude`.

Result: **98/98** tasks, zero raw markers. Full detail in `logs/tool-fix-evidence.txt`.

## Benchmark summary

| Model | Tasks | Total time | Raw tool markers |
|---|---:|---:|---:|
| Inkling NInfer before fix | 34/98 | 688,3 s | 8 |
| **Inkling NInfer after fix** | **98/98** | **298,6 s** | **0** |
| MiniCPM-V 4.7 35B A3B | 98/98 | 387,5 s | 0 |
| Gyro-S | 98/98 | 4663,5 s | 0 |

Per-task results are in `benchmarks/results/`. A–F per-task breakdown is in `logs/tool-fix-evidence.txt`.

**Provenance of the totals:** a total is the sum of the six per-task times shown in the table, each rounded to 0.1 s from `wall_ms` in `metrics.json` — `results/inkling_ninfer/` (7,5+13,3+10,6+356,9+7,0+293,0 = 688,3 s; raw ms sum 688452), `results/fixfinal/` with task E from `results/fixE2/` (58,5+34,5+47,8+56,8+42,8+58,2 = 298,6 s; raw ms sum 298663), `results/finalmini/` (26,2+38,2+47,0+180,8+49,7+45,6 = 387,5 s; raw ms sum 387555). The 4663,5 s Gyro-S figure comes from `benchmarks/RAPORT_FINAL_BATCH2.txt`. The 34/98 figure comes from `logs/tool-fix-evidence.txt`; ~150 t/s from `logs/bench-results.txt`. The 8 raw markers before the fix are the sum of per-task counts in the pre-fix transcripts: A 1, B 1, C 1, D 3, E 1, F 1 (those transcripts are excluded from this repo; the post-fix zero-marker counts are recorded in `logs/tool-fix-evidence.txt:17-22`).

## Not included (too large)

- `ninfer/` engine binaries (~GBs) — download the release from `https://github.com/iamwavecut/ninfer-all/releases/tag/2026-11-23.10` (Windows CUDA 13.4 build).
- `models/*.ninfer` — download from Hugging Face:
  - `WaveCut/Inkling-2-Mini-UD-IQ1_M-NInfer-v3`
  - `WaveCut/Inkling-2-Mini-UD-Q2_K_XL-NInfer-v3`
  - `WaveCut/Qwen3.8-27B-GSQ-RCO-IQ3_S-NInfer-v3`

Some files in `benchmarks/` still contain absolute paths from the original machine (notably `HARNESS.md`); adapt them if you reuse the harness. API keys in `config/opencode.json` are placeholders (`*-local-token`), not real secrets.

## Reproduce

1. Download the NInfer Windows CUDA 13.4 release and extract it into `ninfer/`.
2. Download the GGUF/NInfer artifacts into `models/`.
3. Copy `config/opencode.json` to `~/.config/opencode/opencode.json` and `AGENT_RULES.md` and `plugins/` next to it.
4. Run `START.bat`, choose `1`, press Enter for defaults.
5. Run the A–F probes with `benchmarks/scripts/run_probe.ps1`, e.g. `-Model ninfer/inkling-2-mini -NoSub -Task A -Batch myrun`. The script derives its harness root from its own location, so `tasks/`, `config/` and `scripts/` are found automatically; pass `-OpencodeExe` if the bundled desktop CLI is not present (otherwise `opencode` from PATH is used).
