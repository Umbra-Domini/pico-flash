#!/bin/bash

# =============================================================================
#   Author : UmbraDomini
#   Tool   : Pico 2 W Automated Flash Script
#   Usage  : ./pico_flash.sh
#   Note   : Hold BOOTSEL button while plugging in before running.
# =============================================================================

# ── CONFIG ────────────────────────────────────────────────────────────────────
PICO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_FLASH_NUKE="$PICO_DIR/flash_nuke.uf2"
SOURCE_NEEDED_FILES="$PICO_DIR/needed_files"
# SOURCE_PAYLOAD is selected interactively at runtime

WAIT_TIMEOUT=60

# All known Pico BOOTSEL-mode mount labels (mass storage, pre-flash)
PICO_BOOTSEL_LABELS=("RPI-RP2" "RP2350" "RPI-RP2350" "RPI-RP2040")

# All known post-flash mount labels
PICO_READY_LABELS=("CIRCUITPY" "MicroPython")
# ─────────────────────────────────────────────────────────────────────────────

# ── COLORS ────────────────────────────────────────────────────────────────────
R='\033[0;31m'       # red
G='\033[0;32m'       # green
Y='\033[0;33m'       # yellow
C='\033[0;36m'       # cyan
M='\033[0;35m'       # magenta
W='\033[1;37m'       # white bold
D='\033[2m'          # dim
B='\033[1m'          # bold
X='\033[0m'          # reset

# ── LOGGING ───────────────────────────────────────────────────────────────────
info()    { echo -e "${D}│${X}  ${C}→${X}  $*"; }
success() { echo -e "${D}│${X}  ${G}✔${X}  ${G}$*${X}"; }
warn()    { echo -e "${D}│${X}  ${Y}◎${X}  ${Y}$*${X}"; }
error()   { echo -e "${D}│${X}  ${R}✘${X}  ${R}$*${X}" >&2; }
dim()     { echo -e "   ${D}$*${X}"; }

divider()     { echo -e "${D}├─────────────────────────────────────────────────────────────${X}"; }
divider_top() { echo -e "${D}┌─────────────────────────────────────────────────────────────${X}"; }
divider_bot() { echo -e "${D}└─────────────────────────────────────────────────────────────${X}"; }

step() {
    local num="$1" total="$2" label="$3"
    echo ""
    echo -e "${D}│${X}"
    echo -e "${D}│${X}  ${D}step ${X}${W}${B}${num}${X}${D}/${total}${X}   ${M}${B}${label}${X}"
    echo -e "${D}├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌${X}"
}

# ── AUTO-DETECT MEDIA ROOT ────────────────────────────────────────────────────
find_media_root() {
    for base in "/media/$USER" "/run/media/$USER"; do
        [ -d "$base" ] && echo "$base" && return 0
    done
    echo "/media/$USER"
}
MEDIA_ROOT=$(find_media_root)

