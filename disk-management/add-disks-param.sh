#!/bin/bash
# =============================================================================
# add-data-disks-param.sh
# Flexible disk addition script - all options configurable via CLI parameters.
# All disks in a single run share the same size, SKU and caching, and are
# striped into one LVM volume group.
#
# Usage:
#   ./add-data-disks-param.sh [OPTIONS]
#
# Required:
#   --vm          VM name
#   --rg          Resource group
#   --location    Azure region (e.g. swedencentral)
#   --ip          Private IP of the VM
#
# Optional:
#   --count       Number of disks to add (default: 2)
#   --size        Disk size in GB (default: 512)
#   --sku         Disk SKU (default: Premium_LRS)
#   --caching     Disk caching: ReadOnly | None | ReadWrite (default: ReadOnly)
#   --mount       Mount point (default: /data)
#   --vg          LVM volume group name (default: vg_data)
#   --lv          LVM logical volume name (default: lv_data)
#   --fs          Filesystem: xfs | ext4 (default: xfs)
#   --suffix      Disk name suffix prefix (default: datadisk)
#   --lun-start   Preferred starting LUN (default: 0, auto-skips used LUNs)
#   --key         SSH private key path (default: ~/.ssh/id_rsa)
#   --user        SSH username (default: azureadm)
#   --iops        Disk IOPS (UltraSSD only)
#   --mbps        Disk MB/s throughput (UltraSSD only)
#   --dry-run     Print what would be done without making changes
#   -h, --help    Show this help
#
# Examples:
#   # Add 2x512GB data disks to an app server
#   ./add-data-disks-param.sh --vm <vm-name> --rg <resource-group> \
#     --location <region> --ip <vm-private-ip> --mount /usr/sap
#
#   # Add 4x1TB striped HANA data disks
#   ./add-data-disks-param.sh --vm <db-vm-name> --rg <resource-group> \
#     --location <region> --ip <vm-private-ip> \
#     --count 4 --size 1024 --mount /hana/data --vg vg_hana_data --lv lv_hana_data
#
#   # Add 2x512GB log disks (no caching for log)
#   ./add-data-disks-param.sh --vm <db-vm-name> --rg <resource-group> \
#     --location <region> --ip <vm-private-ip> \
#     --count 2 --size 512 --caching None --mount /hana/log \
#     --vg vg_hana_log --lv lv_hana_log --suffix hanalog --lun-start 10
# =============================================================================

set -euo pipefail

# =============================================================================
# Defaults
# =============================================================================
VM_NAME=""
RESOURCE_GROUP=""
LOCATION=""
VM_IP=""
DISK_COUNT=2
DISK_SIZE_GB=512
DISK_SKU="Premium_LRS"
DISK_CACHING="ReadOnly"
MOUNT_POINT="/data"
VG_NAME="vg_data"
LV_NAME="lv_data"
FILESYSTEM="xfs"
DISK_SUFFIX="datadisk"
LUN_START=0
SSH_KEY="~/.ssh/id_rsa"
SSH_USER="azureadm"
DISK_IOPS_RW=""
DISK_MBPS_RW=""
DRY_RUN=false

# =============================================================================
# Parse arguments
# =============================================================================
usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm)        VM_NAME="$2";        shift 2 ;;
        --rg)        RESOURCE_GROUP="$2"; shift 2 ;;
        --location)  LOCATION="$2";       shift 2 ;;
        --ip)        VM_IP="$2";          shift 2 ;;
        --count)     DISK_COUNT="$2";     shift 2 ;;
        --size)      DISK_SIZE_GB="$2";   shift 2 ;;
        --sku)       DISK_SKU="$2";       shift 2 ;;
        --caching)   DISK_CACHING="$2";   shift 2 ;;
        --mount)     MOUNT_POINT="$2";    shift 2 ;;
        --vg)        VG_NAME="$2";        shift 2 ;;
        --lv)        LV_NAME="$2";        shift 2 ;;
        --fs)        FILESYSTEM="$2";     shift 2 ;;
        --suffix)    DISK_SUFFIX="$2";    shift 2 ;;
        --lun-start) LUN_START="$2";      shift 2 ;;
        --key)       SSH_KEY="$2";        shift 2 ;;
        --user)      SSH_USER="$2";       shift 2 ;;
        --iops)      DISK_IOPS_RW="$2";   shift 2 ;;
        --mbps)      DISK_MBPS_RW="$2";   shift 2 ;;
        --dry-run)   DRY_RUN=true;        shift   ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# =============================================================================
