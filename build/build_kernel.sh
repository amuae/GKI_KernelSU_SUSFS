#!/usr/bin/env bash
set -euo pipefail

# Build script for Android 14 Kernel 6.1.118
# This script applies patches and builds the kernel Image only
#
# Usage: ./build_kernel.sh [OPTIONS]
#   --module-bypass        Apply module version check bypass (optional)
#   --kernel-name NAME     Custom kernel name suffix (default: gca0ef6d17716-ab13624819)
#   --build-time TIME      Custom build timestamp (default: Tue Jun 10 18:59:08 UTC 2025)
#                          Format: "Day Mon DD HH:MM:SS UTC YYYY" or "auto"
#   --hook-method METHOD   Hook method: manual, syscall, or kprobes (default: manual)
#   --enable-kpm           Enable KPM (Kernel Patch Module) support (experimental)

# Force IPv4 for all network operations to avoid IPv6 connection issues
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0="url.https://github.com/.insteadOf"
export GIT_CONFIG_VALUE_0="git://github.com/"
export GIT_CONFIG_KEY_1="http.version"
export GIT_CONFIG_VALUE_1="HTTP/1.1"

# Configure git to use IPv4
git config --global core.gitProxy "" 2>/dev/null || true
git config --global http.version HTTP/1.1 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Parse command line arguments
MODULE_BYPASS=false
KERNEL_NAME="gca0ef6d17716-ab13624819"
BUILD_TIME="Tue Jun 10 18:59:08 UTC 2025"
HOOK_METHOD="manual"
ENABLE_KPM=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --module-bypass)
            MODULE_BYPASS=true
            shift
            ;;
        --kernel-name)
            KERNEL_NAME="$2"
            shift 2
            ;;
        --build-time)
            BUILD_TIME="$2"
            shift 2
            ;;
        --hook-method)
            HOOK_METHOD="$2"
            if [[ ! "$HOOK_METHOD" =~ ^(manual|syscall|kprobes)$ ]]; then
                echo "错误: hook-method 必须是 manual, syscall, 或 kprobes"
                exit 1
            fi
            shift 2
            ;;
        --enable-kpm)
            ENABLE_KPM=true
            shift
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--module-bypass] [--kernel-name NAME] [--build-time TIME] [--hook-method METHOD] [--enable-kpm]"
            exit 1
            ;;
    esac
done

# Configuration
ANDROID_VERSION="android14"
KERNEL_VERSION="6.1"
OS_PATCH_LEVEL="2025-01"
WORK_DIR="android14-6.1-118-work"
CONFIG="${ANDROID_VERSION}-${KERNEL_VERSION}-118"

echo "=== GKI Kernel Build Script ==="
echo "Android Version: $ANDROID_VERSION"
echo "Kernel Version: $KERNEL_VERSION"
echo "OS Patch Level: $OS_PATCH_LEVEL"
echo "Working Directory: $WORK_DIR"
echo "Module Bypass: $MODULE_BYPASS"
echo "Kernel Name: $KERNEL_NAME"
echo "Build Time: $BUILD_TIME"
echo "Hook Method: $HOOK_METHOD"
echo "Enable KPM: $ENABLE_KPM"
echo ""

# Download dependencies if not exist
echo "=== Checking Dependencies ==="
if [ ! -d "susfs4ksu" ]; then
    echo "Downloading susfs4ksu..."
    SUSFS_BRANCH="gki-${ANDROID_VERSION}-${KERNEL_VERSION}"
    git clone https://gitlab.com/simonpunk/susfs4ksu.git -b "$SUSFS_BRANCH"
fi

if [ ! -d "SukiSU_patch" ]; then
    echo "Downloading SukiSU_patch..."
    git clone https://github.com/ShirkNeko/SukiSU_patch.git
fi

if [ ! -d "AnyKernel3" ]; then
    echo "Downloading AnyKernel3..."
    git clone https://github.com/WildKernels/AnyKernel3.git -b gki-2.0
    echo "[OK] AnyKernel3 (GKI-2.0) downloaded"
fi
echo ""

