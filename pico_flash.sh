#!/bin/bash

# =============================================================================
#   Author : UmbraDomini
#   Tool   : Pico 2 W Flash & Management Script
#   Usage  : ./pico_flash.sh
#   Flash  : Hold BOOTSEL while plugging in → full wipe + reflash
#   Setup  : Bridge GP0→GND, plug in normally → setup menu (no payload fire)
# =============================================================================

# ── CONFIG ────────────────────────────────────────────────────────────────────
PICO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_FLASH_NUKE="$PICO_DIR/flash_nuke.uf2"
SOURCE_NEEDED_FILES="$PICO_DIR/needed_files"

WAIT_TIMEOUT=60

PICO_BOOTSEL_LABELS=("RPI-RP2" "RP2350" "RPI-RP2350" "RPI-RP2040")
PICO_READY_LABELS=("CIRCUITPY" "MicroPython")
# ─────────────────────────────────────────────────────────────────────────────

# ── COLORS ────────────────────────────────────────────────────────────────────
R='\033[0;31m'
G='\033[0;32m'
Y='\033[0;33m'
C='\033[0;36m'
M='\033[0;35m'
W='\033[1;37m'
D='\033[2m'
B='\033[1m'
X='\033[0m'

# ── LOGGING ───────────────────────────────────────────────────────────────────
info()    { echo -e "${D}│${X}  ${C}→${X}  $*"; }
success() { echo -e "${D}│${X}  ${G}✔${X}  ${G}$*${X}"; }
warn()    { echo -e "${D}│${X}  ${Y}◎${X}  ${Y}$*${X}"; }
error()   { echo -e "${D}│${X}  ${R}✘${X}  ${R}$*${X}" >&2; }
dim()     { echo -e "   ${D}$*${X}"; }

divider_top() { echo -e "${D}┌─────────────────────────────────────────────────────────────${X}"; }
divider_bot() { echo -e "${D}└─────────────────────────────────────────────────────────────${X}"; }

