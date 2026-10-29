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
      GPU_BFD="$2"
      GPU_BDF="$2"
      shift 2
      ;;
    set|reset|boot|show)
      SUBCOMMAND="$1"
      shift
      # Stop parsing after subcommand so arguments can be processed by subcommand handler
      break
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
  [ "$(basename "$(readlink -f "$c/device/driver")" 2>/dev/null)" = "xe" ] || continue
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
  hwm_bdf=$(basename "$(readlink -f "$d/device" 2>/dev/null)" 2>/dev/null)
  if [ "$hwm_bdf" = "$CBDF" ]; then HW="$d"; break; fi
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
  local key="$1" val="$2"
  # Per-GPU config: /etc/xe-gpu-tune-cardX.conf (X is card number extracted from CARD path)
  local CONF="/etc/xe-gpu-tune-${CARD##*/}.conf"
  mkdir -p "$(dirname "$CONF")"; touch "$CONF"
  grep -vE "^$key=" "$CONF" 2>/dev/null > "$CONF.tmp" || true
  echo "$key=$val" >> "$CONF.tmp"; mv "$CONF.tmp" "$CONF"
}

case "${SUBCOMMAND:-show}" in
  show) show ;;
  reset)
    echo "$(rd $GT/rp0_freq)" > "$GT/max_freq"
    echo "$(rd $GT/rpn_freq)" > "$GT/min_freq"   # note: hw default min; some firmwares idle-floor higher
    # power: restore the rated default if the card exposes one, else 0 = uncapped (the shipped default)
    [ -n "$HW" ] && [ -e "$HW/power1_cap" ] && { def=$(rd "$HW/power1_rated_max" 2>/dev/null); echo "${def:-0}" > "$HW/power1_cap"; }
    # Clean up per-GPU config file for this GPU
    rm -f "/etc/xe-gpu-tune-${CARD##*/}.conf"
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
    # Per-GPU config: /etc/xe-gpu-tune-cardX.conf where X is the card number
    POWER_W=""; CLK_MIN=""; CLK_MAX=""; PROFILE=""
    if [ -n "${GPU_BDF:-}" ] || [ -n "${ARC_GPU_BDF:-}" ]; then
      # Single-GPU mode (--gpu or ARC_GPU_BDF): use the CARD already detected above
      CONF="/etc/xe-gpu-tune-${CARD##*/}.conf"
      [ -r "$CONF" ] || { echo "no $CONF; nothing to apply"; exit 0; }
      # shellcheck disable=SC1090
      . "$CONF"
      [ -n "$POWER_W" ] && set_power_w "$POWER_W"
      [ -n "$CLK_MIN" ] && set_clk_min "$CLK_MIN"
      [ -n "$CLK_MAX" ] && set_clk_max "$CLK_MAX"
      [ -n "$PROFILE" ] && set_profile "$PROFILE"
      echo "boot tuning applied:"; show
    else
      # Multi-GPU mode (no --gpu): loop over all xe GPUs and apply each config
      for c in /sys/class/drm/card*; do
        [ -e "$c/device/driver" ] || continue
        driver=$(readlink -f "$c/device/driver" 2>/dev/null)
        [ "$(basename "$driver" 2>/dev/null)" = "xe" ] || continue
        _gt="$c/device/tile0/gt0/freq0"
        [ -d "$_gt" ] || continue
        _cn=$(basename "$c")
        _conf="/etc/xe-gpu-tune-${_cn}.conf"
        [ -r "$_conf" ] || continue
        _pw=""; _cmn=""; _cmx=""; _prf=""
        # shellcheck disable=SC1090
        . "$_conf"
        # Config file uses CLK_MIN/CLK_MAX/POWER_W/PROFILE; map to our loop vars
        _pw="${POWER_W:-}"; _cmn="${CLK_MIN:-}"; _cmx="${CLK_MAX:-}"; _prf="${PROFILE:-}"
        # set clocks via the per-GPU sysfs node
        [ -n "$_cmn" ] && echo "$_cmn" > "$_gt/min_freq" 2>/dev/null
        [ -n "$_cmx" ] && echo "$_cmx" > "$_gt/max_freq" 2>/dev/null
        # match hwmon by BDF (same logic as the CARD detection above)
        _bdf=$(basename "$(readlink -f "$c/device")")
        _hw=""
        for _d in /sys/class/hwmon/hwmon*; do
          [ -r "$_d/name" ] && [ "$(cat "$_d/name" 2>/dev/null)" = "xe" ] || continue
          _hwm_bdf=$(basename "$(readlink -f "$_d/device" 2>/dev/null)" 2>/dev/null)
          [ "$_hwm_bdf" = "$_bdf" ] && _hw="$_d" && break
        done
        [ -n "$_pw" ] && [ -n "$_hw" ] && echo "$_pw" > "$_hw/power1_cap" 2>/dev/null
        [ -n "$_prf" ] && { echo "$_prf" > "$c/device/power_dlb_config" 2>/dev/null || echo "$_prf" > "$c/device/power_context" 2>/dev/null || true; }
      done
      echo "boot tuning applied to all GPUs:"; show
    fi
    ;;
  *) echo "usage: xe-gpu-tune {show|set [--power-w N] [--clk-min MHZ] [--clk-max MHZ] [--profile base|power_saving]|reset|boot [--gpu BDF]}"; exit 1;;
esac
