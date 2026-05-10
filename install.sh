#!/bin/sh
set -eu

REPO_URL=${REPO_URL:-https://github.com/nxp-imx/mwifiex.git}
REF=${REF:-lf-6.18.2_1.0.0}
KERNEL_RELEASE=${KERNEL_RELEASE:-$(uname -r)}
KERNELDIR=${KERNELDIR:-/lib/modules/$KERNEL_RELEASE/build}

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BUILD_DIR:-$script_dir/build}
DRIVER_DIR=${DRIVER_DIR:-$BUILD_DIR/mwifiex}
PATCH_FILE=${PATCH_FILE:-$script_dir/ps5-iw620.patch}
INSTALL_MOD_DIR=${INSTALL_MOD_DIR:-extra/ps5-iw620}
MODULE_DIR=${MODULE_DIR:-/lib/modules/$KERNEL_RELEASE/$INSTALL_MOD_DIR}
MODPROBE_CONF=${MODPROBE_CONF:-/etc/modprobe.d/ps5-iw620.conf}

FW_NAME=${FW_NAME:-nxp/pcieuartiw620_combo_v1.bin}
FIRMWARE_SRC=${FIRMWARE_SRC:-}
FIRMWARE_DIR=${FIRMWARE_DIR:-/lib/firmware}

ARCH=${ARCH:-}
JOBS=${JOBS:-}

MOAL_OPTIONS=${MOAL_OPTIONS:-fw_name=$FW_NAME pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 auto_fw_reload=0 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1}

usage() {
	cat <<EOF
Usage: $0 [install|build|uninstall|clean]

Commands:
  install    Build and install the driver modules (default)
  build      Build the driver without installing it
  uninstall  Remove installed modules and modprobe config
  clean      Remove the local build directory

Environment:
  KERNEL_RELEASE   Kernel release to build for (default: $(uname -r))
  KERNELDIR         Kernel build directory (default: $KERNELDIR)
  DRIVER_DIR        Driver source checkout (default: $DRIVER_DIR)
  MODULE_DIR        Module install path (default: $MODULE_DIR)
  MODPROBE_CONF     Modprobe config path (default: $MODPROBE_CONF)
  FW_NAME           Firmware name passed to moal (default: $FW_NAME)
  FIRMWARE_SRC      Optional local firmware file to copy into /lib/firmware
  FIRMWARE_DIR      Firmware install root (default: $FIRMWARE_DIR)
  ARCH              Kernel build ARCH override
  JOBS              Parallel make jobs
EOF
}

say() {
	printf '%s\n' "$*"
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

need_root() {
	[ "$(id -u)" -eq 0 ] || die "run install/uninstall as root"
}

build_arch() {
	if [ -n "$ARCH" ]; then
		printf '%s\n' "$ARCH"
		return
	fi

	case "$(uname -m)" in
		x86_64|i386|i486|i586|i686) printf 'x86\n' ;;
		aarch64|arm64) printf 'arm64\n' ;;
		arm*) printf 'arm\n' ;;
		riscv64) printf 'riscv\n' ;;
		ppc64*) printf 'powerpc\n' ;;
		*) uname -m ;;
	esac
}

make_jobs() {
	if [ -n "$JOBS" ]; then
		printf '%s\n' "$JOBS"
	elif command -v nproc >/dev/null 2>&1; then
		nproc
	else
		getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n'
	fi
}

