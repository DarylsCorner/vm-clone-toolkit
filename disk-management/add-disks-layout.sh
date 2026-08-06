#!/bin/bash
# =============================================================================
# add-data-disks.sh
# Creates Azure managed disks, attaches to a Linux VM, creates PV/LV/filesystem
# and mounts with fstab persistence.
#
# Disk config format (one entry per disk):
#   "DISK_SUFFIX:SIZE_GB:LUN:CACHING:VG_NAME:LV_NAME:MOUNT_POINT[:LV_PCT]"
#
# Caching values: ReadOnly | None | ReadWrite
#   ReadOnly  - recommended for data disks
#   None      - recommended for log/write-heavy disks
#   ReadWrite - OS disk only (avoid for data disks)
#
# LV_PCT (optional, default: 100): percentage of VG free space to allocate
#   to the logical volume. Set below 100 to leave headroom in the VG.
#   Example: 85 creates an LV using 85%FREE, leaving ~15% free in the VG.
#
# For striped LVM (multiple disks -> one mount point), give them the SAME
# VG_NAME and MOUNT_POINT - the script will add all matching disks to that VG.
# =============================================================================

set -euo pipefail

# =============================================================================
# PARAMETERS - Modify these before running
# =============================================================================

VM_NAME="VM-name"
RESOURCE_GROUP="RG-name"
LOCATION="swedencentral"                     # e.g. swedencentral
DISK_SKU="Premium_LRS"
FILESYSTEM="xfs"

# SSH connection to the VM for automated LVM configuration
VM_IP="add-your-IP"                   # Private IP of the VM
SSH_KEY="add-your-key"                   # SSH private key path on the deployer
SSH_USER="azureadm"                        # SSH username

# VM_INSTANCE is set via --instance flag at runtime (required)
# Do NOT hardcode - must be passed explicitly to avoid naming conflicts
#   --instance 0  ->  DDB1, DDB2, cache0, jobs0
#   --instance 1  ->  DDB3, DDB4, cache1, jobs1
#   --instance 2  ->  DDB5, DDB6, cache2, jobs2
VM_INSTANCE=""

# Parse --instance flag
for arg in "$@"; do
    case $arg in
        --instance=*) VM_INSTANCE="${arg#*=}" ;;
        --instance)   shift; VM_INSTANCE="$1" ;;
    esac
done

if [[ -z "$VM_INSTANCE" ]]; then
    echo "ERROR: --instance is required"
    echo "  Usage: $0 --instance <number>"
    echo "  Example: $0 --instance 0   (DDB1, DDB2, cache0, jobs0)"
    echo "           $0 --instance 1   (DDB3, DDB4, cache1, jobs1)"
    exit 1
fi

# -----------------------------------------------------------------------------
# Disk layout - Commvault MediaAgent
#   DDB disks: DDB{VM_INSTANCE*2+1} and DDB{VM_INSTANCE*2+2}  -> /ddb01 (striped, 85%FREE, 2x1250GB = ~2.1TB usable)
#   cache disk: cache{VM_INSTANCE}                             -> /indexcache
#   jobs disk:  jobs{VM_INSTANCE}                              -> /opt/commvault
#
# Format: "NAME_SUFFIX:SIZE_GB:LUN:CACHING:VG_NAME:LV_NAME:MOUNT_POINT[:LV_PCT]"
# Disks sharing the same VG_NAME will be striped into one logical volume.
# LV_PCT defaults to 100 if omitted. Set to 85 to leave >=15% free in the VG.
# -----------------------------------------------------------------------------
DDB_START=$(( VM_INSTANCE * 2 + 1 ))
DDB_END=$(( DDB_START + 1 ))

DISK_CONFIGS=(
    "DDB${DDB_START}:1250:1:None:vg_ddb01:lv_ddb01:/ddb01:85"
    "DDB${DDB_END}:1250:2:None:vg_ddb01:lv_ddb01:/ddb01:85"
    "cache${VM_INSTANCE}:2048:3:None:vg_indexcache:lv_indexcache:/indexcache:100"
    "jobs${VM_INSTANCE}:128:4:ReadOnly:vg_commvault:lv_commvault:/opt/commvault:100"
)

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
    DISK_NAME="${DISK_SUFFIX}"

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
declare -A VG_LVPCT

for config in "${DISK_CONFIGS[@]}"; do
    IFS=':' read -r DISK_SUFFIX SIZE_GB LUN CACHING VG LV MOUNT LV_PCT <<< "$config"
    ACTUAL_LUN="${ASSIGNED_LUNS[$DISK_SUFFIX]}"
    VG_DEVICES[$VG]+="/dev/disk/azure/scsi1/lun${ACTUAL_LUN} "
    VG_LV[$VG]="$LV"
    VG_MOUNT[$VG]="$MOUNT"
    VG_LVPCT[$VG]="${LV_PCT:-100}"
done

# Build remote script string
REMOTE_SCRIPT="set -e\n"
REMOTE_SCRIPT+="which pvcreate 2>/dev/null || apt-get install -y lvm2 || zypper install -y lvm2\n"

for VG in "${!VG_DEVICES[@]}"; do
    LV="${VG_LV[$VG]}"
    MOUNT="${VG_MOUNT[$VG]}"
    DEVS="${VG_DEVICES[$VG]}"
    LVPCT="${VG_LVPCT[$VG]}"
    REMOTE_SCRIPT+="echo '--- Configuring ${VG} -> ${MOUNT} (LV size: ${LVPCT}%FREE) ---'\n"
    REMOTE_SCRIPT+="DEVICES=\"${DEVS}\"\n"
    REMOTE_SCRIPT+="pvcreate \$DEVICES\n"
    REMOTE_SCRIPT+="vgcreate ${VG} \$DEVICES\n"
    REMOTE_SCRIPT+="lvcreate -l ${LVPCT}%FREE -n ${LV} ${VG}\n"
    REMOTE_SCRIPT+="mkfs.${FILESYSTEM} /dev/${VG}/${LV}\n"
    REMOTE_SCRIPT+="mkdir -p ${MOUNT}\n"
    REMOTE_SCRIPT+="if grep -q ' ${MOUNT} ' /etc/fstab; then\n"
    REMOTE_SCRIPT+="  echo 'WARNING: fstab entry for ${MOUNT} already exists - skipping fstab update'\n"
    REMOTE_SCRIPT+="else\n"
    REMOTE_SCRIPT+="  echo \"/dev/mapper/${VG}-${LV}  ${MOUNT}  ${FILESYSTEM}  defaults,_netdev  0  0\" >> /etc/fstab\n"
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
