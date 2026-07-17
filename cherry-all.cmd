@echo off
REM cherry-all: 将指定 commit cherry-pick 到选定的本地分支
REM 用法: cherry-all <commit-hash> [其它参数透传给 PowerShell]
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cherry-all.ps1" %*