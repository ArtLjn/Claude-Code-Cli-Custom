#!/usr/bin/env bash
# Ocean CLI 一键安装脚本
# 支持 macOS / Linux / WSL
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/ArtLjn/ocean-cc-cli/main/install.sh | bash
#   curl -fsSL https://gitee.com/morning-ljn/ocean-cc-cli/raw/main/install.sh | bash
#   OCEAN_MIRROR=cn bash <(curl -fsSL ...)
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════════════════════
DEFAULT_REPO="https://github.com/ArtLjn/ocean-cc-cli.git"
GITEE_REPO="https://gitee.com/morning-ljn/ocean-cc-cli.git"
INSTALL_DIR="${OCEAN_INSTALL_DIR:-$HOME/.ocean-cli}"
BIN_DIR="$HOME/.local/bin"
BUN_MIN_VERSION="1.3.5"

# 镜像源列表（按优先级）
MIRROR_REPOS=(
  "$DEFAULT_REPO"
  "$GITEE_REPO"
  "https://ghps.cc/$DEFAULT_REPO"
  "https://ghproxy.com/$DEFAULT_REPO"
  "https://mirror.ghproxy.com/$DEFAULT_REPO"
)
MIRROR_SCRIPTS=(
  "https://raw.githubusercontent.com/ArtLjn/ocean-cc-cli/main/install.sh"
  "https://gitee.com/morning-ljn/ocean-cc-cli/raw/main/install.sh"
  "https://ghps.cc/https://raw.githubusercontent.com/ArtLjn/ocean-cc-cli/main/install.sh"
  "https://ghproxy.com/https://raw.githubusercontent.com/ArtLjn/ocean-cc-cli/main/install.sh"
)

# ═══════════════════════════════════════════════════════════════
# 颜色
# ═══════════════════════════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN}>>>${NC} %s\n" "$*"; }
ok()    { printf "${GREEN} ✓${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW} !${NC} %s\n" "$*"; }
err()   { printf "${RED} ✗${NC} %s\n" "$*" && 2; }
die()   { err "$@"; exit 1; }

# ═══════════════════════════════════════════════════════════════
# 平台检测
# ═══════════════════════════════════════════════════════════════
OS="$(uname -s)"
ARCH="$(uname -m)"

detect_platform() {
  case "$OS" in
    Darwin)
      PLATFORM="macos"
      ;;
    Linux)
      PLATFORM="linux"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      PLATFORM="windows"
      ;;
    *)
      PLATFORM="unknown"
      ;;
  esac
  echo "$PLATFORM"
}

PLATFORM="$(detect_platform)"

# ═══════════════════════════════════════════════════════════════
# 网络工具：多源回退下载
# ═══════════════════════════════════════════════════════════════
download_with_fallback() {
  local url="$1"
  local output="$2"
  local max_time="${3:-30}"

  for src in "${MIRROR_SCRIPTS[@]}"; do
    info "尝试下载: ${src:0:60}..."
    if curl -fsSL -m "$max_time" -o "$output" "$src" 2>/dev/null; then
      # 验证下载内容（防爬虫页面通常含 HTML）
      if head -1 "$output" | grep -qE '<(!DOCTYPE|html|script|!--)' >/dev/null 2>&1; then
        warn "返回了 HTML 页面（防爬虫），跳过..."
        continue
      fi
      ok "下载成功"
      return 0
    fi
    warn "下载失败，切换下一个源..."
  done
  return 1
}

clone_with_fallback() {
  local target_dir="$1"
  for repo in "${MIRROR_REPOS[@]}"; do
    info "尝试克隆: ${repo:0:60}..."
    if git clone --depth 1 "$repo" "$target_dir" 2>/dev/null; then
      ok "克隆成功"
      return 0
    fi
    warn "克隆失败，切换下一个源..."
    rm -rf "$target_dir"
  done
  return 1
}

# ═══════════════════════════════════════════════════════════════
# 步骤 1: 环境检测
# ═══════════════════════════════════════════════════════════════
info "检测运行环境 ..."
info "平台: $PLATFORM ($OS $ARCH)"

case "$PLATFORM" in
  macos|linux)
    ;;
  windows)
    warn "检测到 Windows 环境"
    info "推荐在 WSL 或 Git Bash 中运行本脚本"
    info "或使用 PowerShell 安装: iwr -useb ... | iex"
    ;;
  *)
    die "不支持的操作系统: $OS"
    ;;
esac

command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 \
  || die "未找到 C 编译器 (cc/gcc)"
ok "C 编译器"

