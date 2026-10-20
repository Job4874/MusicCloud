@echo off
setlocal
if not exist "%~dp0runtime\node.exe" (
  echo MusicCloud's bundled runtime is missing. No process was stopped.
  pause
  exit /b 1
)
"%~dp0runtime\node.exe" "%~dp0desktop\stop.mjs"
if errorlevel 1 (
  echo.
  echo No unrelated process was stopped. Read the message above.
  pause
  exit /b 1
)
