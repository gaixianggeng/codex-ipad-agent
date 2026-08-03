#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_MASTER="$ROOT_DIR/ios/MimiRemote/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-ios-marketing-1024x1024@1x.png"
MASTER_PATH="${1:-$DEFAULT_MASTER}"

if ! command -v sips >/dev/null 2>&1; then
  echo "缺少 macOS 系统命令：sips" >&2
  exit 1
fi

if [[ ! -f "$MASTER_PATH" ]]; then
  echo "找不到 AppIcon 母图：$MASTER_PATH" >&2
  exit 1
fi

metadata="$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$MASTER_PATH")"
if [[ "$metadata" != *"pixelWidth: 1024"* || "$metadata" != *"pixelHeight: 1024"* ]]; then
  echo "AppIcon 母图必须是 1024×1024：$MASTER_PATH" >&2
  exit 1
fi
if [[ "$metadata" != *"hasAlpha: no"* ]]; then
  echo "AppIcon 母图不能包含 Alpha 通道：$MASTER_PATH" >&2
  exit 1
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimi-app-icons.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
cp "$MASTER_PATH" "$temp_dir/master.png"

generate_icon() {
  local target_path="$1"
  local pixel_size="$2"

  mkdir -p "$(dirname "$target_path")"
  sips --resampleHeightWidth "$pixel_size" "$pixel_size" "$temp_dir/master.png" \
    --out "$target_path" >/dev/null
}

# iOS 的 Marketing 图标就是唯一母图；其余尺寸全部由它确定性缩放生成。
ios_icon_dir="$ROOT_DIR/ios/MimiRemote/Resources/Assets.xcassets/AppIcon.appiconset"
cp "$temp_dir/master.png" "$ios_icon_dir/AppIcon-ios-marketing-1024x1024@1x.png"

ios_targets=(
  "AppIcon-iphone-20x20@2x.png:40"
  "AppIcon-iphone-20x20@3x.png:60"
  "AppIcon-iphone-29x29@2x.png:58"
  "AppIcon-iphone-29x29@3x.png:87"
  "AppIcon-iphone-40x40@2x.png:80"
  "AppIcon-iphone-40x40@3x.png:120"
  "AppIcon-iphone-60x60@2x.png:120"
  "AppIcon-iphone-60x60@3x.png:180"
  "AppIcon-ipad-20x20@1x.png:20"
  "AppIcon-ipad-20x20@2x.png:40"
  "AppIcon-ipad-29x29@1x.png:29"
  "AppIcon-ipad-29x29@2x.png:58"
  "AppIcon-ipad-40x40@1x.png:40"
  "AppIcon-ipad-40x40@2x.png:80"
  "AppIcon-ipad-76x76@1x.png:76"
  "AppIcon-ipad-76x76@2x.png:152"
  "AppIcon-ipad-83.5x83.5@2x.png:167"
)
for target in "${ios_targets[@]}"; do
  IFS=: read -r filename pixel_size <<<"$target"
  generate_icon "$ios_icon_dir/$filename" "$pixel_size"
done

mac_targets=(
  "AppIconMac-16x16.png:16"
  "AppIconMac-16x16@2x.png:32"
  "AppIconMac-32x32.png:32"
  "AppIconMac-32x32@2x.png:64"
  "AppIconMac-128x128.png:128"
  "AppIconMac-128x128@2x.png:256"
  "AppIconMac-256x256.png:256"
  "AppIconMac-256x256@2x.png:512"
  "AppIconMac-512x512.png:512"
  "AppIconMac-512x512@2x.png:1024"
)
mac_icon_dirs=(
  "$ROOT_DIR/ios/MimiRemote/Resources/Assets.xcassets/AppIconMac.appiconset"
  "$ROOT_DIR/macos/MimiRemoteMac/Resources/Assets.xcassets/AppIcon.appiconset"
)
for mac_icon_dir in "${mac_icon_dirs[@]}"; do
  for target in "${mac_targets[@]}"; do
    IFS=: read -r filename pixel_size <<<"$target"
    generate_icon "$mac_icon_dir/$filename" "$pixel_size"
  done
done

# Web 安装图标与原生 AppIcon 共用品牌母图，避免不同入口继续展示旧版本。
cp "$temp_dir/master.png" "$ROOT_DIR/web/assets/app-icon.png"

echo "AppIcon 已从同一 1024×1024 母图生成：$MASTER_PATH"