# Validate required parameters
# =============================================================================
ERRORS=()
[[ -z "$VM_NAME" ]]        && ERRORS+=("--vm is required")
[[ -z "$RESOURCE_GROUP" ]] && ERRORS+=("--rg is required")
[[ -z "$LOCATION" ]]       && ERRORS+=("--location is required")
[[ -z "$VM_IP" ]]          && ERRORS+=("--ip is required")

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: Missing required parameters:"
    for e in "${ERRORS[@]}"; do echo "  $e"; done
    echo ""
    echo "Run with --help for usage."
    exit 1
fi

# =============================================================================
# Summary
# =============================================================================
echo "======================================================================"
echo "  add-data-disks-param.sh"
echo "======================================================================"
echo "  VM:           ${VM_NAME}"
echo "  Resource RG:  ${RESOURCE_GROUP}"
echo "  Location:     ${LOCATION}"
echo "  VM IP:        ${VM_IP}"
echo "  Disks:        ${DISK_COUNT} x ${DISK_SIZE_GB}GB ${DISK_SKU}"
echo "  Caching:      ${DISK_CACHING}"
echo "  LUN start:    ${LUN_START} (auto-skips used LUNs)"
echo "  Mount point:  ${MOUNT_POINT}"
echo "  VG / LV:      ${VG_NAME} / ${LV_NAME}"
echo "  Filesystem:   ${FILESYSTEM}"
echo "  Dry run:      ${DRY_RUN}"
echo "======================================================================"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "DRY RUN — no changes will be made."
fi

# =============================================================================
# Discover used LUNs
# =============================================================================
echo ""
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

next_free_lun() {
    local candidate=$1
    while echo " $USED_LUNS " | grep -qw "$candidate"; do
        candidate=$(( candidate + 1 ))
    done
    echo "$candidate"
}

# =============================================================================
# Create and attach disks
# =============================================================================
ASSIGNED_LUNS=()
CURRENT_LUN=$LUN_START

for i in $(seq 1 "$DISK_COUNT"); do
    DISK_NAME="${VM_NAME}-${DISK_SUFFIX}-$(printf '%02d' "$i")"
    FREE_LUN=$(next_free_lun "$CURRENT_LUN")

    [[ "$FREE_LUN" != "$CURRENT_LUN" ]] && \
        echo ">>> LUN ${CURRENT_LUN} in use — using LUN ${FREE_LUN} for ${DISK_NAME}"

    USED_LUNS="$USED_LUNS $FREE_LUN"
    ASSIGNED_LUNS+=("$FREE_LUN")
    CURRENT_LUN=$(( FREE_LUN + 1 ))

    echo ""
    echo ">>> Creating: ${DISK_NAME} | ${DISK_SIZE_GB}GB | LUN ${FREE_LUN} | Caching: ${DISK_CACHING}"

    EXTRA_PARAMS=""
    [[ -n "$DISK_IOPS_RW" ]] && EXTRA_PARAMS="$EXTRA_PARAMS --disk-iops-read-write $DISK_IOPS_RW"
    [[ -n "$DISK_MBPS_RW" ]] && EXTRA_PARAMS="$EXTRA_PARAMS --disk-mbps-read-write $DISK_MBPS_RW"

    if [[ "$DRY_RUN" == "false" ]]; then
        ZONE_PARAM=""
        [[ -n "$VM_ZONE" ]] && ZONE_PARAM="--zone $VM_ZONE"

        az disk create \
            --name "$DISK_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --location "$LOCATION" \
            --size-gb "$DISK_SIZE_GB" \
            --sku "$DISK_SKU" \
            --output none \
            $EXTRA_PARAMS \
            $ZONE_PARAM

        az vm disk attach \
            --vm-name "$VM_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            --name "$DISK_NAME" \
            --lun "$FREE_LUN" \
            --caching "$DISK_CACHING" \
            --output none

        echo ">>> Attached: ${DISK_NAME} at LUN ${FREE_LUN}"
    else
        echo ">>> [DRY RUN] Would create and attach: ${DISK_NAME} at LUN ${FREE_LUN}"
    fi
