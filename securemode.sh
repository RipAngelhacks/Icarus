#!/bin/sh
# Adapted Br0ker Script for KV6 Corsola V140 Unenroll (VT4 Internet Recovery - Keeps Dev Mode)
# Based on OlyB's Br0ker for BadApple/SH1MMER, modified for KV6 (no vulnerable kernel DD; uses existing rootfs).
# Focuses on stateful unblock files, VPD enrollment flag, and crossystem to bypass secure mode prompt.
# Run as root in VT4 (Ctrl + Alt + F4). Erases data. May need post-boot gsctool for full deprovision.
# WARNING: KV6 patched for kernel exploits; this emulates unblock effects. If prompt persists, WP disable needed.

fail() {
    printf "$1\n"
    printf "exiting...\n"
    exit 1
}

check_tools() {
    for tool in cgpt crossystem vpd mount umount mkdir rmdir awk grep head tr pv; do
        command -v "$tool" >/dev/null 2>&1 || echo "Warning: $tool unavailable (skip where possible)."
    done
    echo "Tools checked."
}

get_internal() {
    local ROOTDEV_LIST=$(cgpt find -t rootfs 2>/dev/null || fail "cgpt find failed.")
    if [ -z "$ROOTDEV_LIST" ]; then
        fail "Could not parse rootdev devices."
    fi
    local device_type=$(echo "$ROOTDEV_LIST" | grep -oE 'mmc|nvme|sda' | head -n 1)
    case $device_type in
        "mmc")
            intdis=/dev/mmcblk0
            intdis_prefix="p"
            ;;
        "nvme")
            intdis=/dev/nvme0
            intdis_prefix="n"
            ;;
        "sda")
            intdis=/dev/sda
            intdis_prefix=""
            ;;
        *)
            fail "Unknown device type: $device_type (expected mmc for corsola)."
            ;;
    esac
    echo "Detected internal disk: $intdis."
}

format_part_number() {
    echo -n "$1"
    echo "$1" | grep -q '[0-9]$' && echo -n p
    echo "$2"
}

main() {
    echo "Starting KV6-adapted Br0ker unenroll..."
    get_internal
    check_tools

    local CROS_DEV="$intdis"
    local TARGET_STATEFUL=$(format_part_number "$CROS_DEV" 1)
    local TARGET_KERN=$(format_part_number "$CROS_DEV" 2)
    local TARGET_ROOT=$(format_part_number "$CROS_DEV" 3)

    [ -b "$TARGET_STATEFUL" ] || fail "$TARGET_STATEFUL not block device!"
    [ -b "$TARGET_KERN" ] || fail "$TARGET_KERN not block device!"
    [ -b "$TARGET_ROOT" ] || fail "$TARGET_ROOT not block device!"

    # Skip TPM daemon stop (recovery)

    # Skip kernel ver check (KV6)

    echo "Using existing kernel/rootfs (V140 KV6 - no downgrade)."

    # Prioritize dev kernel (assume KERN-A/B setup)
    cgpt add "$CROS_DEV" -i 2 -S1 -T0 2>/dev/null || echo "cgpt add warning."
    cgpt prioritize "$CROS_DEV" -i 2 2>/dev/null || echo "cgpt prioritize warning."

    # Format stateful (wipes data)
    if command -v mkfs.ext4 >/dev/null 2>&1; then
        mkfs.ext4 -F -b 4096 -L H-STATE "$TARGET_STATEFUL"
    else
        MNT=$(mktemp -d)
        mount -o ro "$TARGET_ROOT" "$MNT" || fail "Mount root failed."
        mount --bind /dev "$MNT"/dev || fail "Bind /dev failed."
        chroot "$MNT" /sbin/mkfs.ext4 -F -b 4096 -L H-STATE "$TARGET_STATEFUL" || echo "mkfs warning."
        umount "$MNT"/dev 2>/dev/null || true
        umount "$MNT" 2>/dev/null || true
        rmdir "$MNT" 2>/dev/null || true
    fi

    # Mount stateful and create unblock files (key for unenroll)
    MNT=$(mktemp -d)
    mount "$TARGET_STATEFUL" "$MNT" || fail "Mount stateful failed."
    mkdir -p "$MNT"/dev_mode_unblock_broker || fail "Create unblock dir failed."
    touch "$MNT"/dev_mode_unblock_broker/carrier_lock_unblocked \
         "$MNT"/dev_mode_unblock_broker/init_state_determination_unblocked \
         "$MNT"/dev_mode_unblock_broker/enrollment_unblocked || echo "Touch files warning."
    umount "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true

    # Set VPD enrollment flag (clears check)
    vpd -i RW_VPD -s check_enrollment=0 || echo "VPD set warning (may need WP off)."

    # Set crossystem to skip secure prompt (keeps dev mode; omit block_devmode)
    crossystem disable_dev_request=1 || echo "crossystem warning."

    # Attempt deprovision if tools available
    if command -v gsctool >/dev/null 2>&1; then
        gsctool -a -o || echo "gsctool warning (press power for PP)."
    fi
    if command -v cryptohome >/dev/null 2>&1; then
        cryptohome --action=remove_firmware_management_parameters || echo "cryptohome warning."
    fi
    if command -v tpm_manager_client >/dev/null 2>&1; then
        tpm_manager_client take_ownership || echo "tpm warning."
    fi

    echo "Complete! Reboot -f. Ctrl+D at warning to boot dev mode."
    echo "Post-boot: Ctrl+Alt+F2 > chronos > sudo su > dmver check (UNENROLLED?)."
    echo "If enrolled, retry gsctool + powerwash."
    sleep 3
    reboot -f
}

echo "WARNING: Erases data on stateful. Adapted for KV6 - may need manual post-boot steps."
read -p "Continue unenroll? (y/N) " -n 1 -r
echo
case "$REPLY" in [yY]) main ;; *) echo "Aborted." ;; esac
