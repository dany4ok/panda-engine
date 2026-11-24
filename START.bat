@echo off
title Inkling 2 Mini - terminal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0start.ps1"
