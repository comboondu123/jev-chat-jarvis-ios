#!/usr/bin/env bash
# Jev Jarvis → TrollStore IPA 打包脚本
#
# 用法: bash tools/trollstore/make-ipa.sh <Release-iphoneos 产物目录> <输出目录>
#
# 作用:
#   1) 用 ldid 给 App 和键盘扩展分别写入仓库自带的 entitlements
#      (App/JevJarvis.entitlements、Keyboard/JevKeyboard.entitlements)——
#      这是免签名安装的关键: App 与键盘靠同一个 App Group
#      (group.com.jevchat.jarvis) 共享配置,必须写进签名里。
#   2) 校验两份二进制确实带上了 App Group。
#   3) 打包成 Payload/JevJarvis.app 结构的 .ipa,供 TrollStore 直接安装。
#
# 说明: 本脚本运行在 GitHub Actions 的 macOS runner 上(bash 可用);
#       Windows 本机无需也无法运行它。
set -euo pipefail

APP_NAME="JevJarvis"
KB_NAME="JevKeyboard"
PRODUCTS_DIR="${1:?缺少参数 1: Release-iphoneos 产物目录}"
OUT_DIR_ARG="${2:?缺少参数 2: 输出目录}"
# 输出目录转成绝对路径(pushd 之后相对路径会失效)
OUT_DIR="$(cd "$(dirname "$OUT_DIR_ARG")" && pwd)/$(basename "$OUT_DIR_ARG")"
ENT_APP="App/JevJarvis.entitlements"
ENT_KB="Keyboard/JevKeyboard.entitlements"
GROUP_ID="group.com.jevchat.jarvis"

APP="$PRODUCTS_DIR/$APP_NAME.app"
KB_APPEX="$APP/PlugIns/$KB_NAME.appex"

# 0) 前置检查
for f in "$APP" "$KB_APPEX"; do
  test -d "$f" || { echo "错误: 找不到 $f"; exit 1; }
done
test -f "$ENT_APP" || { echo "错误: 找不到 $ENT_APP"; exit 1; }
test -f "$ENT_KB"  || { echo "错误: 找不到 $ENT_KB"; exit 1; }

# 1) 清掉 Xcode 可能留下的签名残留,再分别写入 entitlements
rm -rf "$APP/_CodeSignature" "$APP/CodeResources" \
       "$KB_APPEX/_CodeSignature" "$KB_APPEX/CodeResources"
ldid -S"$ENT_APP" "$APP/$APP_NAME"
ldid -S"$ENT_KB" "$KB_APPEX/$KB_NAME"

# 2) 校验 entitlements 已写入(必须带 App Group)
ldid -e "$APP/$APP_NAME" | grep -q "$GROUP_ID" \
  || { echo "错误: App 签名里缺 $GROUP_ID"; exit 1; }
ldid -e "$KB_APPEX/$KB_NAME" | grep -q "$GROUP_ID" \
  || { echo "错误: 键盘签名里缺 $GROUP_ID"; exit 1; }
echo "OK: 两个二进制均已写入 $GROUP_ID"

# 3) 打包 IPA
mkdir -p "$OUT_DIR"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
pushd "$STAGE" >/dev/null
zip -qry "$OUT_DIR/jev-jarvis-trollstore.ipa" Payload
popd >/dev/null

echo "完成: $OUT_DIR/jev-jarvis-trollstore.ipa"
