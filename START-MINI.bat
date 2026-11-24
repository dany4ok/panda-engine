@echo off
title MiniCPM - agentic model
rem Set POLY_DIR to your Poly-strata install before running on another machine.
if "%POLY_DIR%"=="" set "POLY_DIR=C:\Users\x1p\Desktop\Poly-strata"
cd /d "%POLY_DIR%"
"%POLY_DIR%\.venv\Scripts\python.exe" "%POLY_DIR%\serve\server.py" --engine strata --config "%POLY_DIR%\strata-minicpmv-q4_k_m.json" --port 8080
pause
