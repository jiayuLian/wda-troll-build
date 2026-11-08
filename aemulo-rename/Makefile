TARGET := iphone:clang:latest:14.0
# 单架构 arm64：Aemulo 主二进制就是 arm64-only（cputype 0x100000c），
# 编 fat 反而要多处理一遍 ldid，没必要。
ARCHS := arm64

include $(THEOS)/makefiles/common.mk

# 必须用 library.mk，不能用 tweak.mk：
# tweak.mk 会自动链 CydiaSubstrate，TrollStore 设备上没有它，
# dyld 加载期直接 Library not loaded -> App 一启动就闪退。
LIBRARY_NAME = AemuloRename
AemuloRename_FILES = AemuloRename.m
AemuloRename_CFLAGS = -fobjc-arc -g0 -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable
AemuloRename_FRAMEWORKS = UIKit Foundation
AemuloRename_LIBRARIES = sqlite3
# 注入点在 @executable_path/Frameworks/，install_name 用绝对路径避免依赖 LC_RPATH
AemuloRename_LDFLAGS = -Wl,-install_name,@executable_path/Frameworks/AemuloRename.dylib -Wl,-dead_strip

include $(THEOS)/makefiles/library.mk
