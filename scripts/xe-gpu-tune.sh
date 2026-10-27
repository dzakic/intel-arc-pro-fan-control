#!/bin/bash
# xe-gpu-tune — set power cap + GPU clock limits on an Intel Arc (xe) GPU.
# Uses only driver-exposed sysfs (safe; the driver clamps to valid ranges).
#
#   sudo xe-gpu-tune show
#   sudo xe-gpu-tune set  [--power-w N] [--clk-min MHZ] [--clk-max MHZ]
#   sudo xe-gpu-tune reset                 # back to hardware defaults
#   sudo xe-gpu-tune boot                  # apply /etc/xe-gpu-tune.conf (used by systemd)
#   sudo xe-gpu-tune --gpu BDF set ...     # multi-GPU: specify GPU by BDF
set -uo pipefail

# --- parse --gpu option (before subcommand) ---
GPU_BDF=""
SUBCOMMAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu)
      [ $# -lt 2 ] && { echo "error: --gpu requires BDF argument"; exit 1; }
      GPU_BDF="$2"
      shift 2
      ;;
    set|reset|boot|show)
      SUBCOMMAND="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# --- find the xe GPU's sysfs (honour ARC_GPU_BDF or --gpu for multi-GPU) ---
CARD=""
for c in /sys/class/drm/card*; do
  [ -e "$c/device/driver" ] || continue
  [ "$(basename "$(readlink -f "$c/device/driver")")" = "xe" ] || continue
  bdf=$(basename "$(readlink -f "$c/device")")
  # Check both --gpu argument and ARC_GPU_BDF env var
  if [ -n "${GPU_BDF:-}" ]; then
    [ "$bdf" = "$GPU_BDF" ] || continue
  elif [ -n "${ARC_GPU_BDF:-}" ]; then
    [ "$bdf" = "$ARC_GPU_BDF" ] || continue
  fi
  CARD="$c"; break
done
[ -n "$CARD" ] || { echo "error: no xe GPU found"; exit 1; }
GT="$CARD/device/tile0/gt0/freq0"
[ -d "$GT" ] || { echo "error: no freq controls at $GT"; exit 1; }
# matching hwmon (same BDF as CARD; fall back to the first xe hwmon if none matches)
CBDF=$(basename "$(readlink -f "$CARD/device")")
HW=""; HW_ANY=""
for d in /sys/class/hwmon/hwmon*; do
  [ -r "$d/name" ] && [ "$(cat "$d/name")" = "xe" ] || continue
  [ -z "$HW_ANY" ] && HW_ANY="$d"
  if [ "$(basename "$(readlink -f "$d/device" 2>/dev/null)" 2>/dev/null)" = "$CBDF" ]; then HW="$d"; break; fi
done
[ -n "$HW" ] || HW="$HW_ANY"

rd() { cat "$1" 2>/dev/null; }
show() {
  echo "gpu   : $CARD"
  echo "clocks: cur $(rd $GT/cur_freq) / min $(rd $GT/min_freq) / max $(rd $GT/max_freq) MHz"
  echo "        hw range: rpn(min) $(rd $GT/rpn_freq) .. rp0(max) $(rd $GT/rp0_freq) MHz; rpe(efficient) $(rd $GT/rpe_freq)"
  if [ -n "$HW" ] && [ -e "$HW/power1_cap" ]; then
    echo "power : cap $(( $(rd $HW/power1_cap)/1000000 )) W (crit $(( $(rd $HW/power1_crit 2>/dev/null || echo 0)/1000000 )) W)"
  fi
  [ -n "$HW" ] && echo "temp  : $(( $(rd $HW/temp2_input)/1000 )) C"
  [ -e "$GT/power_profile" ] && echo "profile: $(rd $GT/power_profile)   (writable: base | power_saving)"
}

set_power_w() { [ -n "$HW" ] && [ -e "$HW/power1_cap" ] && echo $(( $1 * 1000000 )) > "$HW/power1_cap" && echo "  power cap -> ${1} W"; }
set_clk_min() { echo "$1" > "$GT/min_freq" && echo "  min clock -> ${1} MHz"; }
set_clk_max() { echo "$1" > "$GT/max_freq" && echo "  max clock -> ${1} MHz"; }
set_profile() { [ -e "$GT/power_profile" ] && echo "$1" > "$GT/power_profile" && echo "  power profile -> ${1}"; }

persist_kv(){
  CONF=/etc/xe-gpu-tune.conf
  mkdir -p "$(dirname "$CONF")"; touch "$CONF"
  grep -vE "^$1=" "$CONF" 2>/dev/null > "$CONF.tmp" || true
  echo "$1=$2" >> "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
}

case "${SUBCOMMAND:-show}" in
  show) show ;;
  reset)
    echo "$(rd $GT/rp0_freq)" > "$GT/max_freq"
    echo "$(rd $GT/rpn_freq)" > "$GT/min_freq"   # note: hw default min; some firmwares idle-floor higher
    # power: restore the rated default if the card exposes one, else 0 = uncapped (the shipped default)
    [ -n "$HW" ] && [ -e "$HW/power1_cap" ] && { def=$(rd "$HW/power1_rated_max" 2>/dev/null); echo "${def:-0}" > "$HW/power1_cap"; }
    echo "reset to hardware defaults:"; show ;;
  set)
    while [ $# -gt 0 ]; do
      case "$1" in
        --power-w) set_power_w "$2"; persist_kv POWER_W "$2"; shift 2;;
        --clk-min) set_clk_min "$2"; persist_kv CLK_MIN "$2"; shift 2;;
        --clk-max) set_clk_max "$2"; persist_kv CLK_MAX "$2"; shift 2;;
        --profile) set_profile "$2"; persist_kv PROFILE "$2"; shift 2;;
        *) echo "unknown arg: $1"; exit 1;;
      esac
    done
    echo "applied:"; show ;;
  boot)
    CONF=/etc/xe-gpu-tune.conf
    [ -r "$CONF" ] || { echo "no $CONF; nothing to apply"; exit 0; }
    POWER_W=""; CLK_MIN=""; CLK_MAX=""; PROFILE=""
    # shellcheck disable=SC1090
    . "$CONF"
    [ -n "$POWER_W" ] && set_power_w "$POWER_W"
    [ -n "$CLK_MIN" ] && set_clk_min "$CLK_MIN"
    [ -n "$CLK_MAX" ] && set_clk_max "$CLK_MAX"
    [ -n "$PROFILE" ] && set_profile "$PROFILE"
    echo "boot tuning applied:"; show ;;
  *) echo "usage: xe-gpu-tune {show|set [--power-w N] [--clk-min MHZ] [--clk-max MHZ] [--profile base|power_saving]|reset|boot [--gpu BDF]}"; exit 1;;
esac
