#!/usr/bin/env bash
set -euo pipefail

# Download kernel source for android14-6.1-2025-01 (6.1.118)
# This will download to current directory

ANDROID_VERSION="android14"
KERNEL_VERSION="6.1"
OS_PATCH_LEVEL="2025-01"

echo "=== Downloading Android 14 Kernel 6.1 (2025-01 patch) ==="
echo "This will download to: $(pwd)"
echo ""

# Check if repo is available
if ! command -v repo >/dev/null 2>&1; then
  echo "Installing repo tool locally..."
  mkdir -p ./git-repo
  curl -s https://storage.googleapis.com/git-repo-downloads/repo > ./git-repo/repo
  chmod a+rx ./git-repo/repo
  REPO="$(pwd)/git-repo/repo"
else
  REPO=$(command -v repo)
fi

# CPU count for parallel sync
CPU_COUNT=$(nproc 2>/dev/null || echo 4)

# Create work directory
FORMATTED_BRANCH="${ANDROID_VERSION}-${KERNEL_VERSION}-${OS_PATCH_LEVEL}"
WORK_DIR="android14-6.1-118"

echo "Creating directory: $WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Initialize repo
echo "Initializing repo manifest..."
"$REPO" init --depth=1 \
  --u https://android.googlesource.com/kernel/manifest \
  -b "common-${FORMATTED_BRANCH}" \
  --repo-rev=v2.16

# Check for deprecated branch
echo "Checking if branch is deprecated..."
REMOTE_BRANCH=$(git ls-remote https://android.googlesource.com/kernel/common "${FORMATTED_BRANCH}" 2>/dev/null || true)
if echo "$REMOTE_BRANCH" | grep -q deprecated; then
  echo "Branch is deprecated, updating manifest..."
  sed -i "s/\"${FORMATTED_BRANCH}\"/\"deprecated\/${FORMATTED_BRANCH}\"/g" .repo/manifests/default.xml
fi

# Sync repositories
echo "Syncing repositories (this may take 30-60 minutes)..."
echo "Using $CPU_COUNT parallel jobs"
"$REPO" sync -c -j"${CPU_COUNT}" --no-tags --fail-fast

# Extract actual sublevel
SUBLEVEL="118"
if [ -f "common/Makefile" ]; then
  ACTUAL_SUBLEVEL=$(grep '^SUBLEVEL = ' common/Makefile | awk '{print $3}' || echo "118")
  if [ -n "$ACTUAL_SUBLEVEL" ]; then
    SUBLEVEL="$ACTUAL_SUBLEVEL"
  fi
fi

echo ""
echo "=== Download Complete ==="
echo "Kernel version: ${KERNEL_VERSION}.${SUBLEVEL}"
echo "Original source location: $(pwd)"
echo "Size: $(du -sh . | cut -f1)"
echo ""
echo "Creating working copy for modifications..."
cd ..

# Create working directory name
WORK_DIR="android14-6.1-118-work"

# Copy source to working directory
echo "Copying source code to ${WORK_DIR}..."
cp -r android14-6.1-118 "${WORK_DIR}"
