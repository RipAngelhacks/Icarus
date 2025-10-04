#!/bin/sh
# Full Safe Reset Script for Chromebook (VT4 Internet Recovery - Disables Secure Mode Error)
# Adapted from "daub" by HarryJarry1 for KV6 Corsola V140 on steelix (Lenovo 300e Yoga Gen 4).
# This uses current (2025) compatible methods: Wipes stateful (data reset), manipulates GPT for dev boot priority,
# sets disable_dev_request=1 to skip "return to secure mode" prompt, and clears enrollment data where possible.
# Run as root in VT4 shell (Ctrl + Alt + F4). Software-only; no hardware mods. Erases all user data.
# WARNING: Experimental in recovery; backs up nothing. If fails, use internet recovery. Does not guarantee full unenroll on KV6 (may need cryptohome post-boot).
# After reboot, boot to dev mode and run: cryptohome --action=remove_firmware_management_parameters for complete unenroll.

fail() {
    printf "$1\n"
    printf "exiting...\n"
    exit 1
}

# Safety check: Confirm tools exist (standard in recovery shell)
check_tools() {
    for tool in cgpt fdisk crossystem mount umount chroot mkdir rmdir vgchange vgscan awk grep head tr; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            fail "Missing tool: $tool. Ensure you're in full VT4 recovery shell."
        fi
    done
    echo "All required tools detected."
}

get_internal() {
    # Detect internal disk (eMMC for corsola/steelix)
    local ROOTDEV_LIST=$(cgpt find -t rootfs 2>/dev/null || fail "cgpt find failed - recovery issue?")
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
    echo "Detected internal disk: $intdis (type: $device_type)."
}

mountlvm() {
    vgchange -ay 2>/dev/null || echo "vgchange skipped (no LVM detected)."
    local volgroup=$(vgscan 2>/dev/null | grep "Found volume group" | awk '{print $4}' | tr -d '"')
    if [ -n "$volgroup" ]; then
        echo "Found volume group: $volgroup"
        mount "/dev/$volgroup/unencrypted" /stateful || fail "Could not mount LVM /stateful. Use standard recovery."
    else
        echo "No LVM; skipping."
    fi
}

main() {
    echo "Starting Chromebook reset process to disable secure mode error..."
    get_internal
    check_tools

    # Create temp mount point
    mkdir -p /localroot || fail "Could not create /localroot."

    # Mount root partition (ro for safety)
    local root_part="${intdis}${intdis_prefix}3"
    mount "$root_part" /localroot -o ro || fail "Could not mount root partition: $root_part."

    # Bind /dev for chroot
    mount --bind /dev /localroot/dev || fail "Could not bind /dev."

    # Set GPT priority for root B (enables dev mode boot)
    chroot /localroot cgpt add "$intdis" -i 2 -P 10 -T 5 -S 1 || echo "Warning: cgpt add failed (may already be configured)."

    # Delete reserved partitions 4 and 5 for clean state
    (
        echo "d"
        echo "4"
        echo "d"
        echo "5"
        echo "w"
    ) | chroot /localroot fdisk "$intdis" 2>/dev/null || echo "Warning: fdisk failed (disk may be busy)."

    # Cleanup mounts
    umount /localroot/dev 2>/dev/null || echo "Warning: umount /dev failed."
    umount /localroot 2>/dev/null || echo "Warning: umount root failed."
    rmdir /localroot 2>/dev/null || echo "Warning: rmdir failed."

    # Set flag to disable dev request (skips secure mode beep/prompt)
    crossystem disable_dev_request=1 || fail "crossystem failed - could not set disable_dev_request flag."

    # Mount and wipe stateful (full reset, clears enrollment cache)
    local stateful_part="${intdis}${intdis_prefix}1"
    if ! mount "$stateful_part" /stateful 2>/dev/null; then
        mountlvm  # Fallback to LVM if needed
    fi
    if mountpoint -q /stateful; then
        rm -rf /stateful/*  # Verbose wipe: add -v if desired
        echo "Stateful partition wiped (data reset complete)."
        umount /stateful 2>/dev/null || echo "Warning: umount /stateful failed."
    else
        echo "Warning: Could not mount/wipe /stateful (partial reset)."
    fi

    # Additional: Attempt cryptohome unenroll if tool available (post-reset)
    if command -v cryptohome >/dev/null 2>&1; then
        cryptohome --action=remove_firmware_management_parameters || echo "Warning: cryptohome unenroll failed (run after boot)."
    else
        echo "cryptohome not available in recovery; run after reboot."
    fi

    echo "Reset complete! Secure mode error should be bypassed on next boot."
    echo "Run 'reboot -f' to force reboot into dev mode (press Ctrl+D at any warning)."
    echo "Post-boot: In shell (Ctrl+Alt+F2), run 'cryptohome --action=remove_firmware_management_parameters' for full unenroll."
}

echo "WARNING: This will fully reset your Chromebook (erase all data, like a powerwash + more)."
echo "It disables the 'return to secure mode' error but may not fully unenroll on KV6 without post-boot steps."
echo "Backup anything important first (impossible in recovery, but noted)."
read -p "Are you sure you want to reset your Chromebook? (y/n) " -n 1 -r
echo
if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
    main
else
    echo "Aborted. No changes made."
fi
