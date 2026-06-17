@echo off
chcp 65001 >nul
title Open365 - 开源电脑助手 (替代360)

REM ============================================================
REM  Open365 启动入口
REM  - 自动请求管理员权限（修复网络/卸载需要）
REM  - 用 UTF-8 控制台跑 PowerShell 主菜单
REM ============================================================

REM 自动提权
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs" >nul 2>&1
    exit /b
)

REM 切到脚本所在目录
cd /d "%~dp0"

REM 跑主菜单（强制 UTF-8 控制台输出，中文不乱码）
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '%~dp0open365.ps1'"

exit /b
