#!/usr/bin/env bash
# ocean 构建脚本 - 代码更新后运行此脚本重新打包
# 兼容 macOS / Linux / Windows (MSYS2/Git Bash/WSL)
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.bun/bin:$PATH"

# ═══════════════════════════════════════════════════════════════
# 平台检测
# ═══════════════════════════════════════════════════════════════
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$OS" in
  darwin)  PLATFORM="macos" ;;
  linux)   PLATFORM="linux" ;;
  mingw*|msys*|cygwin*) PLATFORM="windows" ;;
  *)       PLATFORM="linux" ;;
esac

# BIN_DIR: Windows 用 ~/bin，其他用 ~/.local/bin
if [ "$PLATFORM" = "windows" ]; then
  BIN_DIR="$HOME/bin"
else
  BIN_DIR="$HOME/.local/bin"
fi

echo ">>> 平台: $PLATFORM ($OS $ARCH)"

EXTERNALS=(
  '@anthropic-ai/bedrock-sdk'
  '@anthropic-ai/foundry-sdk'
  '@anthropic-ai/vertex-sdk'
  '@azure/identity'
  '@aws-sdk/client-sts'
  '@aws-sdk/client-bedrock'
  'turndown'
  'sharp'
  '@opentelemetry/exporter-metrics-otlp-grpc'
  '@opentelemetry/exporter-metrics-otlp-http'
  '@opentelemetry/exporter-metrics-otlp-proto'
  '@opentelemetry/exporter-prometheus'
  '@opentelemetry/exporter-logs-otlp-grpc'
  '@opentelemetry/exporter-logs-otlp-http'
  '@opentelemetry/exporter-logs-otlp-proto'
  '@opentelemetry/exporter-trace-otlp-grpc'
  '@opentelemetry/exporter-trace-otlp-http'
  '@opentelemetry/exporter-trace-otlp-proto'
)

# 1. 清理旧产物
echo ">>> 清理缓存 ..."
rm -f ocean.bundle.js
rm -f "$BIN_DIR/.ocean-bundle.js" "$BIN_DIR/.ocean-bun" "$BIN_DIR/.clmg-bundle.js" "$BIN_DIR/.clmg-bun"
rm -f "$BIN_DIR/ocean" "$BIN_DIR/ocean.exe"

# 2. 打包 JS bundle
echo ">>> 打包 bundle ..."
ext_args=()
for e in "${EXTERNALS[@]}"; do
  ext_args+=(--external "$e")
done
bun build --target=bun --outfile=ocean.bundle.js ./src/dev-entry.ts "${ext_args[@]}"

# 3. 编译 C 启动器
echo ">>> 编译启动器 ..."
mkdir -p "$BIN_DIR"
if [ "$PLATFORM" = "windows" ]; then
  cc -O2 -o "$BIN_DIR/ocean.exe" clmg_launcher.c
else
  cc -O2 -o "$BIN_DIR/ocean" clmg_launcher.c
fi

# 4. 部署 bundle 和 bun runtime
echo ">>> 部署 ..."
cp ocean.bundle.js "$BIN_DIR/.ocean-bundle.js"
if [ "$PLATFORM" = "windows" ]; then
  cp "$HOME/.bun/bin/bun.exe" "$BIN_DIR/.ocean-bun.exe" 2>/dev/null || \
    cp "$HOME/.bun/bin/bun" "$BIN_DIR/.ocean-bun" 2>/dev/null || true
else
  cp "$HOME/.bun/bin/bun" "$BIN_DIR/.ocean-bun"
fi

# 5. 平台特有步骤
if [ "$PLATFORM" = "macos" ]; then
  # 修复 sharp libvips 动态库路径
  echo ">>> 修复 sharp libvips 路径 ..."
  SHARP_CACHE_DIR="$HOME/.bun/install/cache/@img"
  LIBVIPS_REAL_DIR=$(find "$SHARP_CACHE_DIR" -maxdepth 1 -type d -name 'sharp-libvips-darwin-arm64@*' 2>/dev/null | sort -V | tail -1)
  if [ -n "$LIBVIPS_REAL_DIR" ] && [ -d "$LIBVIPS_REAL_DIR/lib" ]; then
    LIBVIPS_LINK="$SHARP_CACHE_DIR/sharp-libvips-darwin-arm64/lib"
    mkdir -p "$LIBVIPS_LINK" 2>/dev/null || true
    for item in "$LIBVIPS_REAL_DIR/lib/"*; do
      name=$(basename "$item")
      target="$LIBVIPS_LINK/$name"
      if [ ! -e "$target" ]; then
        ln -sf "$item" "$target"
      fi
    done
    echo "    libvips 链接已创建: $LIBVIPS_LINK"
  else
    echo "    跳过: 未找到 sharp-libvips-darwin-arm64 缓存目录"
  fi

  # 清除隔离属性并签名
  echo ">>> 签名 ..."
  xattr -cr "$BIN_DIR/ocean" "$BIN_DIR/.ocean-bundle.js" "$BIN_DIR/.ocean-bun"
  codesign --force --sign - "$BIN_DIR/ocean"
  codesign --force --sign - "$BIN_DIR/.ocean-bun"
else
  echo ">>> 跳过 macOS 专有步骤 (codesign/xattr/libvips)"
  chmod +x "$BIN_DIR/ocean" "$BIN_DIR/.ocean-bun"
fi

# 6. 确保 PATH 包含 BIN_DIR
if ! echo ":${PATH}:" | grep -q ":${BIN_DIR}:"; then
  shell_rc=""
  case "${SHELL:-}" in
    */zsh)  shell_rc="$HOME/.zshrc" ;;
    */bash) shell_rc="$HOME/.bashrc" ;;
    */fish) shell_rc="$HOME/.config/fish/config.fish" ;;
    *)      shell_rc="$HOME/.profile" ;;
  esac
  echo ">>> 添加 $BIN_DIR 到 PATH (写入 $shell_rc)"
  echo "" >> "$shell_rc"
  echo '# Ocean CLI' >> "$shell_rc"
  echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$shell_rc"
  export PATH="$BIN_DIR:$PATH"
fi

echo ">>> 完成: $BIN_DIR/ocean"
