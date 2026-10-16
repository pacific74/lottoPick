@echo off
REM lottoPick Sunday: collect draws and grade picks
cd /d %~dp0
call node --env-file-if-exists=.env run.mjs sunday >> sunday.log 2>&1
