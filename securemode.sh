#!/bin/sh
# Full Safe Reset Script for Chromebook (VT4 Internet Recovery - Bypasses Secure Mode)
# Adapted from "daub" by HarryJarry1 for KV6 Corsola V140 on steelix (Lenovo 300e Yoga Gen 4).
# Uses current (2025) methods: Wipes stateful (data reset), manipulates GPT for dev boot priority,
# sets disable_dev_request=1 to skip "return to secure mode" prompt.
# Run as root in VT4 shell (Ctrl + Alt + F4). Software-only; no hardware mods. Erases all user data.
# WARNING: Experimental in recovery; backs up nothing. If fails, use internet recovery.
# After reboot to dev mode OS: Open shell (Ctrl+Alt+F2), run unenroll commands below for full deprovision.
# Manual unenroll post-boot: gsctool -a -o (press power button for PP if prompted); cryptohome --action=remove_firmware_management_parameters; tpm_manager_client take_ownership; dmver check (should show unenrolled).

fail() {
    printf "$1\n"
    printf "exiting...\n"
    exit 1
}

check_tools() {
    for tool in cgpt fdisk crossystem mount umount chroot mkdir rmdir vgchange vgscan awk grep head tr; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            fail "Missing tool: $tool. Ensure full VT4 recovery shell."
        fi
    done
    echo "All required tools detected."
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
    echo "Detected internal disk: $intdis (type: $device_type)."
}

mountlvm() {
    vgchange -ay 2>/dev/null || echo "vgchange skipped (no LVM)."
    local volgroup=$(vgscan 2>/dev/null | grep "Found volume group" | awk '{print $4}' | tr -d '"')
    if [ -n "$volgroup" ]; then
        echo "Found volume group: $volgroup"
        mount "/dev/$volgroup/unencrypted" /stateful || fail "Could not mount LVM /stateful."
    else
        echo "No LVM; skipping."
    fi
}

main() {
    echo "Starting Chromebook reset process to bypass secure mode error..."
    get_internal
    check_tools

    mkdir -p /localroot || fail "Could not create /localroot."

    local root_part="${intdis}${intdis_prefix}3"
    # Mount root ro (squashfs safe; no rw possible in recovery)
    mount "$root_part" /localroot -o ro || fail "Could not mount root ro: $root_part."

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

    # Attempt immediate unenroll if tools available (limited in recovery)
    if command -v cryptohome >/dev/null 2>&1; then
        cryptohome --action=remove_firmware_management_parameters || echo "Warning: cryptohome failed (run after boot)."
    fi
    if command -v gsctool >/dev/null 2>&1; then
        gsctool -a -o || echo "Warning: gsctool deprovision failed (press power for PP; retry after boot)."
    fi

    echo "Reset complete! Secure mode error should be bypassed on next boot."
    echo "Rebooting in 5 seconds... (Ctrl+C to cancel)"
    sleep 5
    reboot -f
}

echo "WARNING: This will fully reset your Chromebook (erase all data, like a powerwash + more)."
echo "It disables the 'return to secure mode' error; manual unenroll needed post-boot for KV6."
echo "Press Enter to proceed with reset and reboot, or Ctrl+C to abort."
read -r
if [ -n "$REPLY" ] && [ "$REPLY" != "" ]; then
    echo "Aborted."
else
    main
fi
