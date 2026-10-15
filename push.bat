@echo off
REM lottoPick push + deploy (logic is in deploy.ps1)
REM   push.bat            auto message
REM   push.bat "message"  custom message
REM deploy.ps1 is read as UTF-8 explicitly so Korean text never breaks
set "LOTTO_ROOT=%~dp0"
set "LOTTO_MSG=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:LOTTO_ROOT+'deploy.ps1',[Text.Encoding]::UTF8); & ([scriptblock]::Create($s)) -Message $env:LOTTO_MSG"
echo.
pause
