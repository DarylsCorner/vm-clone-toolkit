#!/bin/bash
# =============================================================================
# add-data-disks.sh
# Creates Azure managed disks, attaches to a Linux VM, creates PV/LV/filesystem
# and mounts with fstab persistence.
#
# Disk config format (one entry per disk):
#   "DISK_SUFFIX:SIZE_GB:LUN:CACHING:VG_NAME:LV_NAME:MOUNT_POINT"
#
# Caching values: ReadOnly | None | ReadWrite
#   ReadOnly  - recommended for data disks
#   None      - recommended for log/write-heavy disks
#   ReadWrite - OS disk only (avoid for data disks)
#
# For striped LVM (multiple disks -> one mount point), give them the SAME
# VG_NAME and MOUNT_POINT - the script will add all matching disks to that VG.
# =============================================================================

set -euo pipefail

# =============================================================================
# PARAMETERS - Modify these before running
# =============================================================================

VM_NAME="<vm-name>"
RESOURCE_GROUP="<resource-group>"
LOCATION="<location>"                     # e.g. swedencentral
DISK_SKU="Premium_LRS"
FILESYSTEM="xfs"

# SSH connection to the VM for automated LVM configuration
VM_IP="<vm-private-ip>"                   # Private IP of the VM
SSH_KEY="~/.ssh/id_rsa"                   # SSH private key path on the deployer
SSH_USER="azureadm"                        # SSH username

# -----------------------------------------------------------------------------
# Disk layout - based on target layout:
#   LUN 0 : DDB1  - 32 GiB  - database data (striped with DDB2)
#   LUN 1 : DDB2  - 32 GiB  - database data (striped with DDB1)
#   LUN 2 : cache - 32 GiB  - cache
#   LUN 3 : jobs  - 32 GiB  - jobs/work
#
# Format: "NAME_SUFFIX:SIZE_GB:LUN:CACHING:VG_NAME:LV_NAME:MOUNT_POINT"
# Disks sharing the same VG_NAME will be striped into one logical volume.
# -----------------------------------------------------------------------------
DISK_CONFIGS=(
    "DDB1:32:1:ReadOnly:vg_dbdata:lv_dbdata:/db/data"
    "DDB2:32:2:ReadOnly:vg_dbdata:lv_dbdata:/db/data"
    "cache:32:3:ReadOnly:vg_cache:lv_cache:/db/cache"
    "jobs:32:4:None:vg_jobs:lv_jobs:/db/work"
)

MOUNT_POINT="/data"                       # e.g. /hana/data, /usr/sap, /sapmnt
VG_NAME="vg_data"                         # LVM volume group name
LV_NAME="lv_data"                         # LVM logical volume name

# Optional: UltraSSD only - leave empty for Premium_LRS
DISK_IOPS_RW=""
DISK_MBPS_RW=""

# =============================================================================
# DO NOT MODIFY BELOW THIS LINE
# =============================================================================

echo "======================================================================"
echo "  Deploying disk layout for VM: ${VM_NAME} in ${RESOURCE_GROUP}"
echo "======================================================================"

