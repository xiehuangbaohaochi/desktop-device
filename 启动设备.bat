@echo off
rem Launch DeviceWidget without a console window
start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0DeviceWidget.ps1"
