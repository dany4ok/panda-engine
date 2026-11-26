@echo off
title Panda Engine - MiniCPM backend
rem Standalone backend start; Panda Engine normally does this for you on port 8182.
rem POLY_DIR can be overridden, but it defaults to the runtime bundled in this folder.
if "%POLY_DIR%"=="" set "POLY_DIR=%~dp0..\..\runtime\panda"
"%POLY_DIR%\.venv\Scripts\python.exe" "%POLY_DIR%\serve\server.py" --engine panda --config "%POLY_DIR%\panda-minicpmv-q4_k_m.json" --port 8182
pause
