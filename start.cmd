@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText('%~dp0lanxfer.ps1'))"
