@echo off
REM lottoPick Friday: generate V1/V2/random 1000 each for next round
cd /d %~dp0
call node --env-file-if-exists=.env run.mjs friday >> friday.log 2>&1
