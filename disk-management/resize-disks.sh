#!/bin/bash
# =============================================================================
# resize-disks.sh
# Resizes Azure managed disks and expands the LVM PV/LV/filesystem online.
#
# Disk must already be attached to the VM. The VM does NOT need to be stopped
# for Premium_LRS disk expansion (online resize is supported).
#
# Usage:
#   ./resize-disks.sh --instance <number> --size-gb <new_size>
#
# Examples:
#   ./resize-disks.sh --instance 0 --size-gb 1250   (resize DDB1 + DDB2)
#   ./resize-disks.sh --instance 1 --size-gb 1250   (resize DDB3 + DDB4)
#
# What this script does:
#   1. Resizes each Azure managed disk to the new size via az disk update
#   2. SSHs into the VM and runs pvresize + lvextend + xfs_growfs
# =============================================================================

set -euo pipefail

# =============================================================================
# PARAMETERS - Modify these before running
# =============================================================================

RESOURCE_GROUP="<resource-group>"

# SSH connection to the VM
VM_IP="<vm-private-ip>"
SSH_KEY="~/.ssh/id_rsa"
SSH_USER="azureadm"

# Filesystem type on the DDB volumes
FILESYSTEM="xfs"

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

VM_INSTANCE=""
NEW_SIZE_GB=""

for arg in "$@"; do
    case $arg in
        --instance=*) VM_INSTANCE="${arg#*=}" ;;
        --instance)   shift; VM_INSTANCE="$1" ;;
        --size-gb=*)  NEW_SIZE_GB="${arg#*=}" ;;
        --size-gb)    shift; NEW_SIZE_GB="$1" ;;
    esac
done

if [[ -z "$VM_INSTANCE" ]]; then
    echo "ERROR: --instance is required"
    echo "  Usage: $0 --instance <number> --size-gb <new_size>"
    echo "  Example: $0 --instance 0 --size-gb 1250"
    exit 1
fi

if [[ -z "$NEW_SIZE_GB" ]]; then
    echo "ERROR: --size-gb is required"
    echo "  Usage: $0 --instance <number> --size-gb <new_size>"
    echo "  Example: $0 --instance 0 --size-gb 1250"
    exit 1
fi

# Derive disk names from instance number (matches add-disks-layout.sh naming)
DDB_START=$(( VM_INSTANCE * 2 + 1 ))
DDB_END=$(( DDB_START + 1 ))
DISK_NAMES=("DDB${DDB_START}" "DDB${DDB_END}")
VG_NAME="vg_ddb01"
LV_NAME="lv_ddb01"
MOUNT_POINT="/ddb01"

# =============================================================================
# STEP 1 - Resize Azure managed disks
# =============================================================================

echo ""
echo "====================================================================="
echo "  Resizing Azure disks to ${NEW_SIZE_GB} GB"
echo "  Resource Group: ${RESOURCE_GROUP}"
echo "====================================================================="

for DISK in "${DISK_NAMES[@]}"; do
    CURRENT_SIZE=$(az disk show -g "${RESOURCE_GROUP}" -n "${DISK}" --query diskSizeGB -o tsv 2>/dev/null || echo "NOT_FOUND")

    if [[ "$CURRENT_SIZE" == "NOT_FOUND" ]]; then
        echo "ERROR: Disk '${DISK}' not found in resource group '${RESOURCE_GROUP}'"
        exit 1
    fi

    if (( NEW_SIZE_GB <= CURRENT_SIZE )); then
        echo "ERROR: New size (${NEW_SIZE_GB} GB) must be larger than current size (${CURRENT_SIZE} GB) for disk '${DISK}'"
        echo "  Azure does not support shrinking managed disks."
        exit 1
    fi

    echo ">>> Resizing ${DISK}: ${CURRENT_SIZE} GB -> ${NEW_SIZE_GB} GB"
    az disk update \
        -g "${RESOURCE_GROUP}" \
        -n "${DISK}" \
        --size-gb "${NEW_SIZE_GB}"
    echo ">>> ${DISK} resized successfully"
done

# =============================================================================
# STEP 2 - Expand LVM and filesystem on the VM
# =============================================================================

echo ""
echo "====================================================================="
echo "  Connecting to ${VM_IP} and expanding LVM/filesystem..."
echo "====================================================================="

REMOTE_SCRIPT="set -e\n"

# Rescan all block devices so the OS sees the new disk sizes
REMOTE_SCRIPT+="echo '--- Rescanning block devices ---'\n"
REMOTE_SCRIPT+="for dev in /sys/class/block/sd*/device/rescan; do [ -f \"\$dev\" ] && echo 1 > \"\$dev\"; done\n"
REMOTE_SCRIPT+="sleep 2\n"

# Resize each PV (tells LVM the underlying disk is now larger)
for DISK in "${DISK_NAMES[@]}"; do
    REMOTE_SCRIPT+="echo '--- pvresize for ${DISK} ---'\n"
    REMOTE_SCRIPT+="PV_DEV=\$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '\$2==\"${VG_NAME}\" {print \$1}' | head -1)\n"
    REMOTE_SCRIPT+="pvresize \$(pvs --noheadings -o pv_name,vg_name 2>/dev/null | awk '\$2==\"${VG_NAME}\" {print \$1}')\n"
done

# Extend the LV to use all free space in the VG
REMOTE_SCRIPT+="echo '--- Extending LV to 100%FREE ---'\n"
REMOTE_SCRIPT+="lvextend -l +100%FREE /dev/${VG_NAME}/${LV_NAME}\n"

# Grow the filesystem
if [[ "$FILESYSTEM" == "xfs" ]]; then
    REMOTE_SCRIPT+="echo '--- Growing XFS filesystem on ${MOUNT_POINT} ---'\n"
    REMOTE_SCRIPT+="xfs_growfs ${MOUNT_POINT}\n"
elif [[ "$FILESYSTEM" == "ext4" ]]; then
    REMOTE_SCRIPT+="echo '--- Growing ext4 filesystem ---'\n"
    REMOTE_SCRIPT+="resize2fs /dev/${VG_NAME}/${LV_NAME}\n"
fi

# Verify
REMOTE_SCRIPT+="echo '--- Verification ---'\n"
REMOTE_SCRIPT+="df -hT ${MOUNT_POINT} && pvs && vgs && lvs\n"

printf '%b' "$REMOTE_SCRIPT" | ssh \
    -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    "${SSH_USER}@${VM_IP}" \
    "sudo bash -s"

echo ""
echo "====================================================================="
echo "  Resize complete."
echo "====================================================================="
