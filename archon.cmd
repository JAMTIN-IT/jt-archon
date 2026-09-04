@echo off
REM Lets `archon <command>` work from cmd.exe as well as PowerShell.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0archon.ps1" %*
