# Panda Engine

A single terminal launcher for the three local models configured on this machine:

| Key | Model | Engine | OpenCode ID | Endpoint |
|---|---|---|---|---|
| 1 | Inkling 2 Mini (IQ1_M) | NInfer | `ninfer/inkling-2-mini` | `127.0.0.1:8080` |
| 2 | Inkling 2 Mini (Q2_K_XL) | NInfer | `ninfer/inkling-2-mini` | `127.0.0.1:8080` |
| 3 | MiniCPM-V 4.7 35B A3B | Poly-strata | `polystrata-mini/minicpm-v-4.7-35b-a3b-q4_k_m` | `127.0.0.1:8080` |
| 4 | Gyro Gyro S | Strata desktop | `strata/gyro-gyro-s` | `127.0.0.1:47831` |

## Start

Double-click `START-PANDA.bat` in the repository root.

- **First run:** pick the models to download (`1,3,4`, or `A` for all, or `N` to skip). Downloads go to a `.part` file, resume with `curl -C -`, and are checked against the remote `Content-Length` and (when the server exposes a 64-hex ETag) SHA-256 before being accepted; a failed or partial download is never marked installed. The choice is saved in `%LOCALAPPDATA%\panda-engine\state.json`, so the first-run screen never appears again.
- **Later runs:** the menu opens directly with the active model highlighted. `S` starts it (PORNIRE). `1`–`4` selects another model; if it is missing, the launcher offers to download it.
- `D` re-downloads / adds models, `C` installs the OpenCode layer, `R` replays first-run setup, `Q` exits.
- `-AutoStart` skips the menu and starts the active model; `-ResetState` replays first-run setup; `-DryRun` prints actions without downloading or starting anything.

## What it installs

- **NInfer engine** — latest Windows CUDA 13.4 release from `iamwavecut/ninfer-all`, multi-part `.7z` assembled and extracted into `ninfer/` (7-Zip required; a manual extraction path is printed if absent).
- **Inkling models** — `WaveCut/Inkling-2-Mini-UD-IQ1_M-NInfer-v3` and `WaveCut/Inkling-2-Mini-UD-Q2_K_XL-NInfer-v3` on Hugging Face, stored in `models/`.
- **MiniCPM** — `openbmb/MiniCPM-V-4.7-35B-A3B-gguf`: the Q4_K_M GGUF and mmproj into `PolyStrata-data/models/minicpmv-Q4_K_M/`. The Strata pack/tokenizer and `strata-minicpmv-q4_k_m.json` are reused from the existing Poly-strata install.
- **Gyro-S** — Strata desktop must already be installed; the model itself is downloaded by Strata on first load via the existing `load-gyro-s.ps1` loader. Because it is fetched on demand, Gyro is not recorded in the launcher's `downloaded` list.

When the current Inkling/Poly-strata/Strata installs are present, the launcher detects and reuses them (junctions for `ninfer/` and `models/`) instead of downloading again.

## Settings preserved

The launcher calls the existing launchers and server configs, so all settings are unchanged:

- Inkling: `reasoning_effort=low`, `presence_penalty=0`, `frequency_penalty=0`, 131072 context, `--structured-output --spec none --reasoning-loop conclude`, `--vision`.
- MiniCPM: `strata-minicpmv-q4_k_m.json` (131072 context, expert profile, conversation cache, vision mmproj).
- Gyro-S: `load-gyro-s.ps1` (`vision=yes`, `multiple=false`).

Only one engine can hold port 8080, so starting one model stops the previous server. Gyro-S uses its own port 47831; switching away from it also stops the Strata processes (the loader starts them on demand again). The existing `ninfer/` and `models/` folders are linked into the repo at startup so the original launcher sees downloaded artifacts in the same place.

`C` copies `config/opencode.json`, `AGENT_RULES.md` and `plugins/` into `%USERPROFILE%\.config\opencode\`, after timestamped backups of all three, and rewrites `instructions` to the absolute path of the copied rules file (matching the live setup). All three model IDs are present there.

## Files

- `panda/panda.ps1` — menu, download/state logic, start/stop orchestration.
- `panda/catalog.json` — model URLs, engine paths and setting values.
- `START-PANDA.bat` — double-click entry point.
