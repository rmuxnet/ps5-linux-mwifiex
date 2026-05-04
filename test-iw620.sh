#!/bin/sh
set -eu

DEV=${DEV:-0000:40:00.7}
FW=${FW:-nxp/pcieuartiw620_combo_v1.bin}
EXT_SCAN=${EXT_SCAN:-1}
DRVDBG=${DRVDBG:-0x7}
DRIVER_DIR=${DRIVER_DIR:-}
MODE=${1:-capture}
LOG_ROOT_INPUT=${LOG_ROOT:-}
DURATION=${DURATION:-600}
INTERVAL=${INTERVAL:-5}
CLEAR_DMESG=${CLEAR_DMESG:-1}
GUIDED=${GUIDED:-1}
RUN_LOAD=${RUN_LOAD:-1}

need_root() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "Run this as root: sudo $0" >&2
		exit 1
	fi
}

find_driver_dir() {
	if [ -n "$DRIVER_DIR" ]; then
		return 0
	fi

	if [ -f ./mlan.ko ] && [ -f ./moal.ko ]; then
		DRIVER_DIR=$PWD
		return 0
	fi

	script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$script_dir/mlan.ko" ] && [ -f "$script_dir/moal.ko" ]; then
		DRIVER_DIR=$script_dir
		return 0
	fi

	echo "ERROR: unable to find mlan.ko/moal.ko" >&2
	echo "Run from the built driver checkout or set DRIVER_DIR to it" >&2
	exit 1
}

module_loaded() {
	lsmod | awk -v mod="$1" 'NR > 1 && $1 == mod { found = 1 } END { exit !found }'
}

