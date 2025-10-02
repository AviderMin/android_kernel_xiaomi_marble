#!/bin/bash

# 颜色定义
yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'

# 输出带颜色的消息函数
color_echo() {
    local color=$1
    shift
    echo -e "${color}$*${white}"
}

# 确保脚本在出错时退出
set -e

# --- 关键改进 1: 动态定位脚本目录 ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || {
    color_echo "$red" "无法切换到脚本所在目录: $SCRIPT_DIR"
    exit 1
}
color_echo "$green" "工作目录: $SCRIPT_DIR"

# --- 关键改进 2: 参数解析增强 ---
# 参数处理
TARGET_DEVICE=""
KERNEL_NAME="GlowX"
KERNEL_VERSION="v4.2"
FIX_VERSION="2"
USE_KSU=true       # 默认启用 KSU
CCACHE_ENABLED=true
NO_CLEAN=false
USE_THINLTO=true   # 默认开启 ThinLTO
MAKE_FLAGS=""

# 解析目标设备
if [ $# -lt 1 ]; then
    color_echo "$red" "错误: 未指定目标设备"
    color_echo "$yellow" "用法: $0 <设备名称> [选项]"
    exit 1
fi
TARGET_DEVICE="$1"
shift || true

# 处理选项参数
while [ $# -gt 0 ]; do
    case "$1" in
        --noccache)
            CCACHE_ENABLED=false
            shift
            ;;
        --noclean)
            NO_CLEAN=true
            shift
            ;;
        --nothinlto)
            USE_THINLTO=false
            shift
            ;;
        --noksu)
            USE_KSU=false
            shift
            ;;
        --)
            shift
            MAKE_FLAGS="$*"
            break
            ;;
        *)
            color_echo "$yellow" "忽略未知选项: $1"
            shift
            ;;
    esac
done

# --- 关键改进 3: 唯一构建目录 ---
BUILD_DIR="../Releases_${TARGET_DEVICE}_${KERNEL_NAME}"
color_echo "$green" "使用独立构建目录: $BUILD_DIR"

CLANG_PATH=${CLANG_PATH:-$HOME/build_toolchain/clang-r522817/bin}

# 设置完整的工具路径
export CLANG_BIN="$CLANG_PATH/clang"
export CLANGXX_BIN="$CLANG_PATH/clang++"

# 修改产物路径
MAKE_ARGS="O=$BUILD_DIR"

# 编译信息
MAKE_ARGS+=" KBUILD_BUILD_HOST=AviderMin"
MAKE_ARGS+=" KBUILD_BUILD_USER=GlowX"

# 修改编译参数设置
MAKE_ARGS+=" ARCH=arm64"
MAKE_ARGS+=" SUBARCH=arm64"

# LLVM toolchain - 使用完整路径
MAKE_ARGS+=" CC=$CLANG_BIN"
MAKE_ARGS+=" LLVM=1"
MAKE_ARGS+=" LLVM_IAS=1"

# Clang triple (兼容某些内核脚本)
MAKE_ARGS+=" CLANG_TRIPLE=aarch64-linux-gnu-"

# 设置 PATH 环境变量
export PATH="$CLANG_PATH:$PATH"

# 设置ccache
if $CCACHE_ENABLED; then
    export CCACHE_DIR="${HOME}/.cache/ccache_${TARGET_DEVICE}_build"
    export CC="ccache $CLANG_BIN"
    export CXX="ccache $CLANGXX_BIN"
    export PATH="/usr/lib/ccache:$PATH"
    color_echo "$green" "已启用 ccache | 缓存目录: $CCACHE_DIR"
else
    color_echo "$yellow" "警告: 已禁用 ccache，编译速度可能降低"
fi


