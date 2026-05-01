#!/usr/bin/env bash
# Ocean CLI 一键安装脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/<repo>/ocean-cli/main/install.sh | bash
#       或克隆后本地运行: ./install.sh
set -euo pipefail

# ── 配置 ──────────────────────────────────────────────────────
# 国内镜像支持：设置 OCEAN_MIRROR=cn 自动使用 ghproxy 代理
MIRROR="${OCEAN_MIRROR:-}"
DEFAULT_REPO="https://github.com/ArtLjn/ocean-cc-cli.git"

# 镜像代理函数
mirror_url() {
  local url="$1"
  if [ "$MIRROR" = "cn" ]; then
    # 优先尝试较快的镜像，失败时回退
    echo "https://ghps.cc/$url"
  else
    echo "$url"
  fi
}

REPO_URL="${OCEAN_REPO_URL:-$(mirror_url "$DEFAULT_REPO")}"
INSTALL_DIR="${OCEAN_INSTALL_DIR:-$HOME/.ocean-cli}"
BIN_DIR="$HOME/.local/bin"
BUN_MIN_VERSION="1.3.5"

# ── 颜色 ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${CYAN>>>${NC} %s\n" "$*"; }
ok()    { printf "${GREEN} ✓${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW} !${NC} %s\n" "$*"; }
err()   { printf "${RED} ✗${NC} %s\n" "$*" >&2; }
die()   { err "$@"; exit 1; }

# ── 步骤 1: 环境检测 ──────────────────────────────────────────
info "检测运行环境 ..."

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin|Linux) ;;
  *) die "不支持的操作系统: $OS (仅支持 macOS / Linux)"
esac

command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 \
  || die "未找到 C 编译器 (cc/gcc)，请先安装 Xcode Command Line Tools:\n  xcode-select --install"
ok "C 编译器"

command -v curl >/dev/null 2>&1 || die "未找到 curl"
ok "curl"

command -v git >/dev/null 2>&1 || die "未找到 git"
ok "git"

# ── 步骤 2: 安装 Bun ──────────────────────────────────────────
info "检查 Bun ..."

ensure_bun_on_path() {
  # 优先使用已有 bun
  if command -v bun >/dev/null 2>&1; then
    return 0
  fi
  # 检查默认安装位置
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
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
  command -v bun >/dev/null 2>&1 || die "Bun 安装失败"
  BUN_VER="$(bun --version)"
  ok "Bun $BUN_VER 已安装"
fi

# ── 步骤 3: 克隆 / 更新仓库 ──────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ]; then
  info "更新仓库 ($INSTALL_DIR) ..."
  cd "$INSTALL_DIR"
  git fetch --quiet origin main || warn "git fetch 失败，继续使用本地版本"
  git reset --hard origin/main 2>/dev/null || true
  ok "仓库已更新"
else
  info "克隆仓库 ..."
  rm -rf "$INSTALL_DIR"
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
  ok "仓库已克隆"
fi

# ── 步骤 4: 安装依赖 ──────────────────────────────────────────
info "安装依赖 (bun install) ..."
bun install --frozen-lockfile 2>/dev/null || bun install
ok "依赖已安装"

# ── 步骤 5: 构建部署 ──────────────────────────────────────────
info "构建 Ocean CLI ..."
mkdir -p "$BIN_DIR"
bash ./build.sh
ok "构建完成"

# ── 步骤 6: PATH 检查 ────────────────────────────────────────
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

# ── 完成 ──────────────────────────────────────────────────────
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
