#!/usr/bin/env bash
# Ocean CLI 一键安装脚本
# 支持 macOS / Linux / WSL
# 用法:
#   curl -fsSL .../install.sh | bash
#   OCEAN_MIRROR=cn bash <(curl -fsSL ...)
set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════════════════════
REPO="ArtLjn/ocean-cc-cli"
LATEST="v1.5.3"
BIN_DIR="$HOME/.local/bin"

# 平台检测
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
esac

PLATFORM="${OS}-${ARCH}"
PKG_NAME="ocean-${PLATFORM}.tar.gz"

# 下载源（按优先级）
RELEASE_URLS=(
  "https://github.com/${REPO}/releases/download/${LATEST}/${PKG_NAME}"
  "https://ghproxy.com/https://github.com/${REPO}/releases/download/${LATEST}/${PKG_NAME}"
  "https://ghps.cc/https://github.com/${REPO}/releases/download/${LATEST}/${PKG_NAME}"
  "https://mirror.ghproxy.com/https://github.com/${REPO}/releases/download/${LATEST}/${PKG_NAME}"
)

# 源码构建源
SOURCE_URLS=(
  "https://github.com/${REPO}.git"
  "https://ghps.cc/https://github.com/${REPO}.git"
  "https://ghproxy.com/https://github.com/${REPO}.git"
)

# ═══════════════════════════════════════════════════════════════
# 颜色
# ═══════════════════════════════════════════════════════════════
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { printf "${CYAN}>>>${NC} %s\n" "$*"; }
ok()    { printf "${GREEN} ✓${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW} !${NC} %s\n" "$*"; }
err()   { printf "${RED} ✗${NC} %s\n" "$*" >&2; }
die()   { err "$@"; exit 1; }

# ═══════════════════════════════════════════════════════════════
# 步骤 1: 环境检测
# ═══════════════════════════════════════════════════════════════
info "检测运行环境 ..."
info "平台: $PLATFORM"

case "$OS" in
  darwin|linux) ;;
  mingw*|msys*|cygwin*) die "Windows 请使用 PowerShell 安装: iwr -useb ... | iex" ;;
  *) die "不支持的操作系统: $OS" ;;
esac

command -v curl >/dev/null 2>&1 || die "未找到 curl"
ok "curl"

# ═══════════════════════════════════════════════════════════════
# 步骤 2: 下载预编译包（多源回退）
# ═══════════════════════════════════════════════════════════════
info "下载预编译包 ..."
mkdir -p "$BIN_DIR"

downloaded=false
for url in "${RELEASE_URLS[@]}"; do
  info "尝试: ${url:0:70}..."
  if curl -fsSL -m 120 -o /tmp/ocean-pkg.tar.gz "$url" 2>/dev/null; then
    # 验证是否为有效 tar.gz（非 HTML 错误页面）
    if tar -tzf /tmp/ocean-pkg.tar.gz >/dev/null 2>&1; then
      ok "下载成功"
      downloaded=true
      break
    else
      warn "返回了无效文件，切换下一个源..."
    fi
  else
    warn "下载失败，切换下一个源..."
  fi
done

if $downloaded; then
  # ── 预编译包安装 ────────────────────────────────────────────
  info "解压到 $BIN_DIR ..."
  tar -xzf /tmp/ocean-pkg.tar.gz -C "$BIN_DIR" --strip-components=1
  chmod +x "$BIN_DIR/ocean" "$BIN_DIR/.ocean-bun" 2>/dev/null || true
  rm -f /tmp/ocean-pkg.tar.gz
  ok "安装完成"
else
  # ── 回退：源码构建 ──────────────────────────────────────────
  warn "预编译包下载失败，回退到源码构建 ..."

  command -v git >/dev/null 2>&1 || die "未找到 git（源码构建需要）"
  command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || die "未找到 C 编译器"

  # 安装 Bun
  if ! command -v bun >/dev/null 2>&1 && [ ! -x "$HOME/.bun/bin/bun" ]; then
    info "安装 Bun ..."
    # 尝试 npm 安装（国内有镜像）
    if command -v npm >/dev/null 2>&1; then
      npm install -g bun 2>/dev/null || curl -fsSL -m 60 https://bun.sh/install | bash
    else
      curl -fsSL -m 60 https://bun.sh/install | bash || die "Bun 安装失败"
    fi
    export PATH="$HOME/.bun/bin:$PATH"
  fi
  command -v bun >/dev/null 2>&1 || export PATH="$HOME/.bun/bin:$PATH"
  command -v bun >/dev/null 2>&1 || die "Bun 未找到"

  # 克隆仓库（多源回退）
  INSTALL_DIR="$HOME/.ocean-cli"
  cloned=false
  for repo in "${SOURCE_URLS[@]}"; do
    info "尝试克隆: ${repo:0:60}..."
    if git clone --depth 1 "$repo" "$INSTALL_DIR" 2>/dev/null; then
      ok "克隆成功"
      cloned=true
      break
    fi
    rm -rf "$INSTALL_DIR"
  done
  $cloned || die "所有源都失败，请手动下载: git clone https://github.com/${REPO}.git"

  # 构建
  cd "$INSTALL_DIR"
  bun install --frozen-lockfile 2>/dev/null || bun install
  mkdir -p "$BIN_DIR"
  bash ./build.sh
  ok "构建完成"
fi

# ═══════════════════════════════════════════════════════════════
# 步骤 3: PATH 配置
# ═══════════════════════════════════════════════════════════════
if ! echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
  shell_rc=""
  case "${SHELL:-}" in
    */zsh)  shell_rc="$HOME/.zshrc" ;;
    */bash) shell_rc="$HOME/.bashrc" ;;
    */fish) shell_rc="$HOME/.config/fish/config.fish" ;;
    *)      shell_rc="$HOME/.profile" ;;
  esac
  warn "$BIN_DIR 不在 PATH 中，添加到 $shell_rc"
  echo "" >> "$shell_rc"
  echo '# Ocean CLI' >> "$shell_rc"
  echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$shell_rc"
  export PATH="$BIN_DIR:$PATH"
fi

# ═══════════════════════════════════════════════════════════════
# 完成
# ═══════════════════════════════════════════════════════════════
echo ""
printf "${BOLD}${GREEN}  ✓ Ocean CLI 安装成功！${NC}\n"
echo ""
printf "  命令: ${CYAN}${BIN_DIR}/ocean${NC}\n"
echo ""
printf "  ${BOLD}快速开始:${NC}\n"
echo "    ocean                          # 交互模式"
echo "    ocean --permission-mode auto   # Auto 模式"
echo "    ocean -p \"your prompt\"         # 无头模式"
echo ""

if ! echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
  printf "  ${YELLOW}请重启终端或: source ${SHELL##*/}rc${NC}\n\n"
fi
