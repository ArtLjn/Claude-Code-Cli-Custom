#!/usr/bin/env bash
# Ocean CLI 发布脚本 — 打包预编译二进制
# 用法: ./release.sh [version]
# 产物: dist/ocean-{platform}-{arch}.tar.gz
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo 'dev')}"
DIST_DIR="dist"
BIN_DIR="$HOME/.local/bin"

ok() { printf "  OK %s\n" "$*"; }

echo ">>> Ocean CLI Release v${VERSION}"
echo ""

# ── 1. 构建 JS bundle ────────────────────────────────────────
echo ">>> 打包 JS bundle ..."
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
ext_args=()
for e in "${EXTERNALS[@]}"; do ext_args+=(--external "$e"); done
bun build --target=bun --outfile=ocean.bundle.js ./src/dev-entry.ts "${ext_args[@]}"
ok "bundle"

# ── 2. 为当前平台打包 ────────────────────────────────────────
PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  ARCH="x64" ;;
  aarch64) ARCH="arm64" ;;
  arm64)   ARCH="arm64" ;;
esac

PKG_NAME="ocean-${VERSION}-${PLATFORM}-${ARCH}"
PKG_DIR="$DIST_DIR/$PKG_NAME"

echo ">>> 打包 ${PKG_NAME} ..."
rm -rf "$PKG_DIR" "$DIST_DIR/${PKG_NAME}.tar.gz"
mkdir -p "$PKG_DIR"

# 复制 JS bundle
cp ocean.bundle.js "$PKG_DIR/.ocean-bundle.js"

# 复制 Bun runtime
if [ -x "$HOME/.bun/bin/bun" ]; then
  cp "$HOME/.bun/bin/bun" "$PKG_DIR/.ocean-bun"
else
  echo "  ! 未找到 Bun runtime，跳过"
fi

# 编译 C 启动器
cc -O2 -o "$PKG_DIR/ocean" clmg_launcher.c
chmod +x "$PKG_DIR/ocean" "$PKG_DIR/.ocean-bun"

# 打包
tar -czf "$DIST_DIR/${PKG_NAME}.tar.gz" -C "$DIST_DIR" "$PKG_NAME"
rm -rf "$PKG_DIR"

# 计算文件大小
SIZE=$(du -h "$DIST_DIR/${PKG_NAME}.tar.gz" | cut -f1)
echo "  OK ${PKG_NAME}.tar.gz (${SIZE})"

# ── 3. 生成 checksum ────────────────────────────────────────
cd "$DIST_DIR"
sha256sum "${PKG_NAME}.tar.gz" > "${PKG_NAME}.tar.gz.sha256"
cd ..

echo ""
echo ">>> 发布产物:"
ls -la "$DIST_DIR/${PKG_NAME}"*
echo ""
echo ">>> 安装命令:"
echo "  curl -fsSL https://github.com/ArtLjn/ocean-cc-cli/releases/download/v${VERSION}/${PKG_NAME}.tar.gz | tar xz -C ~/.local/bin --strip-components=1"
echo ""
