#!/bin/bash
# Git 新手助手 - macOS 启动器
# 双击本文件即可打开中文菜单(需先安装 PowerShell 7 和 git)
cd "$(dirname "$0")"
if ! command -v pwsh >/dev/null 2>&1; then
    echo ""
    echo "没有找到 PowerShell 7(pwsh),本工具无法运行。"
    echo ""
    echo "请先安装 PowerShell 7,任选一种:"
    echo "  1) 官网下载安装包: https://aka.ms/powershell-release?tag=stable"
    echo "  2) 已装 Homebrew 的话: brew install --cask powershell"
    echo ""
    echo "装完后,重新双击本文件即可。"
    echo ""
    read -p "按回车退出"
    exit 1
fi
pwsh -NoProfile -File ./upload.ps1 "$@"
echo ""
read -p "按回车关闭窗口"
