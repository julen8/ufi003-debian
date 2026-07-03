#!/bin/bash

set -euo pipefail
set -x

DIST="trixie"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-http://deb.debian.org/debian-security}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_RELEASE_REPO="${KERNEL_RELEASE_REPO:-julen8/linux}"
KERNEL_RELEASE_TAG="${KERNEL_RELEASE_TAG:-latest}"
KERNEL_RELEASE_DOWNLOAD_DIR="${KERNEL_RELEASE_DOWNLOAD_DIR:-$ROOT_DIR/kernel-release}"
KERNEL_RELEASE_INFO_FILE="$ROOT_DIR/kernel-release-info.md"
KERNEL_IMG_DIR="${KERNEL_IMG_DIR:-}" # optional local directory containing built kernel images and deb packages
KERNEL_STAGING_DIR="$(realpath "$ROOT_DIR/../kernel")"
DEB_PKGS_DIR="$(realpath "$ROOT_DIR/../deb-pkgs")"
DEBIAN_ROOTFS_DIR="$ROOT_DIR/debian"
BUILD_DIR="$ROOT_DIR/build"
CHROOT_SCRIPT="$ROOT_DIR/chroot.sh"
ROOTFS_IMAGE="$ROOT_DIR/debian-ufi003.img"
SPARSE_IMAGE="$ROOT_DIR/rootfs.img"
UUID="62ae670d-01b7-4c7d-8e72-60bcd00410b7"
APT_PACKAGES=(ca-certificates curl debootstrap e2fsprogs android-sdk-libsparse-utils jq qemu-user-static binfmt-support rsync)

usage() {
  cat <<'EOF'
Usage: ./build.sh [build|clean|help]

Commands:
  build   Build the Debian rootfs image and refresh staged kernel artifacts (default)
  clean   Remove all generated artifacts and temporary files
  help    Show this message

Environment overrides:
  KERNEL_RELEASE_REPO=<owner/repo>  Kernel release repository, default: julen8/linux
  KERNEL_RELEASE_TAG=<tag|latest>   Kernel release tag to use, default: latest
  KERNEL_IMG_DIR=<path>             Use local kernel artifacts instead of GitHub releases
  DEBIAN_MIRROR=<url>               Debian mirror, default: http://deb.debian.org/debian
  DEBIAN_SECURITY_MIRROR=<url>      Debian security mirror, default: http://deb.debian.org/debian-security
EOF
}

log() {
  printf '[rootfs/build.sh] %s\n' "$*"
}

die() {
  printf '[rootfs/build.sh] ERROR: %s\n' "$*" >&2
  exit 1
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

github_curl() {
  local curl_args=(-fsSL)
  local curl_status=0
  local errexit_enabled=0
  local xtrace_enabled=0

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(-H "Authorization: Bearer $GITHUB_TOKEN")
  fi

  case "$-" in
    *x*)
      xtrace_enabled=1
      set +x
      ;;
  esac

  case "$-" in
    *e*)
      errexit_enabled=1
      set +e
      ;;
  esac

  curl "${curl_args[@]}" "$@"
  curl_status=$?

  if [[ "$errexit_enabled" -eq 1 ]]; then
    set -e
  fi

  if [[ "$xtrace_enabled" -eq 1 ]]; then
    set -x
  fi

  return "$curl_status"
}

download_kernel_release_metadata() {
  local release_api_url=""

  if [[ -z "$KERNEL_RELEASE_TAG" || "$KERNEL_RELEASE_TAG" == "latest" ]]; then
    release_api_url="https://api.github.com/repos/$KERNEL_RELEASE_REPO/releases/latest"
  else
    release_api_url="https://api.github.com/repos/$KERNEL_RELEASE_REPO/releases/tags/$KERNEL_RELEASE_TAG"
  fi

  github_curl \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "$release_api_url"
}

download_kernel_release_artifacts() {
  local asset_count=0
  local asset_name=""
  local asset_url=""
  local release_json="$KERNEL_RELEASE_DOWNLOAD_DIR/release.json"

  log "Downloading kernel artifacts from $KERNEL_RELEASE_REPO release $KERNEL_RELEASE_TAG"
  rm -rf "$KERNEL_RELEASE_DOWNLOAD_DIR" > /dev/null 2>&1
  mkdir -p "$KERNEL_RELEASE_DOWNLOAD_DIR"

  download_kernel_release_metadata > "$release_json"

  while IFS=$'\t' read -r asset_name asset_url; do
    log "Downloading kernel release asset: $asset_name"
    github_curl -L -o "$KERNEL_RELEASE_DOWNLOAD_DIR/$asset_name" "$asset_url"

    case "$asset_name" in
      *.tar.gz|*.tgz)
        tar -xzf "$KERNEL_RELEASE_DOWNLOAD_DIR/$asset_name" -C "$KERNEL_RELEASE_DOWNLOAD_DIR"
        ;;
    esac

    asset_count=$((asset_count + 1))
  done < <(jq -r '.assets[] | select(.name | test("^(boot.*\\.img|linux-image-.*\\.deb)(\\.tar\\.gz|\\.tgz)?$")) | [.name, .browser_download_url] | @tsv' "$release_json")

  [[ "$asset_count" -gt 0 ]] || die "No matching kernel release assets found in $KERNEL_RELEASE_REPO release $KERNEL_RELEASE_TAG"
}