# Check if original source exists (skip in CI environment)
if [ -z "$CI" ]; then
    # Local build: copy from original source to work directory
    ORIGINAL_DIR="android14-6.1-118"
    if [ ! -d "$ORIGINAL_DIR" ]; then
        echo "Error: Original source directory $ORIGINAL_DIR not found!"
        echo "Please run download_kernel.sh first."
        exit 1
    fi

    # Clean and recreate working directory from original source
    echo "=== Preparing Working Directory ==="
    if [ -d "$WORK_DIR" ]; then
        echo "Removing existing working directory..."
        rm -rf "$WORK_DIR"
    fi

    echo "Copying fresh source from $ORIGINAL_DIR to $WORK_DIR..."
    echo "This may take a few minutes..."
    cp -r "$ORIGINAL_DIR" "$WORK_DIR"
    echo "Fresh copy created successfully!"
    echo ""
else
    # CI environment: use source directory directly (no copy needed)
    echo "=== CI Environment Detected ==="
    echo "Using source directory directly: $WORK_DIR"
    if [ ! -d "$WORK_DIR" ]; then
        echo "Error: Source directory $WORK_DIR not found!"
        exit 1
    fi
    echo ""
fi

# ============================================================================
# 添加KernelSU (完全按照amuae工作流)
# ============================================================================
echo "=== 添加KernelSU ==="
cd "$WORK_DIR"

echo "正在配置SukiSU Ultra..."
curl -4 -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU-Ultra/refs/heads/main/kernel/setup.sh" | bash -s susfs-main

cd ./KernelSU

# 获取当前 Git 提交的短哈希 (8位)
GIT_COMMIT_HASH=$(git rev-parse --short=8 HEAD)
echo "当前提交哈希: $GIT_COMMIT_HASH"

# 尝试最多 3 次获取 KernelSU API 版本号
KSU_API_VERSION=""
for i in {1..3}; do
    KSU_API_VERSION=$(curl -4 -s "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/susfs-main/kernel/Makefile" | \
        grep -m1 "KSU_VERSION_API :=" | \
        awk -F'= ' '{print $2}' | \
        tr -d '[:space:]' || echo "")
    if [ -n "$KSU_API_VERSION" ]; then
        break
    fi
    sleep 1
done

if [ -z "$KSU_API_VERSION" ]; then
    KSU_API_VERSION="3.1.7"
    echo "[WARN] 无法获取远程 API 版本，使用默认: $KSU_API_VERSION"
else
    echo "[OK] KSU API版本: $KSU_API_VERSION"
fi

# 创建版本定义模板
VERSION_DEFINITIONS=$'define get_ksu_version_full\nv\\$1-'"$GIT_COMMIT_HASH"$'@main_test\nendef\n\nKSU_VERSION_API := '"$KSU_API_VERSION"$'\nKSU_VERSION_FULL := v'"$KSU_API_VERSION"$'-'"$GIT_COMMIT_HASH"$'@main_test'

# 清理内核 Makefile 中的旧版本定义
sed -i '/define get_ksu_version_full/,/endef/d' kernel/Makefile || true
sed -i '/KSU_VERSION_API :=/d' kernel/Makefile || true
sed -i '/KSU_VERSION_FULL :=/d' kernel/Makefile || true

# 在 REPO_OWNER 行后插入新版本定义
if grep -q "REPO_OWNER" kernel/Makefile; then
    awk -v def="$VERSION_DEFINITIONS" '
        /REPO_OWNER :=/ {print; print def; inserted=1; next}
        1
        END {if (!inserted) print def}
    ' kernel/Makefile > kernel/Makefile.tmp && mv kernel/Makefile.tmp kernel/Makefile
    echo "[OK] 版本定义已添加到 kernel/Makefile"
else
    echo "$VERSION_DEFINITIONS" >> kernel/Makefile
    echo "[OK] 版本定义已追加到 kernel/Makefile"
fi

# 生成自定义版本号
KSU_VERSION=$(git rev-list --count main 2>/dev/null || echo 0)
if [ "$KSU_VERSION" != "0" ]; then
    KSU_VERSION=$((KSU_VERSION + 37185))
else
    KSU_VERSION=114514
fi
echo "[OK] KSU版本号: $KSU_VERSION"

