#!/bin/bash
# Installed by install.sh as /usr/lib/systemd/system-sleep/xe-fan-resume
# (systemd-sleep only scans the vendor dir — /etc/systemd/system-sleep is
#  NOT scanned by upstream systemd, so do not install this hook there).
# Sleep hook script to re-apply fan curve after resume from suspend
#
# Runs before sleep (pre) to set a marker, and after resume (post)
# to re-apply the saved fan curve. The marker file approach ensures we
# only apply the curve after an actual sleep cycle, not on every boot.

LOG="/var/log/xe-fan-resume.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

wait_for_hwmon() {
    # Wait up to ~60s for the xe hwmon device to appear after resume
    local w=0
    while [ $w -lt 60 ]; do
        if ls /sys/class/hwmon/hwmon*/name 2>/dev/null | xargs -r grep -lq xe 2>/dev/null; then
            return 0
        fi
        sleep 1
        w=$((w+1))
    done
    return 1
}

case "$1" in
    pre)
        # Before sleep: set marker so we know we went to sleep
        log "xe-fan-resume: going to sleep, setting wake trigger"
        echo "1" > /run/xe-fan-sleep-trigger
        ;;
    post)
        # After resume: only apply if we were actually suspended
        if [ -f /run/xe-fan-sleep-trigger ]; then
            rm -f /run/xe-fan-sleep-trigger
            log "xe-fan-resume: resuming from sleep, re-applying fan curve..."

            # Wait for the xe hwmon device to be ready
            if wait_for_hwmon; then
                /usr/local/bin/xe-fan-curve boot >> "$LOG" 2>&1
                log "xe-fan-resume: fan curve re-applied (exit $?)"
            else
                log "xe-fan-resume: ERROR - xe hwmon device not found after resume, curve not reapplied"
            fi
        fi
        ;;
esac
