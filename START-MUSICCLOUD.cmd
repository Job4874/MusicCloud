@echo off
setlocal
if not exist "%~dp0runtime\node.exe" (
  echo MusicCloud's bundled runtime is missing. Restore the runtime folder from the original package.
  pause
  exit /b 1
)
"%~dp0runtime\node.exe" "%~dp0desktop\launch.mjs"
if errorlevel 1 (
  echo.
  echo MusicCloud did not open. Read the message above.
  pause
  exit /b 1
)