# 验证修改结果（不强制要求成功）
echo "验证 Makefile 修改..."
grep -A5 "REPO_OWNER" kernel/Makefile || echo "[WARN] REPO_OWNER not found"
grep "KSU_VERSION_FULL" kernel/Makefile || echo "[WARN] KSU_VERSION_FULL not found"
echo "[OK] SukiSU版本号: v${KSU_API_VERSION}-${GIT_COMMIT_HASH}@main_test"

cd ..

echo ""

# Extract actual sublevel from Makefile
echo "=== Extracting Kernel Version ==="
if [ -f "common/Makefile" ]; then
    ACTUAL_SUBLEVEL=$(grep '^SUBLEVEL = ' common/Makefile | awk '{print $3}')
    echo "Detected SUBLEVEL: $ACTUAL_SUBLEVEL"
else
    echo "Error: common/Makefile not found!"
    exit 1
fi

# Apply glibc 2.38 compatibility fix if needed
echo ""
echo "=== Applying Compatibility Fixes ==="
if [[ "$ANDROID_VERSION" == "android14" ]] && [[ "$KERNEL_VERSION" == "6.1" ]] && (( $ACTUAL_SUBLEVEL <= 43 )); then
    GLIBC_VERSION=$(ldd --version 2>/dev/null | head -n 1 | awk '{print $NF}')
    if [ "$(printf '%s\n' "2.38" "$GLIBC_VERSION" | sort -V | head -n1)" = "2.38" ]; then
        echo "Applying glibc 2.38 compatibility fix..."
        cd common/
        sed -i '/\$(Q)\$(MAKE) -C \$(SUBCMD_SRC) OUTPUT=\$(abspath \$(dir \$@))\/ \$(abspath \$@)/s//$(Q)$(MAKE) -C $(SUBCMD_SRC) EXTRA_CFLAGS="$(CFLAGS)" OUTPUT=$(abspath $(dir $@))\/ $(abspath $@)/' tools/bpf/resolve_btfids/Makefile 2>/dev/null || true
        cd ..
    fi
fi

# ============================================================================
# 应用 KernelSU & SUSFS 补丁 (完全按照amuae工作流)
# ============================================================================
echo ""
echo "=== 应用 KernelSU & SUSFS 补丁 ==="

echo "正在添加SukiSU Ultra补丁..."
git clone https://github.com/ShirkNeko/susfs4ksu.git -b gki-${ANDROID_VERSION}-${KERNEL_VERSION}
git clone https://github.com/ShirkNeko/SukiSU_patch.git

# 复制SUSFS补丁到common
cp ./susfs4ksu/kernel_patches/50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch ./common/