# -----------------------------------------------------------------------------
# Step 1: Discover LUNs already in use on this VM
# -----------------------------------------------------------------------------
echo ">>> Checking existing LUN assignments on ${VM_NAME}..."
USED_LUNS=$(az vm show \
    --name "$VM_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "storageProfile.dataDisks[].lun" \
    --output tsv 2>/dev/null | tr '\n' ' ' || true)
echo ">>> LUNs already in use: ${USED_LUNS:-none}"

# Detect VM availability zone
VM_ZONE=$(az vm show \
    --name "$VM_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "zones[0]" \
    --output tsv 2>/dev/null || true)
[[ -n "$VM_ZONE" ]] && echo ">>> VM is in Availability Zone: ${VM_ZONE}" || echo ">>> VM is not zonal"

# Helper: find the next free LUN starting from a preferred value
next_free_lun() {
    local preferred=$1
    local candidate=$preferred
    while echo " $USED_LUNS " | grep -qw "$candidate"; do
        candidate=$(( candidate + 1 ))
    done
    echo "$candidate"
}

# Track assigned LUNs per disk (for use in on-VM script)
declare -A ASSIGNED_LUNS

# -----------------------------------------------------------------------------
# Step 2: Create and attach all disks
# -----------------------------------------------------------------------------
for config in "${DISK_CONFIGS[@]}"; do
    IFS=':' read -r DISK_SUFFIX SIZE_GB LUN CACHING VG LV MOUNT <<< "$config"
    DISK_NAME="${VM_NAME}-${DISK_SUFFIX}"

    # Find a free LUN (skips any already in use)
    FREE_LUN=$(next_free_lun "$LUN")
    if [[ "$FREE_LUN" != "$LUN" ]]; then
        echo ">>> LUN ${LUN} already in use — assigning LUN ${FREE_LUN} for ${DISK_NAME}"
    fi

    # Mark this LUN as used for subsequent disks
    USED_LUNS="$USED_LUNS $FREE_LUN"
    ASSIGNED_LUNS[$DISK_SUFFIX]=$FREE_LUN

    echo ""
    echo ">>> Creating: ${DISK_NAME} | ${SIZE_GB}GB | LUN ${FREE_LUN} | Caching: ${CACHING}"

    EXTRA_PARAMS=""
    [[ -n "$DISK_IOPS_RW" ]] && EXTRA_PARAMS="$EXTRA_PARAMS --disk-iops-read-write $DISK_IOPS_RW"
    [[ -n "$DISK_MBPS_RW" ]] && EXTRA_PARAMS="$EXTRA_PARAMS --disk-mbps-read-write $DISK_MBPS_RW"
    ZONE_PARAM=""
    [[ -n "$VM_ZONE" ]] && ZONE_PARAM="--zone $VM_ZONE"

    az disk create \
        --name "$DISK_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --location "$LOCATION" \
        --size-gb "$SIZE_GB" \
        --sku "$DISK_SKU" \
        --output none \
        $EXTRA_PARAMS \
        $ZONE_PARAM

    az vm disk attach \
        --vm-name "$VM_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DISK_NAME" \
        --lun "$FREE_LUN" \
        --caching "$CACHING" \
        --output none

    echo ">>> Attached: ${DISK_NAME} at LUN ${FREE_LUN}"
done

echo ""
echo "======================================================================"
echo "  All disks created and attached."
echo "  Waiting 15 seconds for OS to detect new disks..."
echo "======================================================================"
sleep 15

# -----------------------------------------------------------------------------
# Step 2: Build LVM commands and execute on VM via SSH
# -----------------------------------------------------------------------------
declare -A VG_DEVICES
declare -A VG_LV
declare -A VG_MOUNT

for config in "${DISK_CONFIGS[@]}"; do
    IFS=':' read -r DISK_SUFFIX SIZE_GB LUN CACHING VG LV MOUNT <<< "$config"
    ACTUAL_LUN="${ASSIGNED_LUNS[$DISK_SUFFIX]}"
    VG_DEVICES[$VG]+="/dev/disk/azure/scsi1/lun${ACTUAL_LUN} "
    VG_LV[$VG]="$LV"
    VG_MOUNT[$VG]="$MOUNT"
done

# Build remote script string
REMOTE_SCRIPT="set -e\n"
REMOTE_SCRIPT+="which pvcreate 2>/dev/null || apt-get install -y lvm2 || zypper install -y lvm2\n"

for VG in "${!VG_DEVICES[@]}"; do
    LV="${VG_LV[$VG]}"
    MOUNT="${VG_MOUNT[$VG]}"
    DEVS="${VG_DEVICES[$VG]}"
    REMOTE_SCRIPT+="echo '--- Configuring ${VG} -> ${MOUNT} ---'\n"
    REMOTE_SCRIPT+="DEVICES=\"${DEVS}\"\n"
    REMOTE_SCRIPT+="pvcreate \$DEVICES\n"
    REMOTE_SCRIPT+="vgcreate ${VG} \$DEVICES\n"
    REMOTE_SCRIPT+="lvcreate -l 100%FREE -n ${LV} ${VG}\n"
    REMOTE_SCRIPT+="mkfs.${FILESYSTEM} /dev/${VG}/${LV}\n"
    REMOTE_SCRIPT+="mkdir -p ${MOUNT}\n"
    REMOTE_SCRIPT+="UUID=\$(blkid -s UUID -o value /dev/${VG}/${LV})\n"
    REMOTE_SCRIPT+="if grep -q ' ${MOUNT} ' /etc/fstab; then\n"
    REMOTE_SCRIPT+="  echo 'WARNING: fstab entry for ${MOUNT} already exists - skipping fstab update'\n"
    REMOTE_SCRIPT+="else\n"
    REMOTE_SCRIPT+="  echo \"UUID=\${UUID}  ${MOUNT}  ${FILESYSTEM}  defaults,nofail  0  2\" >> /etc/fstab\n"
    REMOTE_SCRIPT+="fi\n"
done

REMOTE_SCRIPT+="mount -a\n"
REMOTE_SCRIPT+="echo '--- Verification ---'\n"
REMOTE_SCRIPT+="df -hT && pvs && vgs && lvs\n"

echo ""
echo "====================================================================="
echo "  Connecting to ${VM_IP} and configuring LVM..."
echo "====================================================================="

printf '%b' "$REMOTE_SCRIPT" | ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "${SSH_USER}@${VM_IP}" \
    "sudo bash"

echo ""
echo "====================================================================="
echo "  Complete. Disks configured on ${VM_NAME} (${VM_IP})"
echo "====================================================================="
