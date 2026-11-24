@echo off
title MiniCPM - agentic model
cd /d "C:\Users\x1p\Desktop\Poly-strata"
"C:\Users\x1p\Desktop\Poly-strata\.venv\Scripts\python.exe" "C:\Users\x1p\Desktop\Poly-strata\serve\server.py" --engine strata --config "C:\Users\x1p\Desktop\Poly-strata\strata-minicpmv-q4_k_m.json" --port 8080
pause
