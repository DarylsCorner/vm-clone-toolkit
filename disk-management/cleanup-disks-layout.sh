#!/bin/bash
# =============================================================================
# cleanup-disks-layout.sh
# Reverses add-disks-layout.sh — unmounts filesystems, removes LVM config
# on the VM via SSH, then detaches and deletes the Azure managed disks.
#
# Usage:
#   ./cleanup-disks-layout.sh --instance <number>
#
# Required:
#   --instance    VM instance number (must match the value used during add)
#                 --instance 1  removes DDB1, DDB2, cache1, jobs1
#                 --instance 2  removes DDB3, DDB4, cache2, jobs2
#
# Parameters (same as add-disks-layout.sh - modify before running):
#   VM_NAME, RESOURCE_GROUP, VM_IP, SSH_KEY, SSH_USER
# =============================================================================

set -euo pipefail

# =============================================================================
# PARAMETERS - Modify these before running (same values as add-disks-layout.sh)
# =============================================================================

VM_NAME="<vm-name>"
RESOURCE_GROUP="<resource-group>"

# SSH connection to the VM
VM_IP="<vm-private-ip>"
SSH_KEY="~/.ssh/id_rsa"
SSH_USER="azureadm"

# =============================================================================
# Parse --instance flag
# =============================================================================
VM_INSTANCE=""

for arg in "$@"; do
    case $arg in
        --instance=*) VM_INSTANCE="${arg#*=}" ;;
        --instance)   shift; VM_INSTANCE="$1" ;;
    esac
done

if [[ -z "$VM_INSTANCE" ]]; then
    echo "ERROR: --instance is required"
    echo "  Usage: $0 --instance <number>"
    echo "  Example: $0 --instance 0   (removes DDB1, DDB2, cache0, jobs0)"
    echo "           $0 --instance 1   (removes DDB3, DDB4, cache1, jobs1)"
    exit 1
fi

# =============================================================================
# Derive disk names and VGs from instance number
# =============================================================================
DDB_START=$(( VM_INSTANCE * 2 + 1 ))
DDB_END=$(( DDB_START + 1 ))

DISKS=("DDB${DDB_START}" "DDB${DDB_END}" "cache${VM_INSTANCE}" "jobs${VM_INSTANCE}")
VGS=("vg_ddb01" "vg_indexcache" "vg_commvault")
MOUNTS=("/ddb01" "/indexcache" "/opt/commvault")

echo "======================================================================"
echo "  cleanup-disks-layout.sh"
echo "======================================================================"
echo "  VM:        ${VM_NAME}"
echo "  RG:        ${RESOURCE_GROUP}"
echo "  VM IP:     ${VM_IP}"
echo "  Instance:  ${VM_INSTANCE}"
echo "  Disks:     ${DISKS[*]}"
echo "  VGs:       ${VGS[*]}"
echo "======================================================================"

# =============================================================================
# Step 1: Clean up LVM and mounts on VM via SSH
# =============================================================================
echo ""
echo ">>> Connecting to ${VM_IP} to remove LVM and mounts..."

REMOTE_SCRIPT="set +e\n"

# Unmount filesystems
for MOUNT in "${MOUNTS[@]}"; do
    REMOTE_SCRIPT+="umount ${MOUNT} 2>/dev/null || true\n"
done

# Remove fstab entries
for MOUNT in "${MOUNTS[@]}"; do
    REMOTE_SCRIPT+="sed -i '\\| ${MOUNT} |d' /etc/fstab\n"
done

# Remove device-mapper devices
REMOTE_SCRIPT+="dmsetup remove_all 2>/dev/null || true\n"

# Remove LVs, VGs, PVs
for VG in "${VGS[@]}"; do
    REMOTE_SCRIPT+="lvremove -f -y /dev/${VG}/* 2>/dev/null || true\n"
    REMOTE_SCRIPT+="vgremove -f -y ${VG} 2>/dev/null || true\n"
done

# Wipe PV signatures from data disks (skip sda/sdb/sdc)
REMOTE_SCRIPT+="for dev in sdd sde sdf sdg sdh; do\n"
REMOTE_SCRIPT+="    [ -b /dev/\$dev ] && pvremove -ff -y /dev/\$dev 2>/dev/null || true\n"
REMOTE_SCRIPT+="done\n"

# Remove stale device node directories
for VG in "${VGS[@]}"; do
    REMOTE_SCRIPT+="rm -rf /dev/${VG} 2>/dev/null || true\n"
done

REMOTE_SCRIPT+="echo '--- LVM state after cleanup ---'\n"
REMOTE_SCRIPT+="pvs 2>/dev/null || echo 'No PVs'\n"
REMOTE_SCRIPT+="vgs 2>/dev/null || echo 'No VGs'\n"
REMOTE_SCRIPT+="grep -E 'ddb01|indexcache|commvault' /etc/fstab || echo 'fstab clean'\n"
REMOTE_SCRIPT+="echo 'VM cleanup done'\n"

printf '%b' "$REMOTE_SCRIPT" | ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "${SSH_USER}@${VM_IP}" \
    "sudo bash"

# =============================================================================
# Step 2: Detach and delete Azure disks
# =============================================================================
echo ""
echo ">>> Detaching and deleting Azure disks..."

for DISK in "${DISKS[@]}"; do
    echo ">>> Removing: ${DISK}"
    az vm disk detach \
        --vm-name "$VM_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DISK" \
        --output none 2>/dev/null || true
    az disk delete \
        --name "$DISK" \
        --resource-group "$RESOURCE_GROUP" \
        --yes \
        --no-wait \
        --output none 2>/dev/null || true
done

echo ""
echo "======================================================================"
echo "  Cleanup complete for instance ${VM_INSTANCE} on ${VM_NAME}"
echo "  Disks removed: ${DISKS[*]}"
echo "======================================================================"