prepare_source() {
	need_cmd git
	need_cmd make
	[ -f "$PATCH_FILE" ] || die "patch file not found: $PATCH_FILE"
	[ -d "$KERNELDIR" ] || die "kernel build directory not found: $KERNELDIR"

	mkdir -p "$BUILD_DIR"

	if [ ! -d "$DRIVER_DIR/.git" ]; then
		[ ! -e "$DRIVER_DIR" ] || die "DRIVER_DIR exists but is not a git checkout: $DRIVER_DIR"
		say "Cloning driver source into $DRIVER_DIR"
		git clone "$REPO_URL" "$DRIVER_DIR"
	else
		say "Using existing driver source at $DRIVER_DIR"
	fi

	say "Fetching driver refs"
	git -C "$DRIVER_DIR" fetch --tags origin

	say "Checking out $REF"
	git -C "$DRIVER_DIR" checkout "$REF"

	if git -C "$DRIVER_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
		say "Applying PS5 IW620 patch"
		git -C "$DRIVER_DIR" apply "$PATCH_FILE"
	elif git -C "$DRIVER_DIR" apply -R --check "$PATCH_FILE" >/dev/null 2>&1; then
		say "PS5 IW620 patch is already applied"
	else
		die "patch does not apply cleanly in $DRIVER_DIR"
	fi
}

build_driver() {
	prepare_source
	arch=$(build_arch)
	jobs=$(make_jobs)

	say "Building modules for $KERNEL_RELEASE (ARCH=$arch)"
	make -C "$DRIVER_DIR" CONFIG_OBJTOOL= KERNELDIR="$KERNELDIR" ARCH="$arch" -j "$jobs"

	[ -f "$DRIVER_DIR/mlan.ko" ] || die "missing built module: $DRIVER_DIR/mlan.ko"
	[ -f "$DRIVER_DIR/moal.ko" ] || die "missing built module: $DRIVER_DIR/moal.ko"
}

install_firmware() {
	target=$FIRMWARE_DIR/$FW_NAME

	if [ -n "$FIRMWARE_SRC" ]; then
		[ -f "$FIRMWARE_SRC" ] || die "firmware file not found: $FIRMWARE_SRC"
		say "Installing firmware to $target"
		install -d "$(dirname "$target")"
		install -m 0644 "$FIRMWARE_SRC" "$target"
	elif [ ! -f "$target" ]; then
		say "WARNING: firmware not found at $target"
		say "         If needed, rerun with FIRMWARE_SRC=/path/to/$(basename "$FW_NAME")"
	fi
}

write_modprobe_config() {
	say "Writing modprobe config to $MODPROBE_CONF"
	install -d "$(dirname "$MODPROBE_CONF")"
	cat >"$MODPROBE_CONF" <<EOF
# PS5 IW620 mwifiex
softdep moal pre: cfg80211 mlan
options moal $MOAL_OPTIONS
EOF
}

install_driver() {
	need_root
	need_cmd install
	need_cmd depmod
	build_driver

	say "Installing modules to $MODULE_DIR"
	install -d "$MODULE_DIR"
	install -m 0644 "$DRIVER_DIR/mlan.ko" "$MODULE_DIR/mlan.ko"
	install -m 0644 "$DRIVER_DIR/moal.ko" "$MODULE_DIR/moal.ko"

	write_modprobe_config
	install_firmware

	say "Running depmod for $KERNEL_RELEASE"
	depmod "$KERNEL_RELEASE"

	say "Done. Load with: modprobe moal"
}

uninstall_driver() {
	need_root
	need_cmd depmod

	say "Removing modules from $MODULE_DIR"
	rm -f "$MODULE_DIR/mlan.ko" "$MODULE_DIR/moal.ko"
	rmdir "$MODULE_DIR" 2>/dev/null || true

	say "Removing $MODPROBE_CONF"
	rm -f "$MODPROBE_CONF"

	say "Running depmod for $KERNEL_RELEASE"
	depmod "$KERNEL_RELEASE"
}

clean_build() {
	case "$BUILD_DIR" in
		"$script_dir"/build)
			say "Removing $BUILD_DIR"
			rm -rf "$BUILD_DIR"
			;;
		*)
			die "refusing to remove custom BUILD_DIR: $BUILD_DIR"
			;;
	esac
}

cmd=${1:-install}

case "$cmd" in
	install) install_driver ;;
	build) build_driver ;;
	uninstall) uninstall_driver ;;
	clean) clean_build ;;
	-h|--help|help) usage ;;
	*) usage >&2; exit 2 ;;
esac