command -v curl >/dev/null 2>&1 || die "未找到 curl"
ok "curl"

command -v git >/dev/null 2>&1 || die "未找到 git"
ok "git"

# ═══════════════════════════════════════════════════════════════
# 步骤 2: 安装 Bun
# ═══════════════════════════════════════════════════════════════
info "检查 Bun ..."

ensure_bun_on_path() {
  if command -v bun >/dev/null 2>&1; then
    return 0
  fi
  if [ -x "$HOME/.bun/bin/bun" ]; then
    export PATH="$HOME/.bun/bin:$PATH"
    return 0
  fi
  return 1
}

if ensure_bun_on_path; then
  BUN_VER="$(bun --version 2>/dev/null || echo '0.0.0')"
  ok "Bun $BUN_VER"
else
  info "安装 Bun ..."
  # Bun 安装也支持多源回退
  BUN_INSTALL_URLS=(
    "https://bun.sh/install"
    "https://ghps.cc/https://bun.sh/install"
    "https://ghproxy.com/https://bun.sh/install"
  )
  for url in "${BUN_INSTALL_URLS[@]}"; do
    if curl -fsSL -m 60 "$url" | bash 2>/dev/null; then
      break
    fi
  done
  export PATH="$HOME/.bun/bin:$PATH"
  command -v bun >/dev/null 2>&1 || die "Bun 安装失败"
  BUN_VER="$(bun --version)"
  ok "Bun $BUN_VER 已安装"
fi

# ═══════════════════════════════════════════════════════════════
# 步骤 3: 克隆 / 更新仓库（多源回退）
# ═══════════════════════════════════════════════════════════════
if [ -d "$INSTALL_DIR/.git" ]; then
  info "更新仓库 ($INSTALL_DIR) ..."
  cd "$INSTALL_DIR"
  git fetch --quiet origin main 2>/dev/null || warn "git fetch 失败"
  git reset --hard origin/main 2>/dev/null || true
  ok "仓库已更新"
else
  info "克隆仓库 ..."
  rm -rf "$INSTALL_DIR"
  if ! clone_with_fallback "$INSTALL_DIR"; then
    die "所有镜像源都失败了，请检查网络或手动下载:\n  git clone $DEFAULT_REPO $INSTALL_DIR"
  fi
  cd "$INSTALL_DIR"
  ok "仓库已克隆"
fi

# ═══════════════════════════════════════════════════════════════
# 步骤 4: 安装依赖
# ═══════════════════════════════════════════════════════════════
info "安装依赖 (bun install) ..."
bun install --frozen-lockfile 2>/dev/null || bun install
ok "依赖已安装"

# ═══════════════════════════════════════════════════════════════
# 步骤 5: 构建部署
# ═══════════════════════════════════════════════════════════════
info "构建 Ocean CLI ..."
mkdir -p "$BIN_DIR"
bash ./build.sh
ok "构建完成"

# ═══════════════════════════════════════════════════════════════
# 步骤 6: PATH 检查
# ═══════════════════════════════════════════════════════════════
ensure_path() {
  local shell_rc=""
  case "${SHELL:-}" in
    */zsh)  shell_rc="$HOME/.zshrc" ;;
    */bash) shell_rc="$HOME/.bashrc" ;;
    */fish) shell_rc="$HOME/.config/fish/config.fish" ;;
    *)      shell_rc="$HOME/.profile" ;;
  esac

  if echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
    return 0
  fi

  warn "$BIN_DIR 不在 PATH 中，正在添加到 $shell_rc"
  echo "" >> "$shell_rc"
  echo '# Ocean CLI' >> "$shell_rc"
  echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$shell_rc"
  export PATH="$BIN_DIR:$PATH"
}

ensure_path

# ═══════════════════════════════════════════════════════════════
# 完成
# ═══════════════════════════════════════════════════════════════
echo ""
printf "${BOLD}${GREEN}  ✓ Ocean CLI 安装成功！${NC}\n"
echo ""
printf "  命令路径: ${CYAN}${BIN_DIR}/ocean${NC}\n"
printf "  安装目录: ${CYAN}${INSTALL_DIR}${NC}\n"
echo ""
printf "  ${BOLD}快速开始:${NC}\n"
echo "    ocean                     # 交互模式"
echo "    ocean --permission-mode auto   # Auto 模式"
echo "    ocean -p \"your prompt\"    # 无头模式"
echo ""

if ! echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
  printf "  ${YELLOW}请重启终端或执行: source ${SHELL##*/}rc${NC}\n"
  echo ""
fi
