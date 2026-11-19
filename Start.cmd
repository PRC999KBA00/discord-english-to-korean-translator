@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy RemoteSigned -File "%~dp0Translator.ps1"
if errorlevel 1 pause