# 检查设备配置是否存在
if [[ ! -f "$SCRIPT_DIR/arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]]; then
    color_echo "$red" "错误: 未找到目标设备 [$TARGET_DEVICE] 的配置"
    color_echo "$yellow" "可用设备配置:"
    ls "$SCRIPT_DIR/arch/arm64/configs/"*_defconfig | sed "s/.*\///; s/_defconfig//" | xargs printf "  %s\n"
    exit 1
fi

# 显示环境信息
color_echo "$cyan" "=============================================="
color_echo "$green" "构建配置信息:"
color_echo "$cyan" "=============================================="
color_echo "$yellow" "目标设备:    $TARGET_DEVICE"
color_echo "$yellow" "内核名称:    $KERNEL_NAME"
color_echo "$yellow" "内核版本:    $KERNEL_VERSION"
color_echo "$yellow" "修复版本:    $FIX_VERSION"
color_echo "$yellow" "KernelSU:    $($USE_KSU && echo "启用" || echo "禁用")"
color_echo "$yellow" "ThinLTO:     $($USE_THINLTO && echo "启用" || echo "禁用")"
color_echo "$yellow" "ccache:      $($CCACHE_ENABLED && echo "启用" || echo "禁用")"
color_echo "$yellow" "清理:        $($NO_CLEAN && echo "跳过" || echo "执行")"
color_echo "$cyan" "=============================================="

color_echo "$green" "[clang 版本信息]:"
"$CLANG_BIN" --version

# 清理工作区
if ! $NO_CLEAN; then
    color_echo "$yellow" "清理工作区..."
    rm -rf "$BUILD_DIR"
else
    color_echo "$yellow" "跳过清理步骤..."
fi

# 添加日期到本地版本
LOCAL_VERSION_STR="-GlowX"
LOCAL_VERSION_DATE="-${KERNEL_NAME}-${KERNEL_VERSION}-$(date +%y%m%d)${FIX_VERSION}"
touch .scmversion

# 配置内核
color_echo "$green" "配置 ${TARGET_DEVICE}_defconfig..."
make $MAKE_ARGS "${TARGET_DEVICE}_defconfig"

# 设置本地版本
./scripts/config --file "$BUILD_DIR/.config" --set-str CONFIG_LOCALVERSION "$LOCAL_VERSION_DATE"

# 根据 KSU 启用/禁用配置
if $USE_KSU; then
    color_echo "$green" "启用 KernelSU..."
    ./scripts/config --file "$BUILD_DIR/.config" \
        -e KSU \
        -e KSU_MANUAL_HOOK \
        -e KSU_SUSFS_HAS_MAGIC_MOUNT \
        -e KSU_SUSFS_SUS_MOUNT \
        -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
        -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
        -e KSU_SUSFS_SUS_KSTAT \
        -e KSU_SUSFS_TRY_UMOUNT \
        -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
        -e KSU_SUSFS_SPOOF_UNAME \
        -e KSU_SUSFS_ENABLE_LOG \
        -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
        -e KSU_MULTI_MANAGER_SUPPORT \
        -d KSU_SUSFS_SUS_SU

else
    color_echo "$yellow" "禁用 KernelSU..."
    ./scripts/config --file "$BUILD_DIR/.config" \
        -d KSU \
        -d KSU_MANUAL_HOOK \
        -d KSU_SUSFS_HAS_MAGIC_MOUNT \
        -d KSU_SUSFS_SUS_MOUNT \
        -d KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
        -d KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
        -d KSU_SUSFS_SUS_KSTAT \
        -d KSU_SUSFS_TRY_UMOUNT \
        -d KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
        -d KSU_SUSFS_SPOOF_UNAME \
        -d KSU_SUSFS_ENABLE_LOG \
        -d KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -d KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
        -d KSU_MULTI_MANAGER_SUPPORT \
        -d KSU_SUSFS_SUS_SU
fi

# 处理LTO配置
if $USE_THINLTO; then
    color_echo "$green" "启用 ThinLTO..."
    ./scripts/config --file "$BUILD_DIR/.config" -e LTO_CLANG -e THINLTO
else
    color_echo "$yellow" "禁用 ThinLTO..."
    ./scripts/config --file "$BUILD_DIR/.config" -e LTO_CLANG -d THINLTO
fi

make $MAKE_ARGS olddefconfig

# 记录开始时间
START_TIME=$(date +%s)
NUM_JOBS=$(nproc --all)

# 编译内核
color_echo "$green" "开始编译内核 (使用 $NUM_JOBS 个线程)..."
make $MAKE_ARGS -j$(nproc --all) $MAKE_FLAGS

# 检查编译结果
IMAGE_PATH="$BUILD_DIR/arch/arm64/boot/Image"
if [[ ! -f "$IMAGE_PATH" ]]; then
    color_echo "$red" "错误: 未找到内核镜像 [$IMAGE_PATH]，编译失败"
    exit 1
fi

# 计算编译时间
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

color_echo "$green" "编译成功! 耗时: ${MINUTES}分${SECONDS}秒"

ANY_KERNEL_DIR="$SCRIPT_DIR/anykernel"

cp "$IMAGE_PATH" "$ANY_KERNEL_DIR"

# 创建ZIP文件名
KSU_STR=$($USE_KSU && echo "SU" || echo "NoSU")
ZIP_NAME="${TARGET_DEVICE}_${KERNEL_NAME}-${KERNEL_VERSION}_${KSU_STR}_$(date +%y%m%d)${FIX_VERSION}.zip"

color_echo "$green" "创建刷机包: $ZIP_NAME"
(cd "$ANY_KERNEL_DIR" && zip -r9 "$ZIP_NAME" ./* -x .git .gitignore out/ ./*.zip)

mv "$ANY_KERNEL_DIR/$ZIP_NAME" "$BUILD_DIR/"

color_echo "$green" "完成! 刷机包已保存到: [$BUILD_DIR/$ZIP_NAME]"

color_echo "$green" "ALL DONE"
