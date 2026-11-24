# Panda Engine

Panda Engine is now a single local AI engine with **one public API on port 8080**. It owns
its runtimes and its model data; clients always talk to `http://127.0.0.1:8080/v1` and
Panda routes each request to the active backend. It is no longer a shortcut that opens
another product's launcher.

## Layout — everything in one folder

```
panda engine\
  panda\panda.ps1          menu, model manager, process orchestration
  panda\core\router.py     the unified API (stdlib Python, no dependencies)
  panda\state\route.json   which backend the API currently targets
  panda\catalog.json       models, paths, ports
  runtime\ninfer\          NInfer engine (real folder, used through the ninfer\ junction)
  runtime\polystrata\      Poly-strata runtime: .venv, engine-poly, serve, configs
  models\                  ALL model data: Inkling .ninfer files + polystrata-data\
  config.json              NInfer launch configuration
  START.bat                the single entry point (legacy launchers live in panda\legacy\)
```

Junctions are left at the old locations (`inkling 2 mini\ninfer`, `Poly-strata`,
`PolyStrata-data`) so older launchers keep working — Panda itself no longer depends on
them. **Gyro-S was copied into Panda without modifying the original**: model, pack, MTP and
engine binaries live in `models\gyro-s*`, `models\gyro-s-pack`, `models\gyro-s-mtp` and
`runtime\gyro-engine`. Panda starts that engine itself with `strata-gyro-s.json` — no
`strata-desktop.exe`, no loader, no external program.

## One API, internal backends

The API process owns `127.0.0.1:8080` and forwards requests (including streaming token
responses) to the active backend on an internal port:

| Backend | Internal port | Models |
|---|---|---|
| NInfer | 8181 | all Inkling 2 Mini variants |
| Poly-strata | 8182 | MiniCPM-V 4.7 35B A3B |
| Gyro engine (bundled) | 8183 | Gyro Gyro S — model + pack + engine in Panda |

Menu numbers come from `catalog.json` and are dynamic. Currently 1–5 are Inkling
variants, **6 is MiniCPM** and **7 is Gyro-S**. `GET /_panda/status` reports the active
model, its internal port and whether the backend is reachable. `X` stops the API and all
backends. `Q` closes the menu — the API keeps serving, and if `O` was used the original
OpenCode config is restored (a session that ends without `Q` is restored at next launch).

## Start

Double-click `START.bat` in the repository root — it is the only start file there. The API is started at launch.

- **First run:** pick the models to download by number, `A` for all, or `N` to skip.
  Downloads use `.part` files, resume with `curl -C -`, and are checked against
  `Content-Length` and, when available, SHA-256. The choice is saved in
  `%LOCALAPPDATA%\panda-engine\state.json`, so the first-run screen never appears again.
- **Later runs:** `S` starts the active model and repoints the API at it. Any model
  number selects another model; if it is missing, Panda offers to download it.
- `D` re-downloads models, `G` toggles MiniCPM game mode, `C` installs the OpenCode
  layer, `R` replays first-run setup, `X` stops API + backends, `Q` exits the menu.
- `O` launches **OpenCode** against the Panda API. It backs up
  `~/.config/opencode/opencode.json`, sets `model` to the active model's OpenCode ID,
  points all bundled providers at `http://127.0.0.1:8080/v1`, and starts OpenCode in a
  new terminal (CLI from PATH, or the desktop CLI). Pressing `Q` restores the original
  config byte-for-byte; the backup marker lives in `panda\state\opencode-backup.json`.
  The CLI installed on this machine is OpenCode **V1**, while the live config is V2
  (OpenChamber); `O` therefore also writes a V1-compatible view with an isolated data
  directory under `panda\state\opencode-v1*` and launches the CLI with `XDG_CONFIG_HOME`
  / `XDG_DATA_HOME` pointed there. That is what makes all Panda models — including
  `strata/gyro-gyro-s` — appear in the CLI's model picker.
- `-AutoStart` skips the menu and starts the active model; `-ResetState` replays
  first-run setup; `-DryRun` prints actions without downloading or starting anything.

### Game mode (`G`)

Only for MiniCPM (model 6). With it on, START runs Poly-strata's adaptive VRAM guard
on internal port 8182 instead of the plain server:

- fast mode: model loads on demand into the GPU, ~4 GB VRAM reserved;
- free VRAM below 11 GB for ~8 s: restart with `strata-minicpmv-q4_k_m-cpu.json`
  (RAM/SSD, 0 experts in VRAM, ~3 GB VRAM);
- free VRAM above 13 GB for ~12 s: switch back to GPU mode.

The setting persists in launcher state. The guard is stopped before any other model
starts, so it cannot resurrect a backend under the API. Turning it off stops the guard
and its server; press `S` to start MiniCPM normally. The guard's fast config is
`strata-minicpmv-q4_k_m-review.json` (64K context, 1024 MiB conversation cache) rather
than the 131072/`auto` config — the VRAM thresholds depend on that headroom. Logs:
`logs\panda-router.log` and `runtime\polystrata\strata-adaptive-guard.log`.

## Settings preserved

- Inkling: `reasoning_effort=low`, penalties 0, 131072 context,
  `--structured-output --spec none --reasoning-loop conclude`, `--vision`. Panda sets the
  context, port (8181) and selected artifact in `config.json` at every START. Running
  `panda\legacy\start.ps1` standalone instead uses whatever `config.json` currently holds,
  so its context there may differ from the Panda default.
- MiniCPM: `strata-minicpmv-q4_k_m.json` (131072 context, expert profile, conversation
  cache, vision mmproj). Paths in all three MiniCPM configs now point inside Panda.
- Gyro-S: `runtime\polystrata\strata-gyro-s.json`, using the bundled engine, pack, MTP and
  GGUF in `models\gyro-s*`; started directly by Panda, no Strata desktop.

`C` copies `config/opencode.json`, `AGENT_RULES.md` and the bundled `plugins/` into
`%USERPROFILE%\.config\opencode\`, with timestamped backups, and rewrites `instructions`
to the absolute path of the copied rules file. All three model IDs are present there;
they keep using port 8080, which is now the Panda API.

## Files

- `panda/panda.ps1` — menu, download/state logic, process orchestration, routing.
- `panda/core/router.py` — unified API and streaming proxy.
- `panda/catalog.json` — models, runtime roots, ports, game-mode files.
- `panda/settings/` — snapshot of `strata-minicpmv-q4_k_m.json`.
- `runtime/polystrata/strata-gyro-s.json` — Gyro-S config pointing only inside Panda.
- `START.bat` — the single double-click entry point (old launchers are in `panda\legacy\`).
