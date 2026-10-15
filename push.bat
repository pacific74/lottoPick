@echo off
REM lottoPick push + deploy (logic is in deploy.ps1)
REM   push.bat            auto message
REM   push.bat "message"  custom message
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
echo.
pause