show_mode_banner() {
    case "$1" in
        setup) local label="Entering Setup Mode" ; local color="$G" ;;
        flash) local label="Entering Flash Mode" ; local color="$C" ;;
        *)     local label="Entering $1 Mode"    ; local color="$W" ;;
    esac
    local dashes="─────────────────────────────────────────────────────────────"
    local pad=$(( 57 - ${#label} ))
    echo ""
    echo -e "${color}${B}┌${dashes}┐${X}"
    echo -e "${color}${B}│  ${label}$(printf '%*s' $pad '')  │${X}"
    echo -e "${color}${B}└${dashes}┘${X}"
    echo ""
}

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

# ── DESKTOP PATH ─────────────────────────────────────────────────────────────
find_desktop() {
    if [ -d "$HOME/Desktop" ]; then
        echo "$HOME/Desktop"
    else
        echo "$HOME"
    fi
}
DESKTOP=$(find_desktop)

# ── LABEL-BASED MOUNT FINDER ──────────────────────────────────────────────────
find_pico_mount() {
    local labels=("$@")
    for label in "${labels[@]}"; do
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
        local path="$MEDIA_ROOT/$label"
        if [ -d "$path" ]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

# ── WAIT FOR MOUNT ────────────────────────────────────────────────────────────
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

    if ! command -v lsblk &>/dev/null; then
        warn "lsblk not found — by-label detection disabled, using folder fallback only."
    fi

    ensure_udev_rules

    [ ! -f "$SOURCE_FLASH_NUKE" ]   && error "Missing: $SOURCE_FLASH_NUKE"       && ok=0
    [ ! -d "$SOURCE_NEEDED_FILES" ] && error "Missing dir: $SOURCE_NEEDED_FILES"  && ok=0

    [ $ok -eq 0 ] && exit 1
}

# ── EJECT PICO ────────────────────────────────────────────────────────────────
eject_pico() {
    local mount_path="$1"
    info "Ejecting Pico..."
    sync
    local dev
    dev=$(findmnt -n -o SOURCE "$mount_path" 2>/dev/null)
    local disk
    disk=$(lsblk -no PKNAME "$dev" 2>/dev/null)

    udisksctl unmount -b "$dev" &>/dev/null || umount "$mount_path" 2>/dev/null

    if [ -n "$disk" ]; then
        udisksctl power-off -b "/dev/$disk" &>/dev/null \
            || eject "/dev/$disk" 2>/dev/null \
            || warn "Could not fully eject — unplug the Pico manually."
    fi
    success "Pico ejected — safe to unplug."
}

# =============================================================================
# SETUP MODE
# =============================================================================

run_setup_mode() {
    local CIRCUITPY_MOUNT="$1"

    show_mode_banner "setup"
    divider_top
    echo -e "${D}│${X}  ${M}${B}setup mode${X}  ${D}→${X}  ${W}${CIRCUITPY_MOUNT}${X}"
    echo -e "${D}│${X}  ${D}GP0 bridged to GND — payload is suppressed${X}"
    echo -e "${D}└─────────────────────────────────────────────────────────────${X}"

    while true; do
        echo ""
        echo -e "${D}│${X}  ${W}what do you want to do?${X}"
        echo -e "${D}│${X}"
        echo -e "${D}│${X}  ${C}${B}  1${X}  ${D}→${X}  swap payload"
        echo -e "${D}│${X}  ${C}${B}  2${X}  ${D}→${X}  download file to desktop"
        echo -e "${D}│${X}  ${C}${B}  3${X}  ${D}→${X}  eject"
        echo -e "${D}│${X}  ${C}${B}  4${X}  ${D}→${X}  full reflash  ${D}(wipes everything)${X}"
        echo -e "${D}│${X}"
        printf "${D}│${X}  ${W}choice:${X}  "
        read -r choice
        echo ""

        case "$choice" in
            1) setup_swap_payload "$CIRCUITPY_MOUNT" ;;
            2) setup_download_file "$CIRCUITPY_MOUNT" ;;
            3)
                eject_pico "$CIRCUITPY_MOUNT"
                echo ""
                exit 0
                ;;
            4)
                echo -e "${D}│${X}  ${Y}◎  this will reflash the Pico — all files will be lost.${X}"
                printf "${D}│${X}  ${W}are you sure?${X}  ${D}(y/N):${X} "
                read -r confirm
                echo ""
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    # Eject cleanly first, then ask user to replug in BOOTSEL mode
                    step 1 2 "eject pico"
                    eject_pico "$CIRCUITPY_MOUNT"
                    wait_for_unmount "$CIRCUITPY_MOUNT"

                    step 2 2 "enter bootsel mode"
                    echo ""
                    echo -e "${D}│${X}  ${Y}${B}  ⚠  manual step required${X}"
                    echo -e "${D}├╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌${X}"
                    echo -e "${D}│${X}  ${W}·${X}  ${R}Unplug${X} the Pico"
                    echo -e "${D}│${X}  ${W}·${X}  Hold the ${Y}${B}BOOTSEL${X} button on the Pico"
                    echo -e "${D}│${X}  ${W}·${X}  While holding BOOTSEL, ${G}plug it back in${X}"
                    echo -e "${D}│${X}  ${W}·${X}  Then release BOOTSEL"
                    echo -e "${D}│${X}"
                    echo -e "${D}│${X}  ${D}waiting for Pico in BOOTSEL mode...${X}"
                    echo ""

                    local BOOTSEL_MOUNT
                    BOOTSEL_MOUNT=$(wait_for_pico_mount "waiting for BOOTSEL device..." "${PICO_BOOTSEL_LABELS[@]}")
                    [ $? -ne 0 ] && exit 1

                    run_flash_mode "$BOOTSEL_MOUNT"
                    exit 0
                else
                    warn "reflash cancelled."
                fi
                ;;
            *)
                warn "invalid choice — pick 1, 2, 3, or 4."
                ;;
        esac
    done
}