# 复制SUSFS源文件
cp -r ./susfs4ksu/kernel_patches/fs/* ./common/fs/
cp -r ./susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

# 应用补丁到common
cd common
patch -p1 < 50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch || true

# 应用hook补丁
if [ "$HOOK_METHOD" == "kprobes" ]; then
    echo "正在使用kprobes钩子..."
elif [ "$HOOK_METHOD" == "manual" ]; then
    echo "正在应用manual钩子补丁..."
    cp ../SukiSU_patch/hooks/scope_min_manual_hooks_v1.6.patch ./
    patch -p1 -F 3 < scope_min_manual_hooks_v1.6.patch || true
elif [ "$HOOK_METHOD" == "syscall" ]; then
    echo "正在应用syscall钩子补丁..."
    cp ../SukiSU_patch/hooks/syscall_hooks.patch ./
    patch -p1 -F 3 < syscall_hooks.patch || true
fi

# 应用hide stuff补丁
cp ../SukiSU_patch/69_hide_stuff.patch ./
patch -p1 -F 3 < 69_hide_stuff.patch || true

cd ..

# ============================================================================
# 应用额外补丁 (config.patch等)
# ============================================================================
echo ""
echo "=== 应用额外补丁 ==="
cd common
wget -4 -q https://github.com/cctv18/oppo_oplus_realme_sm8650/raw/refs/heads/main/other_patch/config.patch || true
if [ -f "config.patch" ]; then
    patch -p1 -F 3 < config.patch || true
    echo "[OK] config.patch已应用"
fi
cd ..

# Add BBG (Baseband-guard)
if [ "${ENABLE_BBG:-true}" = "true" ]; then
    echo ""
    echo "=== Adding Baseband Guard (BBG) ==="
    wget -4 -q -O- https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash 2>&1 | grep -v "awk:" || true
    echo "CONFIG_BBG=y" >> common/arch/arm64/configs/gki_defconfig
    sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/lockdown/lockdown,baseband_guard/ } }' common/security/Kconfig
    echo "BBG configured successfully"
else
    echo ""
    echo "=== Skipping Baseband Guard (BBG) ==="
fi

# Samsung device fixes for 6.6 GKI
if [[ "$KERNEL_VERSION" == "6.6" ]]; then
    echo ""
    echo "=== Applying Samsung Device Fixes ==="
    
    SYMBOL_LIST=common/android/abi_gki_aarch64_galaxy
    if [ ! -f "$SYMBOL_LIST" ]; then
        touch "$SYMBOL_LIST"
    fi
    
    echo "Adding Samsung KDP symbols..."
    echo "kdp_set_cred_non_rcu" >> $SYMBOL_LIST
    echo "kdp_usecount_dec_and_test" >> $SYMBOL_LIST
    echo "kdp_usecount_inc" >> $SYMBOL_LIST
    
    # Download min_kdp patch
    cd common
    if [ ! -f "../../min_kdp_patch.patch" ]; then
        wget -4 -q -O ../../min_kdp_patch.patch https://raw.githubusercontent.com/ShirkNeko/SukiSU_patch/refs/heads/master/other/min_kdp/add-min_kdp-symbols.patch || true
    fi
    
    if [ -f "../../min_kdp_patch.patch" ]; then
        if patch -p1 --dry-run < ../../min_kdp_patch.patch &>/dev/null; then
            patch -p1 --no-backup-if-mismatch < ../../min_kdp_patch.patch
            echo "[OK] Applied min_kdp symbols patch"
        else
            echo "[WARN] min_kdp patch already applied or not needed"
        fi
    fi
    
    # Download and add min_kdp.c driver
    cd drivers
    if [ ! -f "min_kdp.c" ]; then
        wget -4 -q -O min_kdp.c https://raw.githubusercontent.com/ShirkNeko/SukiSU_patch/refs/heads/master/other/min_kdp/min_kdp.c || true
        if [ -f "min_kdp.c" ]; then
            echo "obj-y += min_kdp.o" >> Makefile
            echo "[OK] Added min_kdp driver"
        fi
    fi
    
    cd ../..
    echo "Samsung device fixes applied"
fi

# Configure kernel
echo ""
echo "=== Configuring Kernel ==="
DEFCONFIG="./common/arch/arm64/configs/gki_defconfig"

# Remove defconfig check
sed -i 's/check_defconfig//' ./common/build.config.gki

echo "Adding kernel configurations..."

# KernelSU Configuration based on hook method
if [[ "$HOOK_METHOD" == "kprobes" ]]; then
    cat >> "$DEFCONFIG" << 'EOF'

# KernelSU Configuration (kprobes mode)
CONFIG_KSU=y
CONFIG_KSU_SUSFS_SUS_SU=y
CONFIG_KSU_MANUAL_HOOK=n
CONFIG_KSU_KPROBES_HOOK=y
EOF
else
    cat >> "$DEFCONFIG" << 'EOF'

# KernelSU Configuration (manual/syscall mode)
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_SUSFS_SUS_SU=n
EOF
fi

# Add KPM support if enabled
if [ "$ENABLE_KPM" = true ]; then
    echo "CONFIG_KPM=y" >> "$DEFCONFIG"
    echo "[OK] KPM support enabled"
fi

cat >> "$DEFCONFIG" << 'EOF'

# Mountify Support
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y

# Networking Configuration
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
EOF

# BBR TCP Congestion Control (optional)
if [ "${ENABLE_BBR:-true}" = "true" ]; then
    cat >> "$DEFCONFIG" << 'EOF'

# BBR TCP Congestion Control
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_TCP_CONG_BIC=n
CONFIG_TCP_CONG_WESTWOOD=n
CONFIG_TCP_CONG_HTCP=n
EOF
fi

# IPSet Support (optional)
if [ "${ENABLE_IPSET:-true}" = "true" ]; then
    cat >> "$DEFCONFIG" << 'EOF'

# IPSet Support
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
EOF
fi

cat >> "$DEFCONFIG" << 'EOF'

# SUSFS Configuration (15 items - matching amuae exactly)
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y

# Sound Configuration (snd-aloop)
CONFIG_SND=y
CONFIG_SND_DRIVERS=y
CONFIG_SND_PCM=y
CONFIG_SND_TIMER=y
CONFIG_SND_DYNAMIC_MINORS=y
CONFIG_SND_PROC_FS=y
CONFIG_SND_ALOOP=m
EOF

# Build Optimization Configuration (optional)
if [ "${ENABLE_LTO:-true}" = "true" ]; then
    cat >> "$DEFCONFIG" << 'EOF'

# Build Optimization Configuration
CONFIG_LTO_CLANG_THIN=y
CONFIG_LTO_CLANG=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=n
CONFIG_OPTIMIZE_INLINING=y
EOF
fi

echo "Configuration complete!"

# Add snd-aloop to modules list
echo "Adding snd-aloop.ko to modules list..."
echo "sound/drivers/snd-aloop.ko" >> common/android/gki_aarch64_modules

if [[ -f common/modules.bzl ]]; then
    echo "Injecting snd-aloop into modules.bzl..."
    if [[ "$ANDROID_VERSION" == "android14" ]] && [[ "$KERNEL_VERSION" == "6.1" ]] && (( $ACTUAL_SUBLEVEL <= 25 )) && [[ "$OS_PATCH_LEVEL" != "2023-09" ]]; then
        sed -i '/COMMON_GKI_MODULES_LIST = \[/,/^[[:space:]]*\]/{/^[[:space:]]*\]$/i\    "sound/drivers/snd-aloop.ko",
        }' common/modules.bzl
    else
        sed -i '/_COMMON_GKI_MODULES_LIST = \[/,/^[[:space:]]*\]/{/^[[:space:]]*\]$/i\    "sound/drivers/snd-aloop.ko",
        }' common/modules.bzl
    fi
    
    if grep -q '"sound/drivers/snd-aloop.ko"' common/modules.bzl; then
        echo "[OK] snd-aloop successfully added to modules.bzl"
    else
        echo "[ERROR] Failed to add snd-aloop to modules.bzl"
    fi
fi

# ABI bypass for Android 14 6.1
echo "Applying ABI check bypass..."
perl -i -pe 's/^(\s*)return 1$/$1print("Who Cares? Bypassing Now!")\n$1return 0/g if /if missing_symbols:/../return 1/' build/kernel/abi/check_buildtime_symbol_protection.py

# Apply module check bypass if requested
if [ "$MODULE_BYPASS" = true ]; then
    echo ""
    echo "=== Applying Module Check Bypass ==="
    if [[ "$KERNEL_VERSION" == "6.1" ]] || [[ "$KERNEL_VERSION" == "6.6" ]]; then
        TARGET_FILE="common/kernel/module/version.c"
    else
        TARGET_FILE="common/kernel/module.c"
    fi
    
    if [ -f "$TARGET_FILE" ]; then
        # Change 'return 0' to 'return 1' after 'bad_version:' label
        sed -i '/bad_version:/{:a;n;/return 0;/{s/return 0;/return 1;/;b};ba}' "$TARGET_FILE"
        echo "[OK] Module check bypass applied to $TARGET_FILE"
    else
        echo "[WARN] Target file $TARGET_FILE not found, skipping bypass"
    fi
fi

# Modify kernel version string
echo ""
echo "=== Modifying Kernel Version ==="
echo "Setting kernel name to: $KERNEL_NAME"

# Download time hijacking libraries for precise timestamp control
echo "Preparing timestamp control..."
cd common
if [ ! -f "libfakestat.so" ]; then
    wget -4 -q https://github.com/cctv18/oppo_oplus_realme_sm8650/raw/refs/heads/main/lib/libfakestat.so || true
fi
if [ ! -f "libfaketimeMT.so" ]; then
    wget -4 -q https://github.com/cctv18/oppo_oplus_realme_sm8650/raw/refs/heads/main/lib/libfaketimeMT.so || true
fi

# Make libraries executable if downloaded
if [ -f "libfakestat.so" ] && [ -f "libfaketimeMT.so" ]; then
    chmod 777 ./*.so
    echo "[OK] Time hijacking libraries ready"
else
    echo "[WARN] Time hijacking libraries not available, using standard method"
fi
cd ..

# Add custom kernel name suffix
sed -i "\$s|echo \"\\\$res\"|echo \"\\\$res-${KERNEL_NAME}\"|" ./common/scripts/setlocalversion

# Set kernel timestamp via SOURCE_DATE_EPOCH
if [ "$BUILD_TIME" = "auto" ]; then
    echo "Using automatic build time (current UTC)"
    # Use current UTC time - convert to epoch
    BUILD_TIMESTAMP=$(date -u +%s)
else
    echo "Using custom build time: $BUILD_TIME"
    # Convert custom time string to epoch timestamp
    BUILD_TIMESTAMP=$(date -u -d "$BUILD_TIME" +%s 2>/dev/null || echo "1749492000")
fi

echo "Build timestamp (epoch): $BUILD_TIMESTAMP"

# Modify stamp.bzl to use custom SOURCE_DATE_EPOCH instead of 0
sed -i "s/export SOURCE_DATE_EPOCH=0/export SOURCE_DATE_EPOCH=$BUILD_TIMESTAMP/" ./build/kernel/kleaf/impl/stamp.bzl

# Remove dirty flag
sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" ./build/kernel/kleaf/impl/stamp.bzl

# Remove ABI exports
rm -rf ./common/android/abi_gki_protected_exports_*
perl -pi -e 's/^\s*"protected_exports_list"\s*:\s*"android\/abi_gki_protected_exports_aarch64",\s*$//;' ./common/BUILD.bazel

# Build kernel
echo ""
echo "=== Building Kernel ==="
echo "This may take 30-60 minutes depending on your CPU..."
echo "Build started at: $(date)"
echo ""

if [ -f "build/build.sh" ]; then
    echo "Using build.sh (legacy method)..."
    LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh
    IMAGE_PATH="out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/Image"
else
    echo "Using bazel (modern method)..."
    # Fix for non-ASCII path: Create symlink with ASCII-only path
    TEMP_LINK="/tmp/kernel-build-$(date +%s)"
    ln -s "$(pwd)" "$TEMP_LINK"
    cd "$TEMP_LINK"
    
    # Build with bazel
    tools/bazel build --config=fast --lto=thin //common:kernel_aarch64_dist
    
    # Return to original directory
    cd "$SCRIPT_DIR/$WORK_DIR"
    IMAGE_PATH="bazel-bin/common/kernel_aarch64/Image"
    
    # Clean up symlink
    rm -f "$TEMP_LINK"
fi

echo ""
echo "Build completed at: $(date)"

# Patch Image file for SukiSU (KPM support)
echo ""
echo "=== Checking KPM Image Patching ==="
if [ "$ENABLE_KPM" = true ]; then
    echo "KPM is enabled, applying Image patch..."
    if [ -f "build/build.sh" ]; then
        IMAGE_DIR="out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist"
    else
        IMAGE_DIR="bazel-bin/common/kernel_aarch64"
    fi

    cd "$IMAGE_DIR"
    if [ -f "Image" ]; then
        echo "Downloading KPM patcher..."
        curl -4 -LSs "https://raw.githubusercontent.com/ShirkNeko/SukiSU_patch/refs/heads/main/kpm/patch_linux" -o patch
        
        if [ -f "patch" ]; then
            chmod +x patch
            echo "Patching Image..."
            ./patch
            
            if [ -f "oImage" ]; then
                rm -f Image
                mv oImage Image
                echo "[OK] Image patched successfully for KPM support"
            else
                echo "[WARN] Patching may have failed, continuing with original Image"
            fi
            
            rm -f patch
        else
            echo "[WARN] Failed to download patcher, using original Image"
        fi
    else
        echo "[ERROR] Image not found at $IMAGE_DIR"
    fi

    cd "$SCRIPT_DIR/$WORK_DIR"
else
    echo "KPM is disabled, skipping Image patching"
fi

# Check if Image was created
if [ -f "$IMAGE_PATH" ]; then
    IMAGE_SIZE=$(du -h "$IMAGE_PATH" | cut -f1)
    echo ""
    echo "=== Build Successful ==="
    echo "Kernel Image: $IMAGE_PATH"
    echo "Image Size: $IMAGE_SIZE"
    echo "Kernel Version: ${KERNEL_VERSION}.${ACTUAL_SUBLEVEL}-${KERNEL_NAME}"
    echo ""
    
    # Copy Image to build directory with descriptive name
    BYPASS_SUFFIX=""
    if [ "$MODULE_BYPASS" = true ]; then
        BYPASS_SUFFIX="-Bypass"
    fi
    OUTPUT_NAME="Image-${KERNEL_VERSION}.${ACTUAL_SUBLEVEL}-${ANDROID_VERSION}-${OS_PATCH_LEVEL}${BYPASS_SUFFIX}"
    cp "$IMAGE_PATH" "../${OUTPUT_NAME}"
    echo "Image copied to: $(pwd)/../${OUTPUT_NAME}"
    
    # Prepare AnyKernel3 package
    echo ""
    echo "=== Preparing AnyKernel3 Package ==="
    
    # Clean previous files
    rm -f ../AnyKernel3/Image
    rm -rf ../AnyKernel3/modules
    
    # Copy kernel Image
    cp "$IMAGE_PATH" ../AnyKernel3/Image
    echo "[OK] Copied Image to AnyKernel3"
    
    # Enable modules in anykernel.sh
    sed -i 's|^do\.modules=.*|do.modules=1|' ../AnyKernel3/anykernel.sh
    
    # Copy snd-aloop module if it exists
    mkdir -p ../AnyKernel3/modules/vendor/lib/modules
    mkdir -p ../AnyKernel3/modules/data/adb/lkm
    
    if [ -f "build/build.sh" ]; then
        # Legacy build path
        MODULE_PATH="out/${ANDROID_VERSION}-${KERNEL_VERSION}/dist/snd-aloop.ko"
    else
        # Bazel build path
        MODULE_PATH="bazel-bin/common/kernel_aarch64/snd-aloop.ko"
    fi
    
    if [ -f "$MODULE_PATH" ]; then
        # Copy to both locations for compatibility
        cp "$MODULE_PATH" ../AnyKernel3/modules/vendor/lib/modules/
        cp "$MODULE_PATH" ../AnyKernel3/modules/data/adb/lkm/
        echo "[OK] Copied snd-aloop.ko module"
    else
        echo "[WARN] snd-aloop.ko not found (module might not have been built)"
    fi
    
    # Create AnyKernel3 zip
    cd ../AnyKernel3
    BYPASS_SUFFIX=""
    if [ "$MODULE_BYPASS" = true ]; then
        BYPASS_SUFFIX="-Bypass"
    fi
    ZIP_NAME="${KERNEL_VERSION}.${ACTUAL_SUBLEVEL}-${ANDROID_VERSION}-${OS_PATCH_LEVEL}${BYPASS_SUFFIX}-AnyKernel3.zip"
    
    echo "Creating flashable zip: $ZIP_NAME"
    zip -r9 "../$ZIP_NAME" . -x ".git/*" ".gitignore" "README.md" "LICENSE" "*.zip" 2>/dev/null
    cd "../$WORK_DIR"
    
    if [ -f "../$ZIP_NAME" ]; then
        ZIP_SIZE=$(du -h "../$ZIP_NAME" | cut -f1)
        echo "[OK] Created AnyKernel3 package: $ZIP_NAME ($ZIP_SIZE)"
    else
        echo "[ERROR] Failed to create AnyKernel3 package"
    fi
else
    echo ""
    echo "=== Build Failed ==="
    echo "Image file not found at expected location: $IMAGE_PATH"
    exit 1
fi

echo ""
echo "=== Build Complete ==="
