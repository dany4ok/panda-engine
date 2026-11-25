# Inkling quantization benchmark artifacts

This directory contains the recorded evaluation and timing metrics for four
local benchmark batches, under `results/qb_iq1m`, `results/qb_q2kxl`,
`results/qb128_iq1m`, and `results/qb128_q2kxl`. Each completed task has its
own `eval.json` and `metrics.json`; `vram.csv` contains sampled VRAM readings.

These are individual recorded runs, not an independently verified ranking.
Some earlier runs reported zero tool calls or missing exit codes, and the
`qb128_q2kxl` batch has no completed metrics or evaluation for task E and no
task F. Do not interpret missing results as passes or as zero scores, or
compare batches as equivalent without checking their configuration and logs.

Generated workspaces, transcripts and local configuration are not included.
Other benchmark reports already published in this directory remain available.
