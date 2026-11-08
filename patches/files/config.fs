# Image file modes come from fs_config, not from the staging directory (measured:
# the staged copy was 0755 while the device showed 0644). Its built-in table gives
# 0755 to bin/*-like paths and 0644 to app directories.
#
# ksud is exec'd, not dlopen'd, and a file without an +x bit cannot be exec'd even
# by root (measured), so the file that delivers ksud needs an explicit 0755.
# The caps: 0 form follows device/xiaomi/sm8250-common/config.fs.
[product/bin/ksud]
mode: 0755
user: AID_ROOT
group: AID_SHELL
caps: 0

# BEGIN manager-jni
# Only with a preinstalled manager (KSU_PREINSTALL_MANAGER=1). The manager looks up
# libksud.so in its own native library dir and execs it, and preprocessed keeps the
# JNI libraries inside the APK, so that dir has to be provided as files - and those
# need the same +x bit. apply-root-changes.sh expands @KSU_PKG@ and drops this whole
# block when no manager is preinstalled, which keeps the package name out of the
# image. Build 17 measured what a stale path costs: the pattern stopped matching,
# ksud lost its +x bit, and the manager showed "not the official manager" with
# Modules: 0.
[product/app/@KSU_PKG@/lib/arm64/*]
mode: 0755
user: AID_ROOT
group: AID_SHELL
caps: 0
# END manager-jni
