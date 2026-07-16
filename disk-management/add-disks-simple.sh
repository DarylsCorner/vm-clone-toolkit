#!/bin/bash
# =============================================================================
# add-disks-simple.sh
# Creates and attaches one or more Azure managed disks to a Linux VM.
# No LVM, no SSH — just raw disk creation and attachment.
# Use this for quick provisioning when the OS/application will handle
# the disk configuration itself (e.g. via Ansible, cloud-init, or manually).
#
# Usage:
#   ./add-disks-simple.sh --vm <name> --rg <rg> --location <loc> [OPTIONS]
#
# Required:
#   --vm          VM name
#   --rg          Resource group
#   --location    Azure region (e.g. swedencentral)
#
# Optional:
#   --count       Number of disks to create (default: 1)
#   --size        Disk size in GB (default: 128)
#   --sku         Disk SKU: Premium_LRS | StandardSSD_LRS | UltraSSD_LRS (default: Premium_LRS)
#   --caching     Disk caching: ReadOnly | None | ReadWrite (default: ReadOnly)
#   --name        Disk name prefix (default: <vm-name>-disk)
#   --lun-start   Starting LUN number (default: 0, auto-skips used LUNs)
#   --dry-run     Show what would be created without making changes
#   -h, --help    Show this help
#
# Examples:
#   # Add a single 256GB disk
#   ./add-disks-simple.sh --vm myvm --rg my-rg --location swedencentral --size 256
#
#   # Add 3x512GB disks named backup-01, backup-02, backup-03
#   ./add-disks-simple.sh --vm myvm --rg my-rg --location swedencentral \
#     --count 3 --size 512 --name backup
#
#   # Add 2 log disks with no caching, starting at LUN 10
#   ./add-disks-simple.sh --vm myvm --rg my-rg --location swedencentral \
#     --count 2 --size 512 --caching None --name hanalog --lun-start 10
# =============================================================================

set -euo pipefail

# =============================================================================
# Defaults
# =============================================================================
VM_NAME=""
RESOURCE_GROUP=""
LOCATION=""
DISK_COUNT=1
DISK_SIZE_GB=128
DISK_SKU="Premium_LRS"
DISK_CACHING="ReadOnly"
DISK_NAME_PREFIX=""
LUN_START=0
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
        --vm)        VM_NAME="$2";          shift 2 ;;
        --rg)        RESOURCE_GROUP="$2";   shift 2 ;;
        --location)  LOCATION="$2";         shift 2 ;;
        --count)     DISK_COUNT="$2";       shift 2 ;;
        --size)      DISK_SIZE_GB="$2";     shift 2 ;;
        --sku)       DISK_SKU="$2";         shift 2 ;;
        --caching)   DISK_CACHING="$2";     shift 2 ;;
        --name)      DISK_NAME_PREFIX="$2"; shift 2 ;;
        --lun-start) LUN_START="$2";        shift 2 ;;
        --dry-run)   DRY_RUN=true;          shift   ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# =============================================================================
# Validate
# =============================================================================
ERRORS=()
[[ -z "$VM_NAME" ]]        && ERRORS+=("--vm is required")
[[ -z "$RESOURCE_GROUP" ]] && ERRORS+=("--rg is required")
[[ -z "$LOCATION" ]]       && ERRORS+=("--location is required")

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: Missing required parameters:"
    for e in "${ERRORS[@]}"; do echo "  $e"; done
    echo "Run with --help for usage."
    exit 1
fi

# Default disk name prefix to vm name if not set
[[ -z "$DISK_NAME_PREFIX" ]] && DISK_NAME_PREFIX="${VM_NAME}-disk"

# =============================================================================
# Summary
# =============================================================================
echo "======================================================================"
echo "  add-disks-simple.sh"
echo "======================================================================"
echo "  VM:         ${VM_NAME}"
echo "  RG:         ${RESOURCE_GROUP}"
echo "  Location:   ${LOCATION}"
echo "  Disks:      ${DISK_COUNT} x ${DISK_SIZE_GB}GB ${DISK_SKU}"
echo "  Caching:    ${DISK_CACHING}"
echo "  Name:       ${DISK_NAME_PREFIX}-01 .. $(printf '%02d' "$DISK_COUNT")"
echo "  LUN start:  ${LUN_START} (auto-skips used LUNs)"
echo "  Dry run:    ${DRY_RUN}"
echo "======================================================================"

[[ "$DRY_RUN" == "true" ]] && echo "" && echo "DRY RUN — no changes will be made."

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

# Detect VM availability zone (empty if not zonal)
VM_ZONE=$(az vm show \
    --name "$VM_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query "zones[0]" \
    --output tsv 2>/dev/null || true)
if [[ -n "$VM_ZONE" ]]; then
    echo ">>> VM is in Availability Zone: ${VM_ZONE}"
else
    echo ">>> VM is not zonal (no zone constraint on disks)"
fi

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
CURRENT_LUN=$LUN_START

for i in $(seq 1 "$DISK_COUNT"); do
    DISK_NAME="${DISK_NAME_PREFIX}-$(printf '%02d' "$i")"
    FREE_LUN=$(next_free_lun "$CURRENT_LUN")

    [[ "$FREE_LUN" != "$CURRENT_LUN" ]] && \
        echo ">>> LUN ${CURRENT_LUN} in use — using LUN ${FREE_LUN}"

    USED_LUNS="$USED_LUNS $FREE_LUN"
    CURRENT_LUN=$(( FREE_LUN + 1 ))

    echo ""
    echo ">>> Disk: ${DISK_NAME} | ${DISK_SIZE_GB}GB | ${DISK_SKU} | LUN ${FREE_LUN} | Caching: ${DISK_CACHING}"

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
        echo ">>> [DRY RUN] Would create disk ${DISK_NAME} and attach at LUN ${FREE_LUN}"
    fi
done

echo ""
echo "======================================================================"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "  Dry run complete. No disks were created."
else
    echo "  Done. ${DISK_COUNT} disk(s) attached to ${VM_NAME}."
    echo ""
    echo "  To verify on the VM:"
    echo "    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT"
    echo "    ls -la /dev/disk/azure/scsi1/"
fi
echo "======================================================================"
