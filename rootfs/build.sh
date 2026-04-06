#!/bin/bash

set -euo pipefail
set -x

DIST="trixie"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_IMG_DIR="$(realpath "$ROOT_DIR/../../ufi003-kernel/artifacts")" # path to the directory containing built kernel images and deb packages
KERNEL_STAGING_DIR="$(realpath "$ROOT_DIR/../kernel")"
DEB_PKGS_DIR="$(realpath "$ROOT_DIR/../deb-pkgs")"
DEBIAN_ROOTFS_DIR="$ROOT_DIR/debian"
BUILD_DIR="$ROOT_DIR/build"
CHROOT_SCRIPT="$ROOT_DIR/chroot.sh"
ROOTFS_IMAGE="$ROOT_DIR/debian-ufi003.img"
SPARSE_IMAGE="$ROOT_DIR/rootfs.img"
UUID="62ae670d-01b7-4c7d-8e72-60bcd00410b7"
APT_PACKAGES=(debootstrap e2fsprogs android-sdk-libsparse-utils rsync)

usage() {
  cat <<'EOF'
Usage: ./build.sh [build|clean|help]

Commands:
  build   Build the Debian rootfs image and refresh staged kernel artifacts (default)
  clean   Remove all generated artifacts and temporary files
  help    Show this message
EOF
}

log() {
  printf '[rootfs/build.sh] %s\n' "$*"
}

cleanup_mounts() {
  local mount_path=""

  for mount_path in \
    "$BUILD_DIR" \
    "$DEBIAN_ROOTFS_DIR/proc" \
    "$DEBIAN_ROOTFS_DIR/dev/pts" \
    "$DEBIAN_ROOTFS_DIR/dev" \
    "$DEBIAN_ROOTFS_DIR/sys"; do
    if mountpoint -q "$mount_path"; then
      umount "$mount_path"
    fi
  done
}

ensure_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "Please run as root"
    exit 1
  fi
}

install_dependencies() {
  local missing_packages=()
  local package_name=""

  for package_name in "${APT_PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package_name" 2>/dev/null | grep -q 'install ok installed'; then
      missing_packages+=("$package_name")
    fi
  done

  if [[ ${#missing_packages[@]} -eq 0 ]]; then
    log "Host dependencies are already installed"
    return
  fi

  log "Installing host dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${missing_packages[@]}"
}

prepare_kernel_staging() {
  local latest_kernel_image=""

  log "Refreshing kernel artifacts staging directory"
  rm -rf "${KERNEL_STAGING_DIR:?}"/* > /dev/null 2>&1

  find "$KERNEL_IMG_DIR" -maxdepth 1 -type f -name 'boot*.img' -exec cp -t "$KERNEL_STAGING_DIR" {} +

  latest_kernel_image="$(find "$KERNEL_IMG_DIR" -maxdepth 1 -type f -name 'linux-image-*.deb' | sort -V | tail -n 1)"
  [[ -n "$latest_kernel_image" ]] || {
    echo "No linux-image-*.deb found in $KERNEL_IMG_DIR" >&2
    exit 1
  }
  cp "$latest_kernel_image" "$KERNEL_STAGING_DIR/"
}

prepare_rootfs_layout() {
  log "Preparing rootfs workspace"
  rm -rf "$DEBIAN_ROOTFS_DIR" "$BUILD_DIR" > /dev/null 2>&1
  mkdir -p "$DEBIAN_ROOTFS_DIR" "$BUILD_DIR"
}

bootstrap_rootfs() {
  log "Bootstrapping Debian rootfs"
  debootstrap --arch=arm64 --foreign "$DIST" "$DEBIAN_ROOTFS_DIR" https://mirrors.ustc.edu.cn/debian
  LANG=C LANGUAGE=C LC_ALL=C chroot "$DEBIAN_ROOTFS_DIR" /debootstrap/debootstrap --second-stage
}

stage_packages() {
  log "Staging packages into rootfs"
  cp "$DEB_PKGS_DIR"/*.deb "$CHROOT_SCRIPT" "$DEBIAN_ROOTFS_DIR/tmp/"
  mv "$KERNEL_STAGING_DIR"/linux-image-*.deb "$DEBIAN_ROOTFS_DIR/tmp/"
}

mount_chroot_filesystems() {
  log "Mounting chroot filesystems"
  mount --bind /proc "$DEBIAN_ROOTFS_DIR/proc"
  mount --bind /dev "$DEBIAN_ROOTFS_DIR/dev"
  mount --bind /dev/pts "$DEBIAN_ROOTFS_DIR/dev/pts"
  mount --bind /sys "$DEBIAN_ROOTFS_DIR/sys"
}

run_chroot_setup() {
  log "Running chroot setup"
  LANG=C LANGUAGE=C LC_ALL=C chroot "$DEBIAN_ROOTFS_DIR" /tmp/chroot.sh
}

finalize_rootfs_metadata() {
  log "Collecting rootfs metadata"
  cp "$DEBIAN_ROOTFS_DIR/etc/debian_version" "$ROOT_DIR/"
  mv "$DEBIAN_ROOTFS_DIR/tmp/info.md" "$ROOT_DIR/"
  echo >> "$ROOT_DIR/info.md"
  rm -rf "$DEBIAN_ROOTFS_DIR/tmp"/* "$DEBIAN_ROOTFS_DIR/root/.bash_history" > /dev/null 2>&1
}

build_images() {
  log "Building ext4 and sparse images"
  dd if=/dev/zero of="$ROOTFS_IMAGE" bs=1M count=$(( $(du -ms "$DEBIAN_ROOTFS_DIR" | cut -f1) + 100 ))
  mkfs.ext4 -L rootfs -U "$UUID" "$ROOTFS_IMAGE"
  mount "$ROOTFS_IMAGE" "$BUILD_DIR"
  rsync -aH "$DEBIAN_ROOTFS_DIR/" "$BUILD_DIR/"
  umount "$BUILD_DIR"
  img2simg "$ROOTFS_IMAGE" "$SPARSE_IMAGE"
  log "Image build completed: $SPARSE_IMAGE"
}

cleanup_workspace() {
  log "Cleaning temporary workspace"
  rm -rf "$ROOTFS_IMAGE" "$DEBIAN_ROOTFS_DIR" "$BUILD_DIR" > /dev/null 2>&1
}

clean_generated_files() {
  log "Removing generated rootfs artifacts"
  cleanup_mounts
  rm -rf "$ROOTFS_IMAGE" "$DEBIAN_ROOTFS_DIR" "$BUILD_DIR" > /dev/null 2>&1
  rm -f "$SPARSE_IMAGE" "$ROOT_DIR/debian_version" "$ROOT_DIR/info.md" > /dev/null 2>&1
  rm -rf "${KERNEL_STAGING_DIR:?}"/* > /dev/null 2>&1
}

build_rootfs() {
  trap cleanup_mounts EXIT
  install_dependencies
  prepare_kernel_staging
  prepare_rootfs_layout
  bootstrap_rootfs
  stage_packages
  mount_chroot_filesystems
  run_chroot_setup
  cleanup_mounts
  finalize_rootfs_metadata
  build_images
  cleanup_workspace
}

main() {
  local mode="${1:-build}"

  case "$mode" in
    build)
      ensure_root
      build_rootfs
      ;;
    clean)
      ensure_root
      clean_generated_files
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
