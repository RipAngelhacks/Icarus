#!/bin/sh
# Full Safe Reset & Unenroll Script for Chromebook (VT4 Internet Recovery - Bypasses Secure Mode, Keeps Dev Mode)
# Adapted from BadApple-Icarus "daub" by HarryJarry1 for KV6 Corsola V140 on steelix (Lenovo 300e Yoga Gen 4).
# Uses 2025-compatible methods: Wipes stateful, GPT tweaks for dev boot, gsctool deprovision, cryptohome FWMP removal.
# No disable_dev_request flag to preserve dev mode. Run as root in VT4 (Ctrl + Alt + F4). Erases data.
# WARNING: In recovery; may need PP (power button) for gsctool. If fails, retry post-boot in shell.

fail() {
    printf "$1\n"
    printf "exiting...\n"
    exit 1
}

check_tools() {
    for tool in cgpt fdisk crossystem mount umount chroot mkdir rmdir vgchange vgscan awk grep head tr gsctool cryptohome tpm_manager_client dmver; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Warning: $tool not available (expected in some recovery; skip where possible)."
        fi
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

mountlvm() {
    vgchange -ay 2>/dev/null || true
    local volgroup=$(vgscan 2>/dev/null | grep "Found volume group" | awk '{print $4}' | tr -d '"')
    if [ -n "$volgroup" ]; then
        mount "/dev/$volgroup/unencrypted" /stateful || fail "LVM mount failed."
    fi
}

main() {
    echo "Starting unenroll process..."
    get_internal
    check_tools

    mkdir -p /localroot || fail "Create /localroot failed."

    local root_part="${intdis}${intdis_prefix}3"
    mount "$root_part" /localroot -o ro || fail "Mount root ro failed: $root_part."

    mount --bind /dev /localroot/dev || fail "Bind /dev failed."

    chroot /localroot cgpt add "$intdis" -i 2 -P 10 -T 5 -S 1 || echo "cgpt add warning."

    (
        echo "d"
        echo "4"
        echo "d"
        echo "5"
        echo "w"
    ) | chroot /localroot fdisk "$intdis" 2>/dev/null || echo "fdisk warning."

    umount /localroot/dev 2>/dev/null || true
    umount /localroot 2>/dev/null || true
    rmdir /localroot 2>/dev/null || true

    # No disable_dev_request - keep dev mode

    local stateful_part="${intdis}${intdis_prefix}1"
    if ! mount "$stateful_part" /stateful 2>/dev/null; then
        mountlvm
    fi
    if mountpoint -q /stateful; then
        rm -rf /stateful/*
        echo "Stateful wiped."
        umount /stateful 2>/dev/null || true
    fi

    # Deprovision
    if command -v gsctool >/dev/null 2>&1; then
        echo "Deprovision TPM (press power if PP prompted)."
        gsctool -a -o || echo "gsctool warning (retry post-boot)."
    fi
    if command -v cryptohome >/dev/null 2>&1; then
        cryptohome --action=remove_firmware_management_parameters || echo "cryptohome warning."
    fi
    if command -v tpm_manager_client >/dev/null 2>&1; then
        tpm_manager_client take_ownership || echo "tpm_manager warning."
    fi
    if command -v dmver >/dev/null 2>&1; then
        dmver check || echo "dmver warning."
    fi

    echo "Complete! Reboot -f, Ctrl+D at warning. Post-boot: Retry commands in shell if needed."
    sleep 3
    reboot -f
}

echo "WARNING: Erases data, unenrolls where possible."
read -p "Reset Chromebook? (y/n) " -n 1 -r
echo
if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
    main
fi
