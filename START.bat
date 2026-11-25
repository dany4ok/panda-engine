@echo off
title Panda Engine
cd /d "%~dp0"
if /I "%~1"=="--console" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0panda\panda.ps1"
) else (
  start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0panda\gui.ps1"
)