find_iface() {
	for netdev in /sys/bus/pci/devices/"$DEV"/net/*; do
		[ -e "$netdev" ] || continue
		basename "$netdev"
		return 0
	done
	return 1
}

say() {
	printf '%s\n' "$*" | tee -a "$TRANSCRIPT"
}

mark() {
	msg=$1
	printf '<6>iw620-test: %s\n' "$msg" >/dev/kmsg 2>/dev/null || true
	say "== marker: $msg =="
}

run_log() {
	name=$1
	shift
	{
		printf '### %s\n' "$name"
		printf '### command:'
		for arg in "$@"; do
			printf ' %s' "$arg"
		done
		printf '\n'
		"$@"
		printf '\n'
	} >>"$LOG_DIR/$name.log" 2>&1 || true
}

unload_modules() {
	for netdev in /sys/bus/pci/devices/"$DEV"/net/*; do
		[ -e "$netdev" ] || continue
		netdev=$(basename "$netdev")
		echo "bringing down $netdev"
		ip link set "$netdev" down || true
	done

	for module in moal mlan; do
		if module_loaded "$module"; then
			echo "rmmod $module"
			if ! rmmod "$module"; then
				echo "ERROR: failed to unload $module" >&2
				lsmod | awk 'NR == 1 || $1 == "moal" || $1 == "mlan"'
				if [ -d "/sys/module/$module/holders" ]; then
					echo "holders for $module:"
					ls -1 "/sys/module/$module/holders"
				fi
				return 1
			fi
		fi
	done
}

load_driver() {
	modprobe cfg80211
	for module in mlan moal; do
		if module_loaded "$module"; then
			echo "ERROR: $module is still loaded; refusing to insert over it" >&2
			lsmod | awk 'NR == 1 || $1 == "moal" || $1 == "mlan"'
			return 1
		fi
	done

	insmod "$DRIVER_DIR/mlan.ko"
	insmod "$DRIVER_DIR/moal.ko" \
		fw_name="$FW" \
		pcie_int_mode=1 \
		drv_mode=1 \
		cfg80211_wext=4 \
		sta_name=mlan \
		ext_scan="$EXT_SCAN" \
		auto_fw_reload=0 \
		wifi_reset_config=0 \
		sched_scan=0 \
		ps_mode=2 \
		auto_ds=2 \
		amsdu_disable=1 \
		drvdbg="$DRVDBG"
}

dump_pci_state() {
	{
		date --iso-8601=seconds
		lspci -nnk -s "$DEV" || true
		lspci -vvnn -s "$DEV" || true
		for attr in enable irq current_link_speed current_link_width \
			power_state resource; do
			if [ -e "/sys/bus/pci/devices/$DEV/$attr" ]; then
				printf '%s=' "$attr"
				cat "/sys/bus/pci/devices/$DEV/$attr"
			fi
		done
		printf '\n'
	} >>"$LOG_DIR/pci-state.log" 2>&1
}

dump_module_params() {
	{
		date --iso-8601=seconds
		if [ -d /sys/module/moal/parameters ]; then
			for param in /sys/module/moal/parameters/*; do
				[ -e "$param" ] || continue
				printf '%s=' "$(basename "$param")"
				cat "$param"
			done
		else
			echo "moal parameters not present"
		fi
		printf '\n'
	} >>"$LOG_DIR/module-params.log" 2>&1
}

sample_state() {
	while :; do
		{
			echo "### $(date --iso-8601=seconds)"
			iface=$(find_iface || true)
			if [ -n "${iface:-}" ]; then
				echo "iface=$iface"
				ip -d link show "$iface" || true
				iw dev "$iface" link || true
				if [ -e "/sys/class/net/$iface/operstate" ]; then
					printf 'operstate='
					cat "/sys/class/net/$iface/operstate"
				fi
				if [ -e "/sys/class/net/$iface/carrier" ]; then
					printf 'carrier='
					cat "/sys/class/net/$iface/carrier"
				fi
			else
				echo "iface=<none>"
			fi
			echo
		} >>"$LOG_DIR/state-samples.log" 2>&1
		sleep "$INTERVAL"
	done
}

stop_background() {
	if [ -n "${STATE_PID:-}" ]; then
		kill "$STATE_PID" 2>/dev/null || true
	fi
	if [ -n "${DMESG_PID:-}" ]; then
		kill "$DMESG_PID" 2>/dev/null || true
	fi
	dmesg >"$LOG_DIR/dmesg-final.log" 2>&1 || true
	dump_pci_state || true
	dump_module_params || true
}

wait_step() {
	step=$1
	mark "before $step"
	say ""
	say "Do this now: $step"
	say "Press Enter here after that step is done."
	read dummy || true
	mark "after $step"
	dump_pci_state || true
	dump_module_params || true
}

prepare_logs() {
	stamp=$(date +%Y%m%d-%H%M%S)
	if [ -z "$LOG_ROOT_INPUT" ]; then
		LOG_ROOT="$DRIVER_DIR/iw620-test-logs"
	else
		LOG_ROOT="$LOG_ROOT_INPUT"
	fi
	LOG_DIR="$LOG_ROOT/$stamp"
	mkdir -p "$LOG_DIR"
	TRANSCRIPT="$LOG_DIR/transcript.log"
	touch "$TRANSCRIPT"
}

capture_run() {
	prepare_logs
	trap stop_background EXIT INT TERM

	say "== iw620 test directory: $LOG_DIR =="
	say "== params: DEV=$DEV DRIVER_DIR=$DRIVER_DIR FW=$FW EXT_SCAN=$EXT_SCAN RUN_LOAD=$RUN_LOAD =="

	run_log uname uname -a
	run_log cmdline cat /proc/cmdline
	run_log moal-modinfo modinfo "$DRIVER_DIR/moal.ko"
	run_log mlan-modinfo modinfo "$DRIVER_DIR/mlan.ko"
	dump_pci_state

	if [ "$CLEAR_DMESG" = "1" ]; then
		dmesg -C || true
	fi
	dmesg -wT >"$LOG_DIR/dmesg-live.log" 2>&1 &
	DMESG_PID=$!

	mark "capture start"

	if [ "$RUN_LOAD" = "1" ]; then
		say "== loading driver =="
		if ! { unload_modules && load_driver; } >"$LOG_DIR/load.log" 2>&1; then
			say "ERROR: driver load failed; see $LOG_DIR/load.log"
			exit 1
		fi
		dump_pci_state || true
		dump_module_params || true
	fi

	sample_state &
	STATE_PID=$!

	if [ "$GUIDED" = "1" ]; then
		wait_step "connect to your AP"
		wait_step "run a Wi-Fi scan while connected"
		wait_step "turn Wi-Fi off"
		wait_step "turn Wi-Fi on and reconnect"
		wait_step "run another Wi-Fi scan"
	else
		say "== unguided capture for ${DURATION}s =="
		sleep "$DURATION"
	fi

	mark "capture finish"
	say "== logs saved in: $LOG_DIR =="
}

need_root
find_driver_dir

case "$MODE" in
	load)
		unload_modules
		load_driver
		;;
	unload)
		unload_modules
		;;
	reload)
		unload_modules
		load_driver
		;;
	capture)
		capture_run
		;;
	*)
		echo "Usage: sudo DRIVER_DIR=\$PWD $0 [capture|load|reload|unload]" >&2
		exit 2
		;;
esac
