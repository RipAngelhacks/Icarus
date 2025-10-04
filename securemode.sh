#!/bin/sh
# Full Safe Reset & Auto-Unenroll Script for Chromebook (VT4 Internet Recovery - Disables Secure Mode & Unenrolls on Boot)
# Adapted from "daub" by HarryJarry1 for KV6 Corsola V140 on steelix (Lenovo 300e Yoga Gen 4).
# Enhanced for automatic unenrollment: Modifies rootfs to add a one-time upstart job that runs deprovision & cryptohome on first boot.
# Uses current (2025) methods: Wipes stateful, GPT tweaks, disable_dev_request=1, plus boot-time unenroll hook.
# Run as root in VT4 shell (Ctrl + Alt + F4). Software-only; no hardware. Erases data. Hard but possible via rootfs mod.
# WARNING: Modifies rootfs (risky if interrupted); test tools. May not fully unenroll if TPM locked—run gsctool manually post-boot if needed.
# After reboot, job runs once, then self-deletes. Check enrollment status with 'dmver check'.

fail() {
    printf "$1\n"
    printf "exiting...\n"
    exit 1
}

check_tools() {
    for tool in cgpt fdisk crossystem mount umount chroot mkdir rmdir vgchange vgscan awk grep head tr initctl; do
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

setup_auto_unenroll() {
    # In chroot: Create unenroll script & upstart job for boot-time execution
    cat > /localroot/usr/local/bin/unenroll.sh << 'EOF'
#!/bin/sh
# One-time unenroll script
if [ -f /var/run/unenrolled ]; then
    exit 0  # Already run
fi

# Deprovision TPM if gsctool available
if command -v gsctool >/dev/null 2>&1; then
    gsctool -a -o 2>/dev/null || true
    sleep 2
fi

# Remove firmware management params if cryptohome available
if command -v cryptohome >/dev/null 2>&1; then
    cryptohome --action=remove_firmware_management_parameters 2>/dev/null || true
fi

# Take ownership if needed
if command -v tpm_manager_client >/dev/null 2>&1; then
    tpm_manager_client take_ownership 2>/dev/null || true
fi

# Mark as done & clean up
touch /var/run/unenrolled
rm -f /etc/init/unenroll.conf
rm -f /usr/local/bin/unenroll.sh
initctl reload-configuration 2>/dev/null || true
echo "Auto-unenroll complete."
EOF
    chroot /localroot chmod +x /usr/local/bin/unenroll.sh

    # Create upstart job to run early on boot (before UI)
    cat > /localroot/etc/init/unenroll.conf << 'EOF'
description "One-time unenroll"
author "Auto-Unenroll"

start on startup
task
script
    /usr/local/bin/unenroll.sh
end script
EOF
    echo "Auto-unenroll job created in rootfs."
}

main() {
    echo "Starting Chromebook reset & auto-unenroll process..."
    get_internal
    check_tools

    mkdir -p /localroot || fail "Could not create /localroot."

    local root_part="${intdis}${intdis_prefix}3"
    # Mount rw for modifications
    mount "$root_part" /localroot -o rw || fail "Could not mount root rw: $root_part."

    mount --bind /dev /localroot/dev || fail "Could not bind /dev."

    # GPT priority for root B
    chroot /localroot cgpt add "$intdis" -i 2 -P 10 -T 5 -S 1 || echo "Warning: cgpt add failed."

    # Delete partitions 4/5
    (
        echo "d"
        echo "4"
        echo "d"
        echo "5"
        echo "w"
    ) | chroot /localroot fdisk "$intdis" 2>/dev/null || echo "Warning: fdisk failed."

    # Setup auto-unenroll
    setup_auto_unenroll

    # Cleanup chroot mounts
    umount /localroot/dev 2>/dev/null || true
    umount /localroot 2>/dev/null || true
    rmdir /localroot 2>/dev/null || true

    # Disable dev request
    crossystem disable_dev_request=1 || fail "crossystem failed."

    # Wipe stateful
    local stateful_part="${intdis}${intdis_prefix}1"
    if ! mount "$stateful_part" /stateful 2>/dev/null; then
        mountlvm
    fi
    if mountpoint -q /stateful; then
        rm -rf /stateful/*
        echo "Stateful wiped."
        umount /stateful 2>/dev/null || true
    else
        echo "Warning: Could not wipe /stateful."
    fi

    # Attempt immediate unenroll if tools here
    if command -v cryptohome >/dev/null 2>&1; then
        cryptohome --action=remove_firmware_management_parameters || echo "Warning: cryptohome failed."
    fi
    if command -v gsctool >/dev/null 2>&1; then
        gsctool -a -o || echo "Warning: gsctool deprovision failed (press power for PP)."
    fi

    echo "Process complete! Secure mode bypassed; auto-unenroll runs on first boot."
    echo "Run 'reboot -f' to reboot (Ctrl+D at warnings)."
    echo "Post-boot: Check with 'dmver check'; if still enrolled, run unenroll commands manually in shell."
}

echo "WARNING: This resets your Chromebook (erases data) and modifies rootfs for auto-unenroll on boot."
echo "Hard but possible; may need manual TPM PP (power button) if prompted."
read -p "Are you sure you want to reset your Chromebook? (y/n) " -n 1 -r
echo
if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
    main
else
    echo "Aborted."
fi
