# Inkling 2 Mini — custom NInfer engine + OpenCode integration

Public snapshot of the local setup we built and benchmarked on an **RTX 5070 Ti 16 GB**.

## What this repo contains

- `start.ps1`, `START.bat` — interactive launcher for the NInfer engine (128k context, vision, DSpark off, 10-minute rolling t/s stats, watchdog that stops the server when the terminal closes).
- `START-MINI.bat` — starts the MiniCPM fallback server.
- `bench.ps1`, `run/metrics-sampler.ps1` — benchmark and live `/metrics` sampler.
- `config.json`, `config/opencode.json` — engine settings and the OpenCode provider/model entries.
- `AGENT_RULES.md` — agent instructions used in the project config.
- `logs/tool-fix-evidence.txt`, `logs/final-task-evidence.txt`, `logs/bench-results.txt` — root-cause write-up and measurements.
- `benchmarks/` — harness docs, reports and **all** `eval.json` / `metrics.json` / `events.jsonl` results from the A–F comparison.

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

## Not included (too large)

- `ninfer/` engine binaries (~GBs) — download the release from `https://github.com/iamwavecut/ninfer-all/releases/tag/2026-11-23.10` (Windows CUDA 13.4 build).
- `models/*.ninfer` — download from Hugging Face:
  - `WaveCut/Inkling-2-Mini-UD-IQ1_M-NInfer-v3`
  - `WaveCut/Inkling-2-Mini-UD-Q2_K_XL-NInfer-v3`
  - `WaveCut/Qwen3.8-27B-GSQ-RCO-IQ3_S-NInfer-v3`

Local absolute paths in the configs point to this machine; adapt them if you reuse the setup. API keys in `config/opencode.json` are placeholders (`*-local-token`), not real secrets.

## Reproduce

1. Download the NInfer Windows CUDA 13.4 release and extract it into `ninfer/`.
2. Download the GGUF/NInfer artifacts into `models/`.
3. Copy `config/opencode.json` to `~/.config/opencode/opencode.json`.
4. Run `START.bat`, choose `1`, press Enter for defaults.
5. Run the A–F probes from `gyro-mini-bench/scripts/run_probe.ps1` with `-Model ninfer/inkling-2-mini -NoSub`.