done

[[ "$DRY_RUN" == "true" ]] && echo "" && echo "Dry run complete." && exit 0

echo ""
echo "======================================================================"
echo "  All disks attached. Waiting 15 seconds for OS detection..."
echo "======================================================================"
sleep 15

# =============================================================================
# Build and execute LVM commands on VM via SSH
# =============================================================================

# Build device list from assigned LUNs
DEVICE_LIST=""
for lun in "${ASSIGNED_LUNS[@]}"; do
    DEVICE_LIST+="/dev/disk/azure/scsi1/lun${lun} "
done

REMOTE_SCRIPT="set -e\n"
REMOTE_SCRIPT+="which pvcreate 2>/dev/null || apt-get install -y lvm2 || zypper install -y lvm2\n"
REMOTE_SCRIPT+="echo '--- Configuring ${VG_NAME} -> ${MOUNT_POINT} ---'\n"
REMOTE_SCRIPT+="DEVICES=\"${DEVICE_LIST}\"\n"
REMOTE_SCRIPT+="pvcreate \$DEVICES\n"
REMOTE_SCRIPT+="vgcreate ${VG_NAME} \$DEVICES\n"
REMOTE_SCRIPT+="lvcreate -l 100%FREE -n ${LV_NAME} ${VG_NAME}\n"
REMOTE_SCRIPT+="mkfs.${FILESYSTEM} /dev/${VG_NAME}/${LV_NAME}\n"
REMOTE_SCRIPT+="mkdir -p ${MOUNT_POINT}\n"
REMOTE_SCRIPT+="UUID=\$(blkid -s UUID -o value /dev/${VG_NAME}/${LV_NAME})\n"
REMOTE_SCRIPT+="if grep -q ' ${MOUNT_POINT} ' /etc/fstab; then\n"
REMOTE_SCRIPT+="  echo 'WARNING: fstab entry for ${MOUNT_POINT} already exists - skipping fstab update'\n"
REMOTE_SCRIPT+="else\n"
REMOTE_SCRIPT+="  echo \"UUID=\${UUID}  ${MOUNT_POINT}  ${FILESYSTEM}  defaults,nofail  0  2\" >> /etc/fstab\n"
REMOTE_SCRIPT+="fi\n"
REMOTE_SCRIPT+="mount -a\n"
REMOTE_SCRIPT+="echo '--- Verification ---'\n"
REMOTE_SCRIPT+="df -hT ${MOUNT_POINT} && pvs && vgs && lvs\n"

echo ""
echo "======================================================================"
echo "  Connecting to ${VM_IP} and configuring LVM..."
echo "======================================================================"

printf '%b' "$REMOTE_SCRIPT" | ssh -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=30 \
    "${SSH_USER}@${VM_IP}" \
    "sudo bash"

echo ""
echo "======================================================================"
echo "  Complete: ${DISK_COUNT}x${DISK_SIZE_GB}GB mounted at ${MOUNT_POINT} on ${VM_NAME}"
echo "======================================================================"
