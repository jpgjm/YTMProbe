# YTMProbe — YouTube Music 注入検証用 tweak
#
# Theos でビルドする。出力は .theos/obj/debug/YTMProbe.dylib
#
# ローカルでビルドする場合:
#   export THEOS=~/theos
#   make clean && make

# ── TARGET の見方 ────────────────────────────────────────
#
#   iphone:clang:<ビルドに使う SDK>:<動作させる最低 iOS 版>
#
# SDK 版は theos/sdks から取得できたものに合わせる必要がある。
# 無い版を指定すると Theos が黙って別の版に落とすことがあり、
# 後から分かりにくい失敗になる。
#
# CI では `latest` にして、取得できた中で最新のものを使わせる。
# ローカルで特定版に固定したいときは、環境変数で上書きできる:
#
#   make YTMPROBE_SDK=16.5
#
YTMPROBE_SDK ?= latest
TARGET := iphone:clang:$(YTMPROBE_SDK):15.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = YouTubeMusic

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTMProbe

YTMProbe_FILES = YTMProbe.x
YTMProbe_FRAMEWORKS = UIKit Foundation Security

# ── コンパイルフラグの意図 ────────────────────────────────
#
# Theos は既定で -Werror を付ける。この tweak は非公開 API を
# 実行時に手探りで呼ぶ性質上、警告が出やすい箇所がある。
# ただし警告を一律で潰すと本当の不具合を見落とすので、
# 「この tweak では避けようがないもの」だけを個別に外す。
#
#   deprecated-declarations
#     非公開 API を扱う都合上、古い API に触れることがある。
#
#   arc-performSelector-leaks
#     現在は NSInvocation に寄せてあり出ないはずだが、
#     手探りの過程で performSelector: を足したときに
#     ビルドが止まらないようにしておく。
#     (実際にリークしうる箇所なので、恒久的に使わないこと)
#
#   unused-parameter
#     ログの sink など、形を揃えるために引数を残す箇所がある。
#
# -Werror 自体は残す。上記以外の警告はビルドを止めてよい。
YTMProbe_CFLAGS = -fobjc-arc \
                  -Wno-deprecated-declarations \
                  -Wno-arc-performSelector-leaks \
                  -Wno-unused-parameter

include $(THEOS_MAKE_PATH)/tweak.mk