# ── LABEL-BASED MOUNT FINDER ─────────────────────────────────────────────────
# Checks /dev/disk/by-label first (most reliable), then falls back to $MEDIA_ROOT/<label>
find_pico_mount() {
    local labels=("$@")
    for label in "${labels[@]}"; do
        # Method 1: kernel label via by-label symlink
        local by_label="/dev/disk/by-label/$label"
        if [ -L "$by_label" ]; then
            local dev
            dev=$(readlink -f "$by_label")
            local mount
            mount=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | grep -v '^$' | head -n1)
            if [ -n "$mount" ]; then
                echo "$mount"
                return 0
            fi
        fi
        # Method 2: distro auto-mount folder (Ubuntu/Fedora/Arch)
        local path="$MEDIA_ROOT/$label"
        if [ -d "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# ── WAIT FOR A PICO MOUNT ─────────────────────────────────────────────────────
# Usage: wait_for_pico_mount "description" label1 label2 ...
# Prints the mount path on stdout; status/spinner goes to stderr.
wait_for_pico_mount() {
    local desc="$1"
    shift
    local labels=("$@")
    local elapsed=0
    local spin=('⠁' '⠂' '⠄' '⡀' '⢀' '⠠' '⠐' '⠈')

    while [ $elapsed -lt $WAIT_TIMEOUT ]; do
        local found
        found=$(find_pico_mount "${labels[@]}")
        if [ -n "$found" ]; then
            printf "\r\033[K" >&2
            success "${desc}  ${D}→  ${found}${X}" >&2
            echo "$found"
            return 0
        fi
        local frame=$(( elapsed % ${#spin[@]} ))
        printf "\r${D}│${X}  ${M}${spin[$frame]}${X}  ${D}${desc}  ${elapsed}s/${WAIT_TIMEOUT}s${X}  " >&2
        sleep 1
        (( elapsed++ ))
    done

    printf "\r\033[K" >&2
    error "Timed out after ${WAIT_TIMEOUT}s — ${desc}" >&2
    return 1
}

# ── UNMOUNT WATCHER ───────────────────────────────────────────────────────────
wait_for_unmount() {
    local mount_path="$1"
    local elapsed=0
    local spin=('⠁' '⠂' '⠄' '⡀' '⢀' '⠠' '⠐' '⠈')
    while [ $elapsed -lt 30 ]; do
        [ ! -d "$mount_path" ] && printf "\r\033[K" >&2 && return 0
        local frame=$(( elapsed % ${#spin[@]} ))
        printf "\r${D}│${X}  ${M}${spin[$frame]}${X}  ${D}Ejecting...  ${elapsed}s${X}  " >&2
        sleep 1
        (( elapsed++ ))
    done
    printf "\r\033[K" >&2
    warn "Mount still present after 30s — continuing anyway."
}

# ── COPY FILE ─────────────────────────────────────────────────────────────────
copy_file() {
    local src="$1" dest="$2" label="$3"
    if [ ! -f "$src" ]; then
        error "Not found: $src"
        exit 1
    fi
    info "Writing  ${D}${label}${X}"
    cp "$src" "$dest" && sync && success "${label} written." || { error "Failed: ${label}"; exit 1; }
}

# ── AUTO-DETECT CIRCUITPYTHON UF2 ─────────────────────────────────────────────
detect_driver() {
    local matches=()
    while IFS= read -r -d '' f; do
        matches+=("$f")
    done < <(find "$PICO_DIR" -maxdepth 1 -name "adafruit-circuitpython-*pico*w*.uf2" -print0 2>/dev/null)

    if [ ${#matches[@]} -eq 0 ]; then
        error "No CircuitPython .uf2 found in $PICO_DIR"
        dim "Expected: adafruit-circuitpython-raspberry_pi_pico2_w-en_US-*.uf2"
        exit 1
    elif [ ${#matches[@]} -gt 1 ]; then
        warn "Multiple .uf2 found — pick one:"
        select choice in "${matches[@]}"; do
            [ -n "$choice" ] && echo "$choice" && return 0
            error "Invalid choice."
        done
    else
        echo "${matches[0]}"
    fi
}

# ── UDEV RULE INSTALLER ───────────────────────────────────────────────────────
UDEV_RULE_FILE="/etc/udev/rules.d/99-pico.rules"

ensure_udev_rules() {
    # Already installed — nothing to do
    [ -f "$UDEV_RULE_FILE" ] && return 0

    warn "Pico udev rules not found — Pico drives may mount read-only."
    info "Installing udev rules so Pico mounts are always writable for $USER..."
    echo ""

    sudo tee "$UDEV_RULE_FILE" > /dev/null << UDEV
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="RPI-RP2",    MODE="0666", OWNER="$USER"
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="RP2350",     MODE="0666", OWNER="$USER"
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="RPI-RP2350", MODE="0666", OWNER="$USER"
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="RPI-RP2040", MODE="0666", OWNER="$USER"
SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="CIRCUITPY",  MODE="0666", OWNER="$USER"
UDEV

    if [ $? -ne 0 ]; then
        error "Failed to install udev rules — you may need to run with sudo once."
        error "Or manually create: $UDEV_RULE_FILE"
        exit 1
    fi

    sudo udevadm control --reload-rules
    success "udev rules installed — Pico drives will now mount writable."
    info "Unplug and replug the Pico if it is already connected."
    echo ""
}

# ── PREFLIGHT CHECKS ──────────────────────────────────────────────────────────
preflight_checks() {
    local ok=1

    # lsblk is needed for by-label resolution
    if ! command -v lsblk &>/dev/null; then
        warn "lsblk not found — by-label detection disabled, using folder fallback only."
    fi

    # Ensure udev rules exist so Pico mounts are writable without sudo
    ensure_udev_rules

    # Check source files exist
    [ ! -f "$SOURCE_FLASH_NUKE" ]    && error "Missing: $SOURCE_FLASH_NUKE"    && ok=0
    [ ! -d "$SOURCE_NEEDED_FILES" ]  && error "Missing dir: $SOURCE_NEEDED_FILES" && ok=0

    [ $ok -eq 0 ] && exit 1
}

# ── EJECT PICO ───────────────────────────────────────────────────────────────
eject_pico() {
    local mount_path="$1"
    info "Ejecting Pico to prevent payload firing on this machine..."
    sync
    local dev
    dev=$(findmnt -n -o SOURCE "$mount_path" 2>/dev/null)
    local disk
    disk=$(lsblk -no PKNAME "$dev" 2>/dev/null)

    udisksctl unmount -b "$dev" &>/dev/null         || umount "$mount_path" 2>/dev/null

    if [ -n "$disk" ]; then
        udisksctl power-off -b "/dev/$disk" &>/dev/null             || eject "/dev/$disk" 2>/dev/null             || warn "Could not fully eject — unplug the Pico manually before deploying."
    fi
    success "Pico ejected — safe to unplug."
}

# =============================================================================
# MAIN
# =============================================================================

clear
echo ""
echo -e "${M}${B}"
cat << 'BANNER'
      ____  ______________  ________    ___   _____ __  __
     / __ \/  _/ ____/ __ \/ ____/ /   /   | / ___// / / /
    / /_/ // // /   / / / / /_  / /   / /| | \__ \/ /_/ / 
   / ____// // /___/ /_/ / __/ / /___/ ___ |___/ / __  /  
  /_/   /___/\____/\____/_/   /_____/_/  |_/____/_/ /_/   
                                                          
  
BANNER
echo -e "${X}"
echo -e "   ${D}automated flash tool  ·  by ${X}${W}UmbraDomini${X}"
echo ""

preflight_checks
SOURCE_DRIVER=$(detect_driver)

echo -e "${D}┌─────────────────────────────────────────────────────────────${X}"
echo -e "${D}│${X}  ${D}firmware ${X} ${C}$(basename "$SOURCE_DRIVER")${X}"
echo -e "${D}│${X}  ${D}pico dir ${X} ${W}$PICO_DIR${X}"
echo -e "${D}│${X}  ${D}media    ${X} ${W}$MEDIA_ROOT${X}"
echo -e "${D}│${X}  ${D}detect   ${X} ${G}label-based${X}  ${D}RPI-RP2 · RP2350 · RPI-RP2350 · RPI-RP2040${X}"
echo -e "${D}└─────────────────────────────────────────────────────────────${X}"

# ── DISCLAIMER ───────────────────────────────────────────────────────────────
echo ""
echo -e "${Y}${B}  ⚠  before you continue${X}"
echo -e "${D}  ┌──────────────────────────────────────────────────────────${X}"
echo -e "${D}  │${X}  ${W}·${X} This script will ${R}completely wipe${X} the Pico's flash.${X}"
echo -e "${D}  │${X}  ${W}·${X} Any existing firmware or files ${R}will be lost${X}.${X}"
echo -e "${D}  │${X}  ${W}·${X} The payload feature is for ${Y}your own devices only${X}.${X}"
echo -e "${D}  │${X}  ${W}·${X} You are ${W}solely responsible${X} for how this tool is used.${X}"
echo -e "${D}  └──────────────────────────────────────────────────────────${X}"
echo ""
printf "  ${D}continue?${X}  ${W}(y/N):${X} "
read -r _disclaimer
echo ""
if [[ ! "$_disclaimer" =~ ^[Yy]$ ]]; then
    warn "aborted."
    echo ""
    exit 0
fi

# ── STEP 1 ───────────────────────────────────────────────────────────────────
step 1 5 "detect pico (BOOTSEL)"
echo ""
info "Hold BOOTSEL, plug in the Pico, and wait..."
echo ""

PICO_MOUNT=$(wait_for_pico_mount "waiting for Pico..." "${PICO_BOOTSEL_LABELS[@]}")
[ $? -ne 0 ] && exit 1

# ── STEP 2 ───────────────────────────────────────────────────────────────────
step 2 5 "wipe flash"
copy_file "$SOURCE_FLASH_NUKE" "$PICO_MOUNT/" "flash_nuke.uf2"
info "Ejecting..."
wait_for_unmount "$PICO_MOUNT"

# After nuke the Pico remounts as a BOOTSEL drive again — wait for it
PICO_MOUNT=$(wait_for_pico_mount "waiting for post-nuke device..." "${PICO_BOOTSEL_LABELS[@]}")
[ $? -ne 0 ] && exit 1

# ── STEP 3 ───────────────────────────────────────────────────────────────────
step 3 5 "flash circuitpython"
copy_file "$SOURCE_DRIVER" "$PICO_MOUNT/" "$(basename "$SOURCE_DRIVER")"
info "Ejecting..."
wait_for_unmount "$PICO_MOUNT"

CIRCUITPY_MOUNT=$(wait_for_pico_mount "waiting for CIRCUITPY..." "${PICO_READY_LABELS[@]}")
[ $? -ne 0 ] && exit 1

# ── STEP 4 ───────────────────────────────────────────────────────────────────
step 4 5 "copy project files"
cp -r "$SOURCE_NEEDED_FILES"/. "$CIRCUITPY_MOUNT/" \
    && sync \
    && success "project files written." \
    || { error "failed to copy project files."; exit 1; }

# ── STEP 5 ───────────────────────────────────────────────────────────────────
step 5 5 "payload"
echo ""
PAYLOAD_LOADED=0

# Scan pico dir for all .dd files
mapfile -t PAYLOAD_FILES < <(find "$PICO_DIR" -maxdepth 1 -name "*.dd" 2>/dev/null | sort)

if [ ${#PAYLOAD_FILES[@]} -eq 0 ]; then
    warn "no .dd payloads found in $PICO_DIR — skipping."
else
    # Show picker — loops back if user says N at the confirm prompt
    while true; do
        echo -e "${D}│${X}  ${W}available payloads:${X}"
        echo -e "${D}│${X}"
        for i in "${!PAYLOAD_FILES[@]}"; do
            echo -e "${D}│${X}  ${C}${B}  $((i+1))${X}  ${D}→${X}  $(basename "${PAYLOAD_FILES[$i]}")"
        done
        echo -e "${D}│${X}  ${C}${B}  0${X}  ${D}→${X}  skip — no payload"
        echo -e "${D}│${X}"
        printf "${D}│${X}  ${W}select payload:${X}  ${D}(0-${#PAYLOAD_FILES[@]}):${X} "
        read -r pick
        echo ""

        if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#PAYLOAD_FILES[@]}" ]; then
            SOURCE_PAYLOAD="${PAYLOAD_FILES[$((pick-1))]}"
            PAYLOAD_NAME=$(basename "$SOURCE_PAYLOAD")
            echo -e "${D}│${X}"
            echo -e "${D}│${X}  ${R}${B}⚠  WARNING${X}  ${Y}payload executes IMMEDIATELY on copy${X}"
            echo -e "${D}│${X}  ${D}         CircuitPython will restart code.py the instant it lands.${X}"
            echo -e "${D}│${X}  ${D}         Only proceed if deploying to a target machine.${X}"
            echo -e "${D}│${X}"
            printf "${D}│${X}  ${W}arm ${C}${PAYLOAD_NAME}${X}${W}?${X}  ${D}(y/N):${X} "
            read -r answer
            echo ""
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                copy_file "$SOURCE_PAYLOAD" "$CIRCUITPY_MOUNT/payload.dd" "$PAYLOAD_NAME"
                echo -e "${D}│${X}  ${R}${B}⚡ payload armed —${X} ${C}${PAYLOAD_NAME}${X}"
                eject_pico "$CIRCUITPY_MOUNT"
                PAYLOAD_LOADED=1
                break
            else
                echo ""
            fi
        else
            success "payload skipped — safe mode."
            break
        fi
    done
fi

# ── DONE ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${D}┌─────────────────────────────────────────────────────────────${X}"
if [ "${PAYLOAD_LOADED}" = "1" ]; then
    echo -e "${D}│${X}  ${G}${B}✔  all done — pico is ready.${X}"
    echo -e "${D}│${X}  ${R}${B}⚡ payload armed${X}  ${C}${PAYLOAD_NAME}${X}  ${R}${B}— deploy to target.${X}"
else
    echo -e "${D}│${X}  ${G}${B}✔  all done — pico is ready.${X}"
    echo -e "${D}│${X}  ${D}mounted at${X}  ${W}${CIRCUITPY_MOUNT}${X}"
    echo -e "${D}│${X}  ${G}no payload — safe to use.${X}"
fi
echo -e "${D}└─────────────────────────────────────────────────────────────${X}"
echo ""
