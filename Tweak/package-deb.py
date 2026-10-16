#!/usr/bin/env python3
# Jev ScreenReader 打包器：Theos 编译 + 手工组装标准 .deb（rootless）
#
# 为什么不用 theos `make package` / macOS `ar`：
#   - theos 打包依赖 dpkg-deb / dm.pl，macOS runner 上不可控；
#   - macOS 的 BSD ar 会写 `#1/N` 扩展名格式，部分 dpkg 版本解析有风险。
# 这里直接用 Python 生成「标准 ar + ./control + ./var/jb 数据」的 deb，
# Sileo / Zebra / dpkg 完全兼容；另附 dylib+plist 的 zip 供 Filza 手动安装。
import gzip
import io
import os
import shutil
import subprocess
import sys
import tarfile
import zipfile

THEOS = os.environ.get("THEOS")
if not THEOS:
    sys.exit("需要 THEOS 环境变量（theos 仓库路径）")

BASE = os.path.dirname(os.path.abspath(__file__))
os.chdir(BASE)

VERSION = None
for line in open("control", encoding="utf-8"):
    if line.startswith("Version:"):
        VERSION = line.split(":", 1)[1].strip()
PKG = "com.jevchat.screenreader"
DYLIB_REL = "var/jb/Library/MobileSubstrate/DynamicLibraries/jev-screenreader.dylib"
PLIST_REL = "var/jb/Library/MobileSubstrate/DynamicLibraries/jev-screenreader.plist"

# ---------- 1) theos 编译 ----------
print("==> Compiling tweak")
subprocess.run(["make"], check=True)

dylib = ".theos/obj/debug/jev-screenreader.dylib"
if not os.path.exists(dylib):
    print("==> lipo arm64 + arm64e")
    subprocess.run(
        ["lipo", "-create",
         ".theos/obj/debug/arm64/jev-screenreader.dylib",
         ".theos/obj/debug/arm64e/jev-screenreader.dylib",
         "-output", dylib],
        check=True)
print("==> dylib:", dylib, os.path.getsize(dylib), "bytes")

# ---------- 2) control.tar.gz：./control ----------
print("==> control.tar.gz")
ctrl_buf = io.BytesIO()
with tarfile.open(fileobj=ctrl_buf, mode="w:gz") as t:
    size = os.path.getsize("control")
    info = tarfile.TarInfo("./control")
    info.size = size
    info.mode = 0o644
    info.mtime = 0
    info.uid = 0
    info.gid = 0
    with open("control", "rb") as f:
        t.addfile(info, f)
ctrl_data = ctrl_buf.getvalue()

# ---------- 3) data.tar.gz：./var/jb/...（rootless 前缀） ----------
print("==> data.tar.gz")
data_buf = io.BytesIO()
with tarfile.open(fileobj=data_buf, mode="w:gz") as t:
    entries = [
        (DYLIB_REL, os.path.join(".theos", "obj", "debug", "jev-screenreader.dylib"), 0o755),
        (PLIST_REL, os.path.join("layout", "Library", "MobileSubstrate",
                                 "DynamicLibraries", "jev-screenreader.plist"), 0o644),
    ]
    for rel, src, mode in entries:
        size = os.path.getsize(src)
        info = tarfile.TarInfo("./" + rel)
        info.size = size
        info.mode = mode
        info.mtime = 0
        info.uid = 0
        info.gid = 0
        with open(src, "rb") as f:
            t.addfile(info, f)
data_data = data_buf.getvalue()

# ---------- 4) 组装标准 ar 归档（成员名均 <=16 字节，无需扩展名表） ----------
def ar_member(name: str, payload: bytes) -> bytes:
    assert len(name) <= 16, name
    size = len(payload)
    header = (
        name.ljust(16)
        + "0".ljust(12)          # date
        + "0".ljust(6)           # uid
        + "0".ljust(6)           # gid
        + "100644".ljust(8)      # mode
        + str(size).ljust(10)    # size
        + "`\n"
    ).encode("ascii")
    out = header + payload
    if size % 2 == 1:
        out += b"\n"             # 偶数对齐
    return out

os.makedirs("packages", exist_ok=True)
deb_path = os.path.join("packages", f"{PKG}_{VERSION}_iphoneos-arm64.deb")
with open(deb_path, "wb") as f:
    f.write(b"!<arch>\n")
    f.write(ar_member("debian-binary", b"2.0\n"))
    f.write(ar_member("control.tar.gz", ctrl_data))
    f.write(ar_member("data.tar.gz", data_data))

# ---------- 5) Filza 手动安装兜底 zip ----------
zip_path = os.path.join("packages", f"jev-screenreader-{VERSION}-manual.zip")
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(".theos", "obj", "debug", "jev-screenreader.dylib"),
            "jev-screenreader.dylib")
    z.write(os.path.join("layout", "Library", "MobileSubstrate", "DynamicLibraries",
                         "jev-screenreader.plist"),
            "jev-screenreader.plist")

print("==> packages:")
for name in sorted(os.listdir("packages")):
    print("   ", name, os.path.getsize(os.path.join("packages", name)), "bytes")
