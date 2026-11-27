# Panda Engine

Panda Engine is now a single local AI engine with **one public API on port 8081**. It owns
its runtimes and its model data; clients always talk to `http://127.0.0.1:8081/v1` and
Panda Engine routes each request to the active backend. It is no longer a shortcut that opens
another product's launcher.

## Layout — everything in one folder

```
panda engine\
  panda\gui.ps1            default Windows desktop UI: Model Library
  panda\panda.ps1          console menu, model manager, process orchestration
  panda\core\router.py     the unified API (stdlib Python, no dependencies)
  panda\state\route.json   which backend the API currently targets
  panda\catalog.json       models, paths, ports
  runtime\ninfer\          NInfer engine (real folder, used through the ninfer\ junction)
  runtime\panda\      Panda Engine runtime: .venv, engine-poly, serve, configs
  models\                  ALL model data: Inkling .ninfer files + panda-data\
  config.json              NInfer launch configuration
  panda.exe                the desktop launcher (icon: panda.ico); START.bat forwards to it
```

Junctions are left at the old locations (`inkling 2 mini\ninfer`, `Panda Engine`,
`Panda Engine-data`) so older launchers keep working — Panda Engine itself no longer depends on
them. **Gyro-S was copied into Panda Engine without modifying the original**: model, pack, MTP and
engine binaries live in `models\gyro-s*`, `models\gyro-s-pack`, `models\gyro-s-mtp` and
`runtime\gyro-engine`. Panda Engine starts that engine itself with `panda-gyro-s.json` — no
`panda-desktop.exe`, no loader, no external program.

## One API, internal backends

The API process owns `127.0.0.1:8081` and forwards requests (including streaming token
responses) to the active backend on an internal port:

| Backend | Internal port | Models |
|---|---|---|
| NInfer | 8181 | all Inkling 2 Mini variants |
| Panda Engine (MiniCPM runtime) | 8182 | MiniCPM-V 4.7 35B A3B |
| Gyro engine (bundled) | 8183 | Gyro Gyro S — model + pack + engine in Panda Engine |

The catalog currently contains two Inkling variants, MiniCPM and Gyro-S. `panda.exe`
opens the desktop Model Library; `panda.exe --console` opens the legacy text menu.
`START.bat` is kept as a thin wrapper around `panda.exe`.
`GET /_panda/status` reports the active model, its internal port and whether the backend
is reachable. In the GUI, selecting a row only inspects it; **Set active** changes the
next-start selection, while **Start** changes the live route. Switching a running model
can stop its current backend. **Stop engine** stops the API and all backends.

## Start

Double-click `panda.exe` in the repository root to open the Model Library and start the
Panda Engine API. Use `panda.exe --console` to open the legacy text menu.

- **First run:** browse the catalog and use **Install** on a model you want. Downloads use
  `.part` files and resume with `curl -C -`. A file is accepted only when its size matches
  the remote (when the server publishes it) **and** it also passes SHA-256 verification
  (when available) or a byte-prefix comparison against a ranged GET. When neither proof
  is available the download fails instead of installing an unverified file. Installing
  does not automatically start a model.
- **Model Library:** search or filter the four catalog entries, inspect model/provider
  details, set a model active for the next start, or start an installed model. Status
  distinguishes installed, selected-for-next-start and a backend confirmed healthy by
  `GET /_panda/status`. No model size or performance estimates are shown.
- **Console mode:** `S` starts the active model and repoints the API at it. Any model
  number selects another model; if it is missing, Panda Engine offers to download it.
- `D` re-downloads models, `G` toggles MiniCPM game mode, `R` replays first-run setup,
  `X` stops API + backends, `Q` exits the menu.
