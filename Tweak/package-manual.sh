#!/bin/bash
# Jev ScreenReader 手动打包（rootless .deb + Filza zip 兜底）
#
# 为什么不用 theos 的 `make package`：macOS runner 上它依赖 dpkg-deb / dm.pl，
# 踩坑不可控；这里直接用 macOS 自带的 ar/tar/gzip/lipo 组装标准 deb，
# 产物与 Sileo/Zebra 完全兼容，另附一份 dylib+plist 的 zip 供 Filza 手动安装。
set -euo pipefail
cd "$(dirname "$0")"

export THEOS="${THEOS:?需要 THEOS 环境变量（theos 仓库路径）}"
VERSION=$(awk '/^Version:/{print $2}' control)
PKG=com.jevchat.screenreader

echo "==> Compiling tweak ($THEOS)"
make

# 定位 fat dylib（Theos 多架构产物在 obj/debug 顶层；个别版本只在子目录，需 lipo）
DYLIB=""
if [ -f .theos/obj/debug/jev-screenreader.dylib ]; then
  DYLIB=.theos/obj/debug/jev-screenreader.dylib
else
  lipo -create \
    .theos/obj/debug/arm64/jev-screenreader.dylib \
    .theos/obj/debug/arm64e/jev-screenreader.dylib \
    -output .theos/obj/debug/jev-screenreader.dylib
  DYLIB=.theos/obj/debug/jev-screenreader.dylib
fi
echo "==> dylib: $DYLIB"
file "$DYLIB"

rm -rf packages
mkdir -p packages/rootfs/var/jb/Library/MobileSubstrate/DynamicLibraries
mkdir -p packages/ctrl/DEBIAN

# data 部分：rootless 一律装到 /var/jb 前缀下
cp "$DYLIB" packages/rootfs/var/jb/Library/MobileSubstrate/DynamicLibraries/jev-screenreader.dylib
cp layout/Library/MobileSubstrate/DynamicLibraries/jev-screenreader.plist \
   packages/rootfs/var/jb/Library/MobileSubstrate/DynamicLibraries/jev-screenreader.plist

# control 部分
cp control packages/ctrl/DEBIAN/control

# 组装标准 deb：debian-binary + control.tar.gz + data.tar.gz，ar 归档
printf '2.0\n' > packages/debian-binary
( cd packages/ctrl   && tar -czf ../control.tar.gz ./DEBIAN/control )
( cd packages/rootfs && tar -czf ../data.tar.gz ./var )
( cd packages && ar -q "${PKG}_${VERSION}_iphoneos-arm64.deb" \
      debian-binary control.tar.gz data.tar.gz )

# Filza 手动安装兜底 zip（dylib + plist）
( cd packages && zip -j "jev-screenreader-${VERSION}-manual.zip" \
      rootfs/var/jb/Library/MobileSubstrate/DynamicLibraries/jev-screenreader.dylib \
      rootfs/var/jb/Library/MobileSubstrate/DynamicLibraries/jev-screenreader.plist )

echo "==> packages:"
ls -lh packages/*.deb packages/*.zip
