#!/bin/sh

rm -fr zig-out
rm -fr .zig-cache
# 必须用稳定的开发者证书签名（DN3HDD448D），否则 ad-hoc 签名每次构建都变，
# macOS 的「本地网络」等隐私授权会丢失，导致 ssh 无法连接局域网主机。
# 版本号显式取自 build.zig.zon（去掉 -dev 后缀），不依赖 git describe——
# 否则 HEAD 上存在多个/不匹配的 tag 时构建会 panic。
VERSION=$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -1)
VERSION=${VERSION%%-*}
GHOSTTY_SIGN_TEAM=DN3HDD448D zig build -Doptimize=ReleaseSmall -Dversion-string="$VERSION"

