@echo off
REM lottoPick weekly batch: collect -> check -> generate
cd /d %~dp0
call npm run weekly >> weekly.log 2>&1
