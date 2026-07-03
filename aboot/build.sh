#!/bin/bash

set -euo pipefail
set -x

BRANCH=21.0
APT_PACKAGES=(ca-certificates device-tree-compiler gcc-arm-none-eabi git make patch python3 python3-cryptography)
REQUIRED_COMMANDS=(arm-none-eabi-gcc arm-none-eabi-ld arm-none-eabi-objcopy dtc git make patch python3)

for command_name in "${REQUIRED_COMMANDS[@]}"; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "Missing command: $command_name" >&2
		echo "Install Debian packages: ${APT_PACKAGES[*]}" >&2
		exit 1
	fi
done

python3 - <<'PY'
import importlib.util
import sys

missing_modules = [
	module_name
	for module_name in ("cryptography",)
	if importlib.util.find_spec(module_name) is None
]

if missing_modules:
	print("Missing Python modules: " + ", ".join(missing_modules), file=sys.stderr)
	print("Install Debian packages: python3-cryptography", file=sys.stderr)
	sys.exit(1)
PY

git clone -b $BRANCH https://github.com/msm8916-mainline/lk2nd.git --depth=1
cd lk2nd
patch -p1 < ../ufi003.patch
make TOOLCHAIN_PREFIX=arm-none-eabi- LK2ND_BUNDLE_DTB="msm8916-512mb-mtp.dtb" LK2ND_COMPATIBLE="thwc,ufi003" lk1st-msm8916 -j$(nproc --all)
echo "lk1st-msm8916-$(lk2nd/scripts/describe-version.sh)" > ../ver.txt
cd ..
mv lk2nd/build-lk1st-msm8916/emmc_appsboot.mbn ./

git clone https://github.com/msm8916-mainline/qtestsign.git --depth=1
qtestsign/qtestsign.py aboot emmc_appsboot.mbn

rm -rf lk2nd qtestsign emmc_appsboot.mbn