- `O` launches **OpenCode** against the Panda Engine API. It backs up
  `~/.config/opencode/opencode.json`, sets `model` to the active model's OpenCode ID,
  points the Panda Engine-managed providers declared in `panda/catalog.json`
  (`ninfer`, `panda-mini` and `panda`) at `http://127.0.0.1:8081/v1`; every other
  provider (Ollama, Strata, PolyStrata, ...) keeps its own endpoint. It leaves the bundled Ollama
  entry on `http://127.0.0.1:11434`, and starts OpenCode in a
  new terminal (CLI from PATH, or the desktop CLI). Pressing `Q` restores the original
  config byte-for-byte; the backup marker lives in `panda\state\opencode-backup.json`.
  The CLI installed on this machine is OpenCode **V1**, while the live config is V2
  (OpenChamber); `O` therefore also writes a V1-compatible view with an isolated data
  directory under `panda\state\opencode-v1*` and launches the CLI with `XDG_CONFIG_HOME`
  / `XDG_DATA_HOME` pointed there. That is what makes all Panda Engine models — including
  `panda/gyro-gyro-s` — appear in the CLI's model picker.
- `-AutoStart` skips the menu and starts the active model; `-ResetState` replays
  first-run setup; `-DryRun` prints actions without downloading or starting anything.
  These are console-mode switches: passing any of them to `panda.exe` routes the
  launcher to `panda.exe --console` so the flag is not silently discarded.

### Game mode (`G`)

Only for MiniCPM. With it on, START runs Panda Engine's adaptive VRAM guard
on internal port 8182 instead of the plain server:

- fast mode: model loads on demand into the GPU, ~4 GB VRAM reserved;
- free VRAM below 11 GB for ~8 s: restart with `panda-minicpmv-q4_k_m-cpu.json`
  (RAM/SSD, 0 experts in VRAM, ~3 GB VRAM);
- free VRAM above 13 GB for ~12 s: switch back to GPU mode.

The setting persists in launcher state. The guard is stopped before any other model
starts, so it cannot resurrect a backend under the API. Turning it off stops the guard
and its server; press `S` to start MiniCPM normally. The guard's fast config is
`panda-minicpmv-q4_k_m-review.json` (64K context, 1024 MiB conversation cache) rather
than the 131072/`auto` config — the VRAM thresholds depend on that headroom. Logs:
`logs\panda-router.log` and `runtime\panda\panda-adaptive-guard.log`.

## Settings preserved

- Inkling: `reasoning_effort=low`, penalties 0, 131072 context,
  `--structured-output --spec none --reasoning-loop conclude`, `--vision`. Panda Engine sets the
  context, port (8181) and selected artifact in `config.json` at every START. Running
  `panda\legacy\start.ps1` standalone instead uses whatever `config.json` currently holds,
  so its context there may differ from the Panda Engine default.
- MiniCPM: `panda-minicpmv-q4_k_m.json` (131072 context, expert profile, conversation
  cache, vision mmproj). Paths in all three MiniCPM configs now point inside Panda Engine.
- Gyro-S: `runtime\panda\panda-gyro-s.json`, using the bundled engine, pack, MTP and
  GGUF in `models\gyro-s*`; started directly by Panda Engine, no Panda Engine desktop.

The OpenCode config layer is copied manually: `config/opencode.json`, `AGENT_RULES.md`
and the bundled `plugins/` go into `%USERPROFILE%\.config\opencode\`. The old console `C`
shortcut was removed because it overwrote custom OpenCode configuration. All model IDs
are present there; they use port 8081, which is the Model Library API.

## Files

- `panda/gui.ps1` — default desktop Model Library UI.
- `panda/panda.ps1` — console menu, download/state logic, process orchestration and GUI actions.
- `panda/core/router.py` — unified API and streaming proxy.
- `panda/catalog.json` — models, runtime roots, ports, game-mode files.
- `panda/settings/` — snapshot of `panda-minicpmv-q4_k_m.json`.
- `runtime/panda/panda-gyro-s.json` — Gyro-S config pointing only inside Panda Engine.
- `panda.exe` — the double-click entry point, with `panda.ico` (old launchers are in `panda\legacy\`); `START.bat` forwards to it.
- Rebuild — `powershell -NoProfile -ExecutionPolicy Bypass -File panda\build-launcher.ps1` recompiles `panda.exe` from `panda\panda-launcher.cs` with `panda.ico` embedded (the default output is the tracked `panda.exe`, so it overwrites it; pass `-Out <path>` to build elsewhere). `python panda\make_panda_icon.py` regenerates `panda.ico` and `panda.png`.
