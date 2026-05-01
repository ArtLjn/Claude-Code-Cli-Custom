# Ocean CLI Windows 安装脚本 (PowerShell)
# 用法: iwr -useb https://raw.githubusercontent.com/ArtLjn/ocean-cc-cli/main/install.ps1 | iex
#       iwr -useb https://gitee.com/morning-ljn/ocean-cc-cli/raw/main/install.ps1 | iex

$ErrorActionPreference = "Stop"

# ── 配置 ──────────────────────────────────────────────────────
$DefaultRepo   = "https://github.com/ArtLjn/ocean-cc-cli.git"
$GiteeRepo     = "https://gitee.com/morning-ljn/ocean-cc-cli.git"
$InstallDir    = if ($env:OCEAN_INSTALL_DIR) { $env:OCEAN_INSTALL_DIR } else { "$env:USERPROFILE\.ocean-cli" }
$BinDir        = "$env:USERPROFILE\.local\bin"
$BunMinVersion = "1.3.5"

$MirrorRepos = @(
    $DefaultRepo,
    $GiteeRepo,
    "https://ghps.cc/$DefaultRepo",
    "https://ghproxy.com/$DefaultRepo"
)

$MirrorScripts = @(
    "https://raw.githubusercontent.com/ArtLjn/ocean-cc-cli/main/install.ps1",
    "https://gitee.com/morning-ljn/ocean-cc-cli/raw/main/install.ps1",
    "https://ghps.cc/https://raw.githubusercontent.com/ArtLjn/ocean-cc-cli/main/install.ps1",
    "https://ghproxy.com/https://raw.githubusercontent.com/ArtLjn/ocean-cc-cli/main/install.ps1"
)

# ── 颜色 ──────────────────────────────────────────────────────
function Info  { param([string]$msg); Write-Host ">>> $msg" -ForegroundColor Cyan }
function Ok    { param([string]$msg); Write-Host "  OK $msg" -ForegroundColor Green }
function Warn  { param([string]$msg); Write-Host "  !  $msg" -ForegroundColor Yellow }
function Err   { param([string]$msg); Write-Host "  X  $msg" -ForegroundColor Red }
function Die   { param([string]$msg); Err $msg; exit 1 }

# ── 多源回退下载 ──────────────────────────────────────────────
function Clone-WithFallback {
    param([string]$TargetDir)
    foreach ($repo in $MirrorRepos) {
        Info "尝试克隆: $repo"
        if (Test-Path $TargetDir) { Remove-Item -Recurse -Force $TargetDir }
        try {
            git clone --depth 1 $repo $TargetDir 2>$null
            if ($LASTEXITCODE -eq 0) {
                Ok "克隆成功"
                return $true
            }
        } catch {
            Warn "克隆失败，切换下一个源..."
        }
    }
    return $false
}

# ── 步骤 1: 环境检测 ──────────────────────────────────────────
Info "检测运行环境 ..."

# 检测 WSL
if ($env:WSL_DISTRO_NAME) {
    Warn "检测到 WSL 环境"
    Info "推荐在 WSL 终端中使用 bash 安装脚本"
    Info "  curl -fsSL ... | bash"
}

# 检测 Git
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { Die "未找到 git，请先安装 Git for Windows: https://git-scm.com/download/win" }
Ok "git"

# 检测 curl
$curl = Get-Command curl -ErrorAction SilentlyContinue
if (-not $curl) { Die "未找到 curl" }
Ok "curl"

# 检测 Bun
$bun = Get-Command bun -ErrorAction SilentlyContinue
if ($bun) {
    $bunVer = & bun --version 2>$null
    Ok "Bun $bunVer"
} else {
    Info "安装 Bun ..."
    $bunUrls = @(
        "https://bun.sh/install",
        "https://ghps.cc/https://bun.sh/install",
        "https://ghproxy.com/https://bun.sh/install"
    )
    foreach ($url in $bunUrls) {
        try {
            irm $url | iex
            break
        } catch {
            Warn "Bun 安装源失败，切换..."
        }
    }
    $env:PATH = "$env:USERPROFILE\.bun\bin;$env:PATH"
    Ok "Bun 已安装"
}

# ── 步骤 2: 克隆仓库 ──────────────────────────────────────────
if (Test-Path "$InstallDir\.git") {
    Info "更新仓库 ($InstallDir) ..."
    Set-Location $InstallDir
    git fetch --quiet origin main 2>$null
    git reset --hard origin/main 2>$null
    Ok "仓库已更新"
} else {
    Info "克隆仓库 ..."
    if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
    if (-not (Clone-WithFallback $InstallDir)) {
        Die "所有镜像源都失败了，请检查网络或手动下载:`n  git clone $DefaultRepo $InstallDir"
    }
    Set-Location $InstallDir
    Ok "仓库已克隆"
}

# ── 步骤 3: 安装依赖 ──────────────────────────────────────────
Info "安装依赖 (bun install) ..."
bun install --frozen-lockfile 2>$null
if ($LASTEXITCODE -ne 0) { bun install }
Ok "依赖已安装"

# ── 步骤 4: 构建 ──────────────────────────────────────────────
Info "构建 Ocean CLI ..."
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
# Windows 下不需要 C 启动器，直接用 bun 运行
$EntryScript = "$InstallDir\src\dev-entry.ts"
if (Test-Path $EntryScript) {
    # 创建 ocean.cmd 包装器
    $CmdContent = @"
@echo off
setlocal
set BUN_INSTALL_BIN=%USERPROFILE%\.bun\bin
set PATH=%BUN_INSTALL_BIN%;%PATH%
bun run "$EntryScript" %*
"@
    $CmdContent | Out-File -Encoding UTF8 "$BinDir\ocean.cmd"
    Ok "构建完成 (Windows cmd wrapper)"
} else {
    Warn "未找到入口文件，跳过构建"
}

# ── 步骤 5: PATH ──────────────────────────────────────────────
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -notlike "*$BinDir*") {
    Warn "$BinDir 不在 PATH 中"
    Info "请手动添加以下路径到系统环境变量 PATH:"
    Info "  $BinDir"
    Info "  $env:USERPROFILE\.bun\bin"
} else {
    Ok "PATH 已配置"
}

# ── 完成 ──────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Ocean CLI 安装成功！" -ForegroundColor Green -BackgroundColor Black
Write-Host ""
Write-Host "  命令路径: $BinDir\ocean.cmd"
Write-Host "  安装目录: $InstallDir"
Write-Host ""
Write-Host "  快速开始:"
Write-Host "    ocean                     # 交互模式"
Write-Host "    ocean --permission-mode auto   # Auto 模式"
Write-Host ""

if ($UserPath -notlike "*$BinDir*") {
    Write-Host "  请重启终端使 PATH 生效" -ForegroundColor Yellow
    Write-Host ""
}