write_kernel_release_info() {
  local kernel_source_dir="$1"
  local latest_kernel_image="$2"
  local release_json="$KERNEL_RELEASE_DOWNLOAD_DIR/release.json"
  shift 2
  local boot_images=("$@")
  local boot_image=""

  if [[ -n "$KERNEL_IMG_DIR" ]]; then
    {
      printf '## Kernel\n\n'
      printf -- '- Source: local artifacts\n'
      printf -- '- Path: `%s`\n' "$kernel_source_dir"
      printf -- '- Linux package: `%s`\n' "$(basename "$latest_kernel_image")"
      printf -- '- Boot images:\n'
      for boot_image in "${boot_images[@]}"; do
        printf '  - `%s`\n' "$(basename "$boot_image")"
      done
    } > "$KERNEL_RELEASE_INFO_FILE"
    return
  fi

  {
    printf '## Kernel\n\n'
    printf -- '- Repository: https://github.com/%s\n' "$KERNEL_RELEASE_REPO"
    jq -r '
      "- Release: [" + (.tag_name // "unknown") + "](" + (.html_url // "") + ")",
      if (.name // "") != "" then "- Release name: " + .name else empty end
    ' "$release_json"
    printf -- '- Linux package: `%s`\n' "$(basename "$latest_kernel_image")"
    printf -- '- Boot images:\n'
    for boot_image in "${boot_images[@]}"; do
      printf '  - `%s`\n' "$(basename "$boot_image")"
    done
    printf -- '- Downloaded release assets:\n'
    jq -r '.assets[] | select(.name | test("^(boot.*\\.img|linux-image-.*\\.deb)(\\.tar\\.gz|\\.tgz)?$")) | "  - `" + .name + "`"' "$release_json"
  } > "$KERNEL_RELEASE_INFO_FILE"
}

prepare_kernel_staging() {
  local boot_images=()
  local kernel_source_dir=""
  local latest_kernel_image=""

  log "Refreshing kernel artifacts staging directory"
  mkdir -p "$KERNEL_STAGING_DIR"
  rm -rf "${KERNEL_STAGING_DIR:?}"/* > /dev/null 2>&1

  if [[ -n "$KERNEL_IMG_DIR" ]]; then
    kernel_source_dir="$(realpath "$KERNEL_IMG_DIR")"
    [[ -d "$kernel_source_dir" ]] || die "Local kernel artifacts directory not found: $kernel_source_dir"
  else
    download_kernel_release_artifacts
    kernel_source_dir="$KERNEL_RELEASE_DOWNLOAD_DIR"
  fi

  mapfile -t boot_images < <(find "$kernel_source_dir" -maxdepth 1 -type f -name 'boot*.img' | sort -V)
  [[ "${#boot_images[@]}" -gt 0 ]] || die "No boot*.img found in $kernel_source_dir"
  cp "${boot_images[@]}" "$KERNEL_STAGING_DIR/"

  latest_kernel_image="$(find "$kernel_source_dir" -maxdepth 1 -type f -name 'linux-image-*.deb' | sort -V | tail -n 1)"
  [[ -n "$latest_kernel_image" ]] || die "No linux-image-*.deb found in $kernel_source_dir"
  cp "$latest_kernel_image" "$KERNEL_STAGING_DIR/"
  write_kernel_release_info "$kernel_source_dir" "$latest_kernel_image" "${boot_images[@]}"
}

prepare_rootfs_layout() {
  log "Preparing rootfs workspace"
  rm -rf "$DEBIAN_ROOTFS_DIR" "$BUILD_DIR" > /dev/null 2>&1
  mkdir -p "$DEBIAN_ROOTFS_DIR" "$BUILD_DIR"
}

bootstrap_rootfs() {
  log "Bootstrapping Debian rootfs"
  debootstrap --arch=arm64 --foreign "$DIST" "$DEBIAN_ROOTFS_DIR" "$DEBIAN_MIRROR"
  env \
    DEBIAN_MIRROR="$DEBIAN_MIRROR" \
    DEBIAN_SECURITY_MIRROR="$DEBIAN_SECURITY_MIRROR" \
    LANG=C \
    LANGUAGE=C \
    LC_ALL=C \
    chroot "$DEBIAN_ROOTFS_DIR" /debootstrap/debootstrap --second-stage
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
  env \
    DEBIAN_MIRROR="$DEBIAN_MIRROR" \
    DEBIAN_SECURITY_MIRROR="$DEBIAN_SECURITY_MIRROR" \
    LANG=C \
    LANGUAGE=C \
    LC_ALL=C \
    chroot "$DEBIAN_ROOTFS_DIR" /tmp/chroot.sh
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
  rm -rf "$KERNEL_RELEASE_DOWNLOAD_DIR" > /dev/null 2>&1
  rm -f "$SPARSE_IMAGE" "$ROOT_DIR/debian_version" "$ROOT_DIR/info.md" "$KERNEL_RELEASE_INFO_FILE" > /dev/null 2>&1
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
