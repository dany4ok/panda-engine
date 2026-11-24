@echo off
title Panda Engine
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0panda\panda.ps1"