# ── SETUP: SWAP PAYLOAD ───────────────────────────────────────────────────────
setup_swap_payload() {
    local CIRCUITPY_MOUNT="$1"

    # Show what's currently on the Pico
    local current=""
    if [ -f "$CIRCUITPY_MOUNT/payload.dd" ]; then
        current="payload.dd  ${D}($(du -h "$CIRCUITPY_MOUNT/payload.dd" 2>/dev/null | cut -f1) on device)${X}"
    else
        current="${D}none — no payload.dd found on device${X}"
    fi

    echo -e "${D}│${X}  ${D}current payload on Pico:${X}  ${Y}${current}${X}"
    echo -e "${D}│${X}"

    # Scan project dir for .dd files
    mapfile -t PAYLOAD_FILES < <(find "$PICO_DIR" -maxdepth 1 -name "*.dd" 2>/dev/null | sort)

    if [ ${#PAYLOAD_FILES[@]} -eq 0 ]; then
        warn "no .dd files found in $PICO_DIR — nothing to swap."
        return
    fi

    echo -e "${D}│${X}  ${W}available payloads:${X}"
    echo -e "${D}│${X}"
    for i in "${!PAYLOAD_FILES[@]}"; do
        echo -e "${D}│${X}  ${C}${B}  $((i+1))${X}  ${D}→${X}  $(basename "${PAYLOAD_FILES[$i]}")"
    done
    echo -e "${D}│${X}  ${C}${B}  0${X}  ${D}→${X}  cancel"
    echo -e "${D}│${X}"
    printf "${D}│${X}  ${W}select:${X}  ${D}(0-${#PAYLOAD_FILES[@]}):${X} "
    read -r pick
    echo ""

    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#PAYLOAD_FILES[@]}" ]; then
        local new_payload="${PAYLOAD_FILES[$((pick-1))]}"
        local new_name
        new_name=$(basename "$new_payload")

        echo -e "${D}│${X}  ${D}replacing:${X}  ${Y}${current}${X}"
        echo -e "${D}│${X}  ${D}with:     ${X}  ${G}${new_name}${X}"
        echo -e "${D}│${X}"
        printf "${D}│${X}  ${W}confirm swap?${X}  ${D}(y/N):${X} "
        read -r confirm
        echo ""

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            copy_file "$new_payload" "$CIRCUITPY_MOUNT/payload.dd" "$new_name"
        else
            warn "swap cancelled."
        fi
    else
        warn "swap cancelled."
    fi
}

# ── SETUP: DOWNLOAD FILE TO DESKTOP ──────────────────────────────────────────
setup_download_file() {
    local CIRCUITPY_MOUNT="$1"

    # List all files on the Pico (non-hidden, non-directory)
    mapfile -t PICO_FILES < <(find "$CIRCUITPY_MOUNT" -maxdepth 1 -type f ! -name ".*" 2>/dev/null | sort)

    if [ ${#PICO_FILES[@]} -eq 0 ]; then
        warn "no files found on Pico."
        return
    fi

    echo -e "${D}│${X}  ${W}files on Pico:${X}"
    echo -e "${D}│${X}"
    for i in "${!PICO_FILES[@]}"; do
        local rel="${PICO_FILES[$i]#$CIRCUITPY_MOUNT/}"
        local size
        size=$(du -h "${PICO_FILES[$i]}" 2>/dev/null | cut -f1)
        echo -e "${D}│${X}  ${C}${B}  $((i+1))${X}  ${D}→${X}  ${rel}  ${D}(${size})${X}"
    done
    echo -e "${D}│${X}  ${C}${B}  0${X}  ${D}→${X}  cancel"
    echo -e "${D}│${X}"
    printf "${D}│${X}  ${W}select file to download:${X}  ${D}(0-${#PICO_FILES[@]}):${X} "
    read -r pick
    echo ""

    if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#PICO_FILES[@]}" ]; then
        local src="${PICO_FILES[$((pick-1))]}"
        local filename
        filename=$(basename "$src")
        local dest="$DESKTOP/$filename"

        # Avoid overwriting — append timestamp if file exists
        if [ -f "$dest" ]; then
            local ts
            ts=$(date +%Y%m%d_%H%M%S)
            dest="$DESKTOP/${filename%.*}_${ts}.${filename##*.}"
            # Handle files with no extension
            [[ "$filename" != *.* ]] && dest="$DESKTOP/${filename}_${ts}"
        fi

        cp "$src" "$dest" && sync \
            && success "saved to  ${D}→${X}  ${W}${dest}${X}" \
            || error "failed to copy file."
    else
        warn "download cancelled."
    fi
}

# =============================================================================
# FLASH MODE  (original flow, unchanged)
# =============================================================================

run_flash_mode() {
    local PICO_MOUNT="${1:-}"   # optional — pre-found BOOTSEL mount passed in from setup mode

    SOURCE_DRIVER=$(detect_driver)

    show_mode_banner "flash"
    divider_top
    echo -e "${D}│${X}  ${D}firmware ${X} ${C}$(basename "$SOURCE_DRIVER")${X}"
    echo -e "${D}│${X}  ${D}pico dir ${X} ${W}$PICO_DIR${X}"
    echo -e "${D}│${X}  ${D}media    ${X} ${W}$MEDIA_ROOT${X}"
    echo -e "${D}│${X}  ${D}detect   ${X} ${G}label-based${X}  ${D}RPI-RP2 · RP2350 · RPI-RP2350 · RPI-RP2040${X}"
    echo -e "${D}└─────────────────────────────────────────────────────────────${X}"

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

    # ── STEP 1 ────────────────────────────────────────────────────────────────
    step 1 5 "detect pico (BOOTSEL)"
    if [ -n "$PICO_MOUNT" ]; then
        echo ""
        success "device already in BOOTSEL mode  ${D}→  ${PICO_MOUNT}${X}"
    else
        echo ""
        info "Hold BOOTSEL, plug in the Pico, and wait..."
        echo ""
        PICO_MOUNT=$(wait_for_pico_mount "waiting for Pico..." "${PICO_BOOTSEL_LABELS[@]}")
        [ $? -ne 0 ] && exit 1
    fi

    # ── STEP 2 ────────────────────────────────────────────────────────────────
    step 2 5 "wipe flash"
    copy_file "$SOURCE_FLASH_NUKE" "$PICO_MOUNT/" "flash_nuke.uf2"
    info "Ejecting..."
    wait_for_unmount "$PICO_MOUNT"

    PICO_MOUNT=$(wait_for_pico_mount "waiting for post-nuke device..." "${PICO_BOOTSEL_LABELS[@]}")
    [ $? -ne 0 ] && exit 1

    # ── STEP 3 ────────────────────────────────────────────────────────────────
    step 3 5 "flash circuitpython"
    copy_file "$SOURCE_DRIVER" "$PICO_MOUNT/" "$(basename "$SOURCE_DRIVER")"
    info "Ejecting..."
    wait_for_unmount "$PICO_MOUNT"

    CIRCUITPY_MOUNT=$(wait_for_pico_mount "waiting for CIRCUITPY..." "${PICO_READY_LABELS[@]}")
    [ $? -ne 0 ] && exit 1

    # ── STEP 4 ────────────────────────────────────────────────────────────────
    step 4 5 "copy project files"
    cp -r "$SOURCE_NEEDED_FILES"/. "$CIRCUITPY_MOUNT/" \
        && sync \
        && success "project files written." \
        || { error "failed to copy project files."; exit 1; }

    # ── STEP 5 ────────────────────────────────────────────────────────────────
    step 5 5 "payload"
    echo ""
    PAYLOAD_LOADED=0
    PAYLOAD_NAME=""

    mapfile -t PAYLOAD_FILES < <(find "$PICO_DIR" -maxdepth 1 -name "*.dd" 2>/dev/null | sort)

    if [ ${#PAYLOAD_FILES[@]} -eq 0 ]; then
        warn "no .dd payloads found in $PICO_DIR — skipping."
    else
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

    # ── DONE ──────────────────────────────────────────────────────────────────
    echo ""
    divider_top
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
}

# =============================================================================
# ENTRY POINT — auto-route based on what's detected
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
echo -e "   ${D}flash & management tool  ·  by ${X}${W}UmbraDomini${X}"
echo ""

preflight_checks

# ── DETECT WHAT'S PLUGGED IN ──────────────────────────────────────────────────
CIRCUITPY_MOUNT=$(find_pico_mount "${PICO_READY_LABELS[@]}")
BOOTSEL_MOUNT=$(find_pico_mount "${PICO_BOOTSEL_LABELS[@]}")

if [ -n "$CIRCUITPY_MOUNT" ]; then
    # CIRCUITPY detected — GP0 bridged to GND, safe to manage
    run_setup_mode "$CIRCUITPY_MOUNT"

elif [ -n "$BOOTSEL_MOUNT" ]; then
    # BOOTSEL detected — full flash mode
    run_flash_mode

else
    # Nothing detected — ask the user what they want to do
    echo ""
    divider_top
    echo -e "${D}│${X}  ${Y}no Pico detected${X}"
    echo -e "${D}│${X}"
    echo -e "${D}│${X}  ${W}·${X}  ${G}setup mode${X}   ${D}→  bridge GP0→GND, then plug in normally${X}"
    echo -e "${D}│${X}  ${W}·${X}  ${C}flash mode${X}   ${D}→  hold BOOTSEL while plugging in${X}"
    echo -e "${D}│${X}"
    echo -e "${D}│${X}  ${W}waiting for Pico...${X}  ${D}(${WAIT_TIMEOUT}s timeout)${X}"
    echo -e "${D}└─────────────────────────────────────────────────────────────${X}"
    echo ""

    # Wait and re-check in a loop
    elapsed=0
    spin=('⠁' '⠂' '⠄' '⡀' '⢀' '⠠' '⠐' '⠈')
    while [ $elapsed -lt $WAIT_TIMEOUT ]; do
        CIRCUITPY_MOUNT=$(find_pico_mount "${PICO_READY_LABELS[@]}")
        BOOTSEL_MOUNT=$(find_pico_mount "${PICO_BOOTSEL_LABELS[@]}")

        if [ -n "$CIRCUITPY_MOUNT" ]; then
            printf "\r\033[K"
            run_setup_mode "$CIRCUITPY_MOUNT"
            exit 0
        elif [ -n "$BOOTSEL_MOUNT" ]; then
            printf "\r\033[K"
            run_flash_mode
            exit 0
        fi

        frame=$(( elapsed % ${#spin[@]} ))
        printf "\r${D}│${X}  ${M}${spin[$frame]}${X}  ${D}waiting...  ${elapsed}s/${WAIT_TIMEOUT}s${X}  "
        sleep 1
        (( elapsed++ ))
    done

    printf "\r\033[K"
    echo ""
    error "timed out — no Pico detected."
    echo ""
    exit 1
fi
