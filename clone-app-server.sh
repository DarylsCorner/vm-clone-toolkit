#!/usr/bin/env bash
set -euo pipefail

# Suppress Azure CLI warnings for cleaner output
export AZURE_CORE_ONLY_SHOW_ERRORS=true

# Color codes for better readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#############################################
# clone-app-server.sh
#
# Clone an existing Azure Linux VM (e.g., SLES 15 app server),
# including OS disk + all data disks, into a new VM.
#
# Features:
#  - Online snapshots (no shutdown/detach)
#  - Picks the next available private IP in the subnet and assigns it STATIC
#  - Clones and re-attaches data disks at the same LUNs and caching settings
#  - Preserves accelerated networking settings
#  - Matches source VM resource naming patterns
#  - Automatically installs MonitorX64Linux extension if present on source
#  - Automatically sets hostname inside guest to match new VM name (can be disabled)
#  - Saves metadata to a JSON log file (includes shared-disk safety gate result)
#
# Safety:
#  - Aborts if any attached data disk is a Shared Disk (maxShares >= 2)
#
# Requirements:
#   - Azure CLI (az) installed and logged in (az login)
#   - jq installed
#   - python3 installed (used to calculate next available IP)
#
# Usage:
#   Single VM:
#     ./clone-app-server.sh <source-rg> <source-vm-name> <new-vm-name> \
#       [target-rg] [location] [vm-size] [set-hostname] [log-dir]
#   
#   Multiple VMs:
#     ./clone-app-server.sh <source-rg> <source-vm-name> --multi "vm1 vm2 vm3" \
#       [target-rg] [location] [vm-size] [set-hostname] [log-dir]
#
# Examples:
#   ./clone-app-server.sh RG-EASTUS sapdl1app01 sapdl1app02
#   ./clone-app-server.sh RG-EASTUS sapdl1app01 --multi "app02 app03 app04"
#   ./clone-app-server.sh app-rg appvm01 appvm02-clone app-rg westus2 Standard_D4s_v5 true ./logs
#############################################

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is required."; exit 1; }; }
need az
need jq
need python3

# Parse arguments
if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <source-rg> <source-vm-name> <new-vm-name|--multi \"vm1 vm2 ...\"> [target-rg] [location] [vm-size] [set-hostname] [log-dir]"
  exit 1
fi

SOURCE_RG="$1"
SOURCE_VM_NAME="$2"

# Check if multi-instance mode
MULTI_MODE=false
declare -a TARGET_VM_NAMES=()

if [[ "$3" == "--multi" ]]; then
  MULTI_MODE=true
  if [[ -z "$4" ]]; then
    echo "ERROR: --multi requires a space-separated list of VM names"
    exit 1
  fi
  # Parse VM names from quoted string
  read -ra TARGET_VM_NAMES <<< "$4"
  
  # Validate VM names
  if [[ ${#TARGET_VM_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: No VM names provided for multi-instance mode"
    exit 1
  fi
  
  # Check for duplicate names
  declare -A seen_names=()
  for vm_name in "${TARGET_VM_NAMES[@]}"; do
    if [[ -n "${seen_names[$vm_name]:-}" ]]; then
      echo "ERROR: Duplicate VM name detected: $vm_name"
      exit 1
    fi
    seen_names[$vm_name]=1
  done
  
  shift 2  # Skip --multi and the name list
else
  TARGET_VM_NAMES=("$3")
fi

# Normalize VM names: if short names provided (e.g., "app02"), construct full names
# by extracting the base prefix from source VM name
declare -a NORMALIZED_VM_NAMES=()
if [[ "$SOURCE_VM_NAME" =~ ^(.+)(app[0-9]+)$ ]]; then
  VM_PREFIX="${BASH_REMATCH[1]}"  # e.g., "sapdl1"
  for vm_name in "${TARGET_VM_NAMES[@]}"; do
    # If the name doesn't contain the prefix, add it
    if [[ ! "$vm_name" =~ ^${VM_PREFIX} ]]; then
      NORMALIZED_VM_NAMES+=("${VM_PREFIX}${vm_name}")
    else
      NORMALIZED_VM_NAMES+=("$vm_name")
    fi
  done
  TARGET_VM_NAMES=("${NORMALIZED_VM_NAMES[@]}")
fi

# Display mode information
if $MULTI_MODE; then
  echo -e "${CYAN}Multi-instance mode: Creating ${#TARGET_VM_NAMES[@]} VMs${NC}"
  echo -e "${CYAN}Target VMs: ${TARGET_VM_NAMES[*]}${NC}"
else
  echo -e "${CYAN}Single-instance mode: Creating 1 VM${NC}"
fi

TARGET_RG="${4:-$SOURCE_RG}"

echo "Fetching source VM details..."
VM_JSON=$(az vm show -g "$SOURCE_RG" -n "$SOURCE_VM_NAME" -o json)

LOCATION="${5:-$(echo "$VM_JSON" | jq -r '.location')}"
VM_SIZE_DEFAULT=$(echo "$VM_JSON" | jq -r '.hardwareProfile.vmSize')
VM_SIZE="${6:-$VM_SIZE_DEFAULT}"
SET_HOSTNAME="${7:-true}"
LOG_DIR="${8:-.}"

mkdir -p "$LOG_DIR"

TS=$(date +%Y%m%d%H%M%S)
START_TIME=$(date +%s)

# Availability Zone info
SOURCE_AVAILABILITY_ZONE=$(echo "$VM_JSON" | jq -r '.zones[0] // ""')

# For multi-instance mode, prepare zone rotation
if $MULTI_MODE && [[ -n "$SOURCE_AVAILABILITY_ZONE" ]]; then
  # Determine available zones for round-robin (zones 1 and 3 for better availability)
  if [[ "$SOURCE_AVAILABILITY_ZONE" == "1" ]]; then
    ZONE_ROTATION=("1" "3")
  elif [[ "$SOURCE_AVAILABILITY_ZONE" == "3" ]]; then
    ZONE_ROTATION=("3" "1")
  else
    # If source is zone 2, rotate between 2 and 1
    ZONE_ROTATION=("$SOURCE_AVAILABILITY_ZONE" "1")
  fi
  echo -e "${CYAN}Zone rotation enabled: ${ZONE_ROTATION[*]} (alternating)${NC}"
else
  AVAILABILITY_ZONE="$SOURCE_AVAILABILITY_ZONE"
fi

# License type
LICENSE_TYPE=$(echo "$VM_JSON" | jq -r '.licenseType // ""')

# OS disk info
OS_DISK_NAME=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.name')
OS_DISK_ID=$(echo "$VM_JSON" | jq -r '.storageProfile.osDisk.managedDisk.id')

# Data disks info
DATA_DISKS_JSON=$(echo "$VM_JSON" | jq -c '.storageProfile.dataDisks // []')
DATA_DISK_COUNT=$(echo "$DATA_DISKS_JSON" | jq 'length')

# Check for shared disks
SHARED_DISK_CHECK=$(echo "$DATA_DISKS_JSON" | jq -r '.[] | select(.managedDisk.id != null) | .managedDisk.id' | while read -r disk_id; do
  if [[ -n "$disk_id" ]]; then
    DISK_SHARED=$(az disk show --ids "$disk_id" --query "maxShares" -o tsv 2>/dev/null || echo "1")
    if [[ "$DISK_SHARED" -gt 1 ]]; then
      echo "SHARED"
      break
    fi
  fi
done)

if [[ "$SHARED_DISK_CHECK" == "SHARED" ]]; then
  echo "ERROR: Source VM has one or more shared disks attached. Cloning VMs with shared disks is not supported."
  exit 1
fi

# NIC/subnet/NSG info
NIC_ID=$(echo "$VM_JSON" | jq -r '.networkProfile.networkInterfaces[0].id')
NIC_JSON=$(az network nic show --ids "$NIC_ID" -o json)
SOURCE_NIC_NAME=$(echo "$NIC_JSON" | jq -r '.name')
SUBNET_ID=$(echo "$NIC_JSON" | jq -r '.ipConfigurations[0].subnet.id')
NSG_ID=$(echo "$NIC_JSON" | jq -r '.networkSecurityGroup.id // empty')
ACCELERATED_NETWORKING=$(echo "$NIC_JSON" | jq -r '.enableAcceleratedNetworking // false')

# Store source NIC name for pattern matching later (in loop)
NIC_NAME="$SOURCE_NIC_NAME"

SUBNET_RG=$(echo "$SUBNET_ID" | awk -F/ '{for(i=1;i<=NF;i++) if($i=="resourceGroups"){print $(i+1); exit}}')
SUBNET_NAME=$(echo "$SUBNET_ID" | awk -F/ '{print $NF}')
VNET_NAME=$(echo "$SUBNET_ID" | awk -F/ '{for(i=1;i<=NF;i++) if($i=="virtualNetworks"){print $(i+1); exit}}')

echo "Source VM:"
echo "  RG            : $SOURCE_RG"
echo "  Name          : $SOURCE_VM_NAME"
echo "  Location      : $LOCATION"
echo "  Size          : $VM_SIZE"
echo "  OS Disk       : $OS_DISK_NAME"
echo "  Data Disks    : $DATA_DISK_COUNT"
echo "  Subnet        : $VNET_NAME/$SUBNET_NAME (RG: $SUBNET_RG)"
[[ -n "$NSG_ID" ]] && echo "  NSG           : $NSG_ID"
echo "  Log directory : $LOG_DIR"
echo

#############################################
# Safety gate: abort if any shared disk is attached
#############################################
SHARED_DISK_CHECK="passed"
SHARED_DISK_FINDINGS="[]"

if [[ "$DATA_DISK_COUNT" -gt 0 ]]; then
  echo -e "${BLUE}Running shared-disk safety check (maxShares >= 2)...${NC}"

  while IFS= read -r d; do
    DISK_ID=$(echo "$d" | jq -r '.managedDisk.id')
    DISK_NAME=$(echo "$d" | jq -r '.name')
    LUN=$(echo "$d" | jq -r '.lun')

    MAX_SHARES=$(az disk show --ids "$DISK_ID" --query "shareInfo.maxShares" -o tsv 2>/dev/null || true)
    MAX_SHARES="${MAX_SHARES:-0}"

    # Record the finding for logging
    SHARED_DISK_FINDINGS=$(echo "$SHARED_DISK_FINDINGS" | jq \
      --arg diskName "$DISK_NAME" \
      --arg diskId "$DISK_ID" \
      --arg lun "$LUN" \
      --arg maxShares "$MAX_SHARES" \
      '. + [{"diskName": $diskName, "diskId": $diskId, "lun": ($lun|tonumber), "maxShares": ($maxShares|tonumber)}]'
    )

    if [[ "$MAX_SHARES" =~ ^[0-9]+$ ]] && (( MAX_SHARES >= 2 )); then
      SHARED_DISK_CHECK="failed"
      echo "ERROR: Shared disk detected!"
      echo "  VM        : $SOURCE_VM_NAME"
      echo "  Disk      : $DISK_NAME"
      echo "  LUN       : $LUN"
      echo "  maxShares : $MAX_SHARES"
      echo "Aborting clone to avoid copying shared-disk/cluster state."

      jq -n \
        --arg timestamp "$TS" \
        --arg sourceRg "$SOURCE_RG" \
        --arg sourceVm "$SOURCE_VM_NAME" \
        --arg targetRg "$TARGET_RG" \
        --arg newVm "$NEW_VM_NAME" \
        --arg sharedDiskCheck "$SHARED_DISK_CHECK" \
        --argjson sharedDiskFindings "$SHARED_DISK_FINDINGS" \
      '{
        timestamp: $timestamp,
        source: { resourceGroup: $sourceRg, vmName: $sourceVm },
        target: { resourceGroup: $targetRg, vmName: $newVm },
        safety: { sharedDiskCheck: $sharedDiskCheck, findings: $sharedDiskFindings },
        status: "aborted"
      }' > "$LOG_FILE"

      exit 2
    fi
  done < <(echo "$DATA_DISKS_JSON" | jq -c '.[]')
fi

echo -e "${GREEN}✓ Shared-disk safety check passed.${NC}"

#############################################
# Helper: select next available IP(s) in subnet
#############################################
if $MULTI_MODE; then
  echo -e "${BLUE}Allocating ${#TARGET_VM_NAMES[@]} private IPs in subnet...${NC}"
else
  echo -e "${BLUE}Selecting next available private IP in subnet...${NC}"
fi

SUBNET_PREFIXES=$(az network vnet subnet show --ids "$SUBNET_ID" --query "addressPrefixes" -o json 2>/dev/null || true)
if [[ -z "$SUBNET_PREFIXES" || "$SUBNET_PREFIXES" == "null" ]]; then
  SUBNET_PREFIX=$(az network vnet subnet show --ids "$SUBNET_ID" --query "addressPrefix" -o tsv | tr -d '\r')
else
  SUBNET_PREFIX=$(echo "$SUBNET_PREFIXES" | jq -r '.[0]' | tr -d '\r')
fi

if [[ -z "$SUBNET_PREFIX" || "$SUBNET_PREFIX" == "null" ]]; then
  echo "ERROR: Could not determine subnet address prefix for $SUBNET_ID"
  exit 1
fi

# Used IPs from ALL NICs in this subnet (across all RGs in subscription)
echo -e "${CYAN}  → Checking IP allocations across subscription...${NC}"
USED_IPS=$(az network nic list --query "[?ipConfigurations[0].subnet.id=='$SUBNET_ID'].ipConfigurations[].privateIPAddress" -o tsv 2>/dev/null || true)

# Calculate required IP count
IP_COUNT=${#TARGET_VM_NAMES[@]}

# Python script to allocate N IPs
ALLOCATED_IPS_RAW=$(python3 - "$SUBNET_PREFIX" "$USED_IPS" "$IP_COUNT" <<'PYSCRIPT'
import ipaddress, sys

cidr = sys.argv[1]
used_ips_raw = sys.argv[2] if len(sys.argv) > 2 else ""
count = int(sys.argv[3]) if len(sys.argv) > 3 else 1
used = set(filter(None, used_ips_raw.split()))
net = ipaddress.ip_network(cidr, strict=False)

# Azure reserves first 4 and last 1
reserved = set()
for i in range(0, 4):
    reserved.add(net.network_address + i)
reserved.add(net.broadcast_address)

allocated = []
for ip in net:
    if ip in reserved:
        continue
    if ip == net.network_address or ip == net.broadcast_address:
        continue
    ip_s = str(ip)
    if ip_s in used:
        continue
    allocated.append(ip_s)
    if len(allocated) >= count:
        break

if len(allocated) < count:
    print("ERROR_NOT_ENOUGH_IPS", file=sys.stderr)
    sys.exit(1)

for ip_addr in allocated:
    print(ip_addr)
PYSCRIPT
)

# Check for IP allocation errors
if [[ $? -ne 0 ]]; then
  echo "ERROR: Not enough available IPs in subnet $SUBNET_PREFIX for $IP_COUNT VMs"
  exit 1
fi

# Store IPs in array
declare -a ALLOCATED_IPS=()
while IFS= read -r ip; do
  ALLOCATED_IPS+=("$ip")
done <<< "$ALLOCATED_IPS_RAW"

if [[ ${#ALLOCATED_IPS[@]} -ne $IP_COUNT ]]; then
  echo "ERROR: IP allocation mismatch. Expected $IP_COUNT, got ${#ALLOCATED_IPS[@]}"
  exit 1
fi

# Display allocated IPs
if $MULTI_MODE; then
  echo -e "${GREEN}  ✓ Allocated $IP_COUNT static private IPs:${NC}"
  for ((i=0; i<${#ALLOCATED_IPS[@]}; i++)); do
    echo -e "${GREEN}    ${TARGET_VM_NAMES[$i]} -> ${ALLOCATED_IPS[$i]}${NC}"
  done
else
  NEXT_IP="${ALLOCATED_IPS[0]}"
  echo -e "${GREEN}  ✓ Selected static private IP: $NEXT_IP${NC}"
fi

#############################################
# 1) Create snapshots (once, reused in multi-mode)
#############################################
STEP_START=$(date +%s)
OS_SNAPSHOT_NAME="${OS_DISK_NAME}-os-snap-${TS}"

if $MULTI_MODE; then
  echo -e "${BLUE}[1/8] Creating snapshots for reuse across ${#TARGET_VM_NAMES[@]} VMs...${NC}"
else
  echo -e "${BLUE}[1/8] Creating OS disk snapshot...${NC}"
fi

echo -e "${YELLOW}  → Snapshotting OS disk: $OS_DISK_NAME...${NC}"
OS_SNAPSHOT_ID=$(
  az snapshot create \
    -g "$TARGET_RG" \
    -n "$OS_SNAPSHOT_NAME" \
    --source "$OS_DISK_ID" \
    --location "$LOCATION" \
    --only-show-errors \
    --query "id" -o tsv 2>/dev/null
)
echo -e "${GREEN}  ✓ OS snapshot created: $OS_SNAPSHOT_NAME${NC}"

# Snapshot data disks
declare -a DATA_SNAPSHOT_IDS=()
declare -a DATA_SNAPSHOT_NAMES=()
declare -a DATA_DISK_LUNS=()
declare -a DATA_DISK_NAMES=()
declare -a DATA_DISK_IDS=()
declare -a DATA_DISK_CACHING=()

if [[ "$DATA_DISK_COUNT" -gt 0 ]]; then
  echo -e "${YELLOW}  → Snapshotting $DATA_DISK_COUNT data disk(s)...${NC}"
  
  while IFS= read -r disk; do
    LUN=$(echo "$disk" | jq -r '.lun')
    DISK_NAME=$(echo "$disk" | jq -r '.name')
    DISK_ID=$(echo "$disk" | jq -r '.managedDisk.id')
    CACHING=$(echo "$disk" | jq -r '.caching // "None"')
    
    SNAP_NAME="${DISK_NAME}-snap-${TS}"
    echo -e "${YELLOW}    → LUN $LUN: $DISK_NAME...${NC}"
    
    SNAP_ID=$(
      az snapshot create \
        -g "$TARGET_RG" \
        -n "$SNAP_NAME" \
        --source "$DISK_ID" \
        --location "$LOCATION" \
        --only-show-errors \
        --query "id" -o tsv 2>/dev/null
    )
    
    DATA_SNAPSHOT_IDS+=("$SNAP_ID")
    DATA_SNAPSHOT_NAMES+=("$SNAP_NAME")
    DATA_DISK_LUNS+=("$LUN")
    DATA_DISK_NAMES+=("$DISK_NAME")
    DATA_DISK_IDS+=("$DISK_ID")
    DATA_DISK_CACHING+=("$CACHING")
    
    echo -e "${GREEN}      ✓ Snapshot created: $SNAP_NAME${NC}"
  done <<< "$(echo "$DATA_DISKS_JSON" | jq -c '.[]')"
fi

if $MULTI_MODE; then
  echo -e "${GREEN}✓ Snapshots created and ready for reuse${NC}"
fi
STEP_END=$(date +%s)
STEP_ELAPSED=$((STEP_END - STEP_START))
echo -e "${CYAN}  ⏱ Step 1: ${STEP_ELAPSED}s${NC}"

#############################################
# Arrays to track created resources
#############################################
declare -a ALL_CREATED_VMS=()
declare -a ALL_VM_IPS=()
declare -a ALL_VM_ZONES=()
declare -a ALL_VM_EXTENSIONS=()
declare -a ALL_VM_STATUSES=()
declare -a ALL_LOG_FILES=()

#############################################
# Main VM Creation Loop
#############################################
for VM_IDX in "${!TARGET_VM_NAMES[@]}"; do
  NEW_VM_NAME="${TARGET_VM_NAMES[$VM_IDX]}"
  NEXT_IP="${ALLOCATED_IPS[$VM_IDX]}"
  
  # Initialize variables for this VM
  NEW_DATA_DISK_IDS=()
  NEW_DATA_DISK_LUNS=()
  NEW_DATA_DISK_CACHING=()
  HOSTNAME_EXTENSION_STATUS="Not set"
  EXTENSION_STATUS="Not installed"
  
  # Determine availability zone for this VM
  if $MULTI_MODE && [[ -n "$SOURCE_AVAILABILITY_ZONE" ]]; then
    # Round-robin: alternate between zones
    ZONE_INDEX=$((VM_IDX % ${#ZONE_ROTATION[@]}))
    AVAILABILITY_ZONE="${ZONE_ROTATION[$ZONE_INDEX]}"
  else
    # Single instance mode: use source zone
    AVAILABILITY_ZONE="$SOURCE_AVAILABILITY_ZONE"
  fi
  
  if $MULTI_MODE; then
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}Creating VM $((VM_IDX + 1)) of ${#TARGET_VM_NAMES[@]}: $NEW_VM_NAME${NC}"
    if [[ -n "$AVAILABILITY_ZONE" ]]; then
      echo -e "${CYAN}Target Zone: $AVAILABILITY_ZONE${NC}"
    fi
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
  fi
  
  # Calculate resource names for this VM using pattern matching
  NEW_OS_DISK_NAME="${OS_DISK_NAME/$SOURCE_VM_NAME/$NEW_VM_NAME}"
  NEW_NIC_NAME="${NIC_NAME/$SOURCE_VM_NAME/$NEW_VM_NAME}"
  
  # Update NIC zone suffix if zone changed and NIC has zone suffix
  if [[ -n "$AVAILABILITY_ZONE" ]] && [[ -n "$SOURCE_AVAILABILITY_ZONE" ]] && [[ "$AVAILABILITY_ZONE" != "$SOURCE_AVAILABILITY_ZONE" ]]; then
    # If NIC name has zone suffix pattern like "_z1", update it
    if [[ "$NEW_NIC_NAME" =~ (.+)_z[0-9]+$ ]]; then
      NEW_NIC_NAME="${BASH_REMATCH[1]}_z${AVAILABILITY_ZONE}"
    fi
  fi
  
  #############################################
  # 2) Create OS disk from snapshot
  #############################################

  #############################################
  # 2) Create OS disk from snapshot
  #############################################
  STEP_START=$(date +%s)
  echo -e "${BLUE}[2/8] Creating OS disk from snapshot...${NC}"
  echo -e "${YELLOW}  → Creating $NEW_OS_DISK_NAME...${NC}"

  ZONE_ARG=()
  if [[ -n "$AVAILABILITY_ZONE" ]]; then
    ZONE_ARG=(--zone "$AVAILABILITY_ZONE")
  fi

  NEW_OS_DISK_ID=$(
    az disk create \
      -g "$TARGET_RG" \
      -n "$NEW_OS_DISK_NAME" \
      --source "$OS_SNAPSHOT_ID" \
      --location "$LOCATION" \
      "${ZONE_ARG[@]}" \
      --only-show-errors \
      --query "id" -o tsv 2>/dev/null
  )
  echo -e "${GREEN}  ✓ OS disk created: $NEW_OS_DISK_NAME${NC}"
  STEP_END=$(date +%s)
  echo -e "${CYAN}  ⏱ Step 2: $((STEP_END - STEP_START))s${NC}"

  #############################################
  # 3) Create data disks from snapshots
  #############################################
  STEP_START=$(date +%s)
  declare -a NEW_DATA_DISK_IDS=()
  declare -a NEW_DATA_DISK_NAMES=()
  declare -a NEW_DATA_DISK_LUNS=()
  declare -a NEW_DATA_DISK_CACHING=()

  if [[ "$DATA_DISK_COUNT" -gt 0 ]]; then
    echo -e "${BLUE}[3/8] Creating $DATA_DISK_COUNT data disk(s) from snapshots...${NC}"
    
    for DISK_IDX in "${!DATA_SNAPSHOT_IDS[@]}"; do
      SNAP_ID="${DATA_SNAPSHOT_IDS[$DISK_IDX]}"
      LUN="${DATA_DISK_LUNS[$DISK_IDX]}"
      SOURCE_DISK_NAME="${DATA_DISK_NAMES[$DISK_IDX]}"
      CACHING="${DATA_DISK_CACHING[$DISK_IDX]}"
      
      # Use source disk naming pattern
      NEW_DISK_NAME="${SOURCE_DISK_NAME/$SOURCE_VM_NAME/$NEW_VM_NAME}"
      
      echo -e "${YELLOW}  → LUN $LUN: Creating $NEW_DISK_NAME...${NC}"
      
      ZONE_ARG_DATA=()
      if [[ -n "$AVAILABILITY_ZONE" ]]; then
        ZONE_ARG_DATA=(--zone "$AVAILABILITY_ZONE")
      fi
      
      NEW_DISK_ID=$(
        az disk create \
          -g "$TARGET_RG" \
          -n "$NEW_DISK_NAME" \
          --source "$SNAP_ID" \
          --location "$LOCATION" \
          "${ZONE_ARG_DATA[@]}" \
          --only-show-errors \
          --query "id" -o tsv 2>/dev/null
      )
      
      NEW_DATA_DISK_IDS+=("$NEW_DISK_ID")
      NEW_DATA_DISK_NAMES+=("$NEW_DISK_NAME")
      NEW_DATA_DISK_LUNS+=("$LUN")
      NEW_DATA_DISK_CACHING+=("$CACHING")
      
      echo -e "${GREEN}    ✓ Data disk ready: $NEW_DISK_NAME${NC}"
    done
  else
    echo "No data disks to create."
  fi
  STEP_END=$(date +%s)
  echo -e "${CYAN}  ⏱ Step 3: $((STEP_END - STEP_START))s${NC}"

  #############################################
  # 4) Create NIC with STATIC private IP
  #############################################
  STEP_START=$(date +%s)
  NSG_ARG=()
  if [[ -n "$NSG_ID" ]]; then
    NSG_ARG=(--network-security-group "$NSG_ID")
  fi

  ACCEL_NET_ARG=()
  if [[ "$ACCELERATED_NETWORKING" == "true" ]]; then
    ACCEL_NET_ARG=(--accelerated-networking true)
  fi

  echo -e "${BLUE}[4/8] Creating network interface...${NC}"
  echo -e "${YELLOW}  → Creating $NEW_NIC_NAME with IP $NEXT_IP...${NC}"
  
  # Build NIC create command
  NIC_CMD="az network nic create -g \"$TARGET_RG\" -n \"$NEW_NIC_NAME\" --location \"$LOCATION\" --subnet \"$SUBNET_ID\" --private-ip-address \"$NEXT_IP\""
  if [[ -n "$NSG_ID" ]]; then
    NIC_CMD="$NIC_CMD --network-security-group \"$NSG_ID\""
  fi
  if [[ "$ACCELERATED_NETWORKING" == "true" ]]; then
    NIC_CMD="$NIC_CMD --accelerated-networking true"
  fi
  NIC_CMD="$NIC_CMD -o none"
  
  # Create NIC
  if ! eval "$NIC_CMD" 2>/dev/null; then
    echo -e "${RED}  ✗ Failed to create NIC $NEW_NIC_NAME with IP $NEXT_IP${NC}"
    echo -e "${RED}    IP may already be in use or there may be a network configuration issue${NC}"
    exit 1
  fi
  
  # Query NIC ID after creation
  NEW_NIC_ID=$(az network nic show -g "$TARGET_RG" -n "$NEW_NIC_NAME" --query id -o tsv 2>/dev/null)
  
  if [[ -z "$NEW_NIC_ID" ]]; then
    echo -e "${RED}  ✗ Failed to retrieve NIC ID for $NEW_NIC_NAME${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}  ✓ NIC created with static IP: $NEXT_IP${NC}"
  STEP_END=$(date +%s)
  echo -e "${CYAN}  ⏱ Step 4: $((STEP_END - STEP_START))s${NC}"

  #############################################
  # 5) Create new VM from cloned OS disk
  #############################################
  STEP_START=$(date +%s)
  echo -e "${BLUE}[5/8] Creating virtual machine...${NC}"
  if [[ -n "$AVAILABILITY_ZONE" ]]; then
    echo -e "${YELLOW}  → Creating $NEW_VM_NAME ($VM_SIZE) in zone $AVAILABILITY_ZONE...${NC}"
  else
    echo -e "${YELLOW}  → Creating $NEW_VM_NAME ($VM_SIZE)...${NC}"
  fi

  ZONE_ARG_VM=()
  if [[ -n "$AVAILABILITY_ZONE" ]]; then
    ZONE_ARG_VM=(--zone "$AVAILABILITY_ZONE")
  fi

  LICENSE_ARG=()
  if [[ -n "$LICENSE_TYPE" ]]; then
    LICENSE_ARG=(--license-type "$LICENSE_TYPE")
  fi

  VM_CREATE_OUTPUT=$(az vm create \
    -g "$TARGET_RG" \
    -n "$NEW_VM_NAME" \
    --attach-os-disk "$NEW_OS_DISK_NAME" \
    --os-type linux \
    --size "$VM_SIZE" \
    --nics "$NEW_NIC_NAME" \
    "${ZONE_ARG_VM[@]}" \
    "${LICENSE_ARG[@]}" \
    --no-wait 2>&1)
  
  VM_CREATE_EXIT=$?
  if [ $VM_CREATE_EXIT -ne 0 ]; then
    echo -e "${RED}  ✗ VM creation failed${NC}"
    echo -e "${YELLOW}  Error: $VM_CREATE_OUTPUT${NC}"
    ALL_CREATED_VMS+=("$NEW_VM_NAME")
    ALL_VM_IPS+=("$NEXT_IP")
    ALL_VM_STATUSES+=("Failed: VM creation error")
    continue
  fi
  echo -e "${GREEN}  ✓ VM creation initiated: $NEW_VM_NAME${NC}"

  NEW_VM_ID=$(az vm show -g "$TARGET_RG" -n "$NEW_VM_NAME" --query "id" -o tsv 2>/dev/null || echo "")

  # Wait for VM Agent and set hostname immediately to avoid DNS conflicts
  if [[ "$SET_HOSTNAME" == "true" || "$SET_HOSTNAME" == "True" ]]; then
    echo -e "${YELLOW}  → Waiting for VM Agent and setting hostname...${NC}"
    AGENT_WAIT=0
    while [ $AGENT_WAIT -lt 90 ]; do
      AGENT_STATUS=$(az vm get-instance-view -g "$TARGET_RG" -n "$NEW_VM_NAME" --query "instanceView.vmAgent.statuses[0].displayStatus" -o tsv 2>/dev/null | tr -d '\r' | xargs || echo "")
      if [[ "$AGENT_STATUS" == "Ready" ]]; then
        # Set hostname immediately
        az vm run-command invoke \
          -g "$TARGET_RG" \
          -n "$NEW_VM_NAME" \
          --command-id RunShellScript \
          --scripts "sudo hostnamectl set-hostname $NEW_VM_NAME && if grep -q '^127.0.1.1' /etc/hosts; then sudo sed -i 's/^127.0.1.1.*/127.0.1.1 $NEW_VM_NAME/' /etc/hosts; else echo '127.0.1.1 $NEW_VM_NAME' | sudo tee -a /etc/hosts; fi" \
          --only-show-errors >/dev/null 2>&1
        echo -e "${GREEN}  ✓ Hostname set to: $NEW_VM_NAME${NC}"
        break
      fi
      sleep 2
      AGENT_WAIT=$((AGENT_WAIT + 1))
    done
    
    if [ $AGENT_WAIT -ge 90 ]; then
      echo -e "${YELLOW}  ⚠ VM Agent not ready yet, hostname will be set during verification${NC}"
    fi
  fi

  STEP_END=$(date +%s)
  echo -e "${CYAN}  ⏱ Step 5: $((STEP_END - STEP_START))s${NC}"

  #############################################
  # 6) Attach cloned data disks
  #############################################
  STEP_START=$(date +%s)
  if [[ "${#NEW_DATA_DISK_IDS[@]}" -gt 0 ]]; then
    echo -e "${BLUE}[6/8] Attaching ${#NEW_DATA_DISK_IDS[@]} data disk(s)...${NC}"
    for i in "${!NEW_DATA_DISK_IDS[@]}"; do
      LUN="${NEW_DATA_DISK_LUNS[$i]}"
      DISK_ID="${NEW_DATA_DISK_IDS[$i]}"
      CACHING="${NEW_DATA_DISK_CACHING[$i]}"
      DISK_NAME="${NEW_DATA_DISK_NAMES[$i]}"
      
      echo -e "${YELLOW}  → Attaching disk $DISK_NAME at LUN $LUN...${NC}"
      
      ATTACH_OUTPUT=$(az vm disk attach \
        -g "$TARGET_RG" \
        --vm-name "$NEW_VM_NAME" \
        --name "$DISK_NAME" \
        --lun "$LUN" \
        --caching "$CACHING" \
        2>&1)
      ATTACH_EXIT=$?
      
      # Wait for disk state to update
      WAIT_DISK=0
      MAX_WAIT_DISK=10
      DISK_ATTACHED=false
      
      while [ $WAIT_DISK -lt $MAX_WAIT_DISK ]; do
        DISK_STATE=$(az disk show -g "$TARGET_RG" -n "$DISK_NAME" --query "diskState" -o tsv 2>/dev/null | tr -d '\r' | xargs || echo "Unknown")
        if [[ "$DISK_STATE" == "Attached" ]]; then
          DISK_ATTACHED=true
          break
        fi
        sleep 2
        WAIT_DISK=$((WAIT_DISK + 1))
      done
      
      if [ "$DISK_ATTACHED" = true ]; then
        echo -e "${GREEN}  ✓ Disk attached at LUN $LUN${NC}"
      else
        echo -e "${RED}  ✗ Failed to attach disk at LUN $LUN${NC}"
        echo -e "${YELLOW}  Disk state: '$DISK_STATE'${NC}"
      fi
    done
    echo -e "${GREEN}  ✓ All data disks attached${NC}"
  else
    echo "No data disks to attach."
  fi
  STEP_END=$(date +%s)
  echo -e "${CYAN}  ⏱ Step 6: $((STEP_END - STEP_START))s${NC}"

  #############################################
  # 7) Install extension if source VM has it
  #############################################
  STEP_START=$(date +%s)
  EXTENSION_NAME="MonitorX64Linux"
  PUBLISHER="Microsoft.AzureCAT.AzureEnhancedMonitoring"
  EXTENSION_STATUS="Not required"
  
  SOURCE_HAS_EXT=$(az vm extension show -g "$SOURCE_RG" --vm-name "$SOURCE_VM_NAME" -n "$EXTENSION_NAME" --query "name" -o tsv 2>/dev/null || echo "")
  
  if [[ -n "$SOURCE_HAS_EXT" ]]; then
    echo -e "${BLUE}[7/8] Installing extension...${NC}"
    echo -e "${YELLOW}  → Installing $EXTENSION_NAME...${NC}"
    
    az vm extension set \
      -g "$TARGET_RG" \
      --vm-name "$NEW_VM_NAME" \
      --name "$EXTENSION_NAME" \
      --publisher "$PUBLISHER" \
      --only-show-errors \
      >/dev/null 2>&1
    
    EXT_STATUS=$(az vm extension show -g "$TARGET_RG" --vm-name "$NEW_VM_NAME" -n "$EXTENSION_NAME" --query "provisioningState" -o tsv 2>/dev/null | tr -d '\r' | xargs || echo "NotFound")
    
    if [[ "$EXT_STATUS" == "Succeeded" ]]; then
      echo -e "${GREEN}  ✓ Extension installed successfully${NC}"
      EXTENSION_STATUS="Installed"
    else
      echo -e "${RED}  ✗ Extension status: $EXT_STATUS${NC}"
      EXTENSION_STATUS="$EXT_STATUS"
    fi
  fi
  STEP_END=$(date +%s)
  echo -e "${CYAN}  ⏱ Step 7: $((STEP_END - STEP_START))s${NC}"

  #############################################
  # 8) Write metadata log (JSON) for this VM
  #############################################
  STEP_START=$(date +%s)
  VM_LOG_FILE="${LOG_DIR}/${NEW_VM_NAME}-clone-${TS}.json"
  echo -e "${BLUE}[8/8] Writing metadata log...${NC}"
  echo -e "${YELLOW}  → Generating $VM_LOG_FILE...${NC}"

  # Extension and hostname were already set in previous steps
  HOSTNAME_EXTENSION_STATUS="Set in step 5"

  DISK_OBJS="[]"
  for i in "${!NEW_DATA_DISK_IDS[@]}"; do
    DISK_OBJS=$(echo "$DISK_OBJS" | jq \
      --arg lun "${NEW_DATA_DISK_LUNS[$i]}" \
      --arg id "${NEW_DATA_DISK_IDS[$i]}" \
      --arg caching "${NEW_DATA_DISK_CACHING[$i]}" \
      --arg snap "${DATA_SNAPSHOT_IDS[$i]:-}" \
      '. + [{"lun": ($lun|tonumber), "newDiskId": $id, "caching": $caching, "snapshotId": $snap}]'
    )
  done

  jq -n \
    --arg timestamp "$TS" \
    --arg sourceRg "$SOURCE_RG" \
    --arg sourceVm "$SOURCE_VM_NAME" \
    --arg targetRg "$TARGET_RG" \
    --arg newVm "$NEW_VM_NAME" \
    --arg location "$LOCATION" \
    --arg vmSize "$VM_SIZE" \
    --arg subnetId "$SUBNET_ID" \
    --arg vnetName "$VNET_NAME" \
    --arg subnetName "$SUBNET_NAME" \
    --arg subnetPrefix "$SUBNET_PREFIX" \
    --arg newPrivateIp "$NEXT_IP" \
    --arg newNicName "$NEW_NIC_NAME" \
    --arg newNicId "$NEW_NIC_ID" \
    --arg newVmId "$NEW_VM_ID" \
    --arg osDiskSourceId "$OS_DISK_ID" \
    --arg osSnapshotId "$OS_SNAPSHOT_ID" \
    --arg newOsDiskId "$NEW_OS_DISK_ID" \
    --arg nsgId "${NSG_ID:-}" \
    --arg hostnameAction "$HOSTNAME_EXTENSION_STATUS" \
    --arg extensionStatus "$EXTENSION_STATUS" \
    --arg sharedDiskCheck "$SHARED_DISK_CHECK" \
    --arg zone "$AVAILABILITY_ZONE" \
    --arg licenseType "$LICENSE_TYPE" \
    --arg accelNet "$ACCELERATED_NETWORKING" \
    --argjson sharedDiskFindings "$SHARED_DISK_FINDINGS" \
    --argjson dataDisks "$DISK_OBJS" \
  '{
    timestamp: $timestamp,
    safety: {
      sharedDiskCheck: $sharedDiskCheck,
      findings: $sharedDiskFindings
    },
    source: {
      resourceGroup: $sourceRg,
      vmName: $sourceVm,
      osDiskId: $osDiskSourceId
    },
    target: {
      resourceGroup: $targetRg,
      vmName: $newVm,
      vmId: $newVmId,
      location: $location,
      vmSize: $vmSize,
      availabilityZone: $zone,
      licenseType: $licenseType
    },
    network: {
      vnetName: $vnetName,
      subnetName: $subnetName,
      subnetId: $subnetId,
      subnetPrefix: $subnetPrefix,
      nsgId: $nsgId,
      nicName: $newNicName,
      nicId: $newNicId,
      privateIp: $newPrivateIp,
      acceleratedNetworking: ($accelNet | ascii_downcase == "true")
    },
    storage: {
      osSnapshotId: $osSnapshotId,
      newOsDiskId: $newOsDiskId,
      dataDisks: $dataDisks
    },
    postConfig: {
      hostnameUpdate: $hostnameAction,
      monitoringExtension: $extensionStatus
    },
    status: "completed"
  }' > "$VM_LOG_FILE"
  echo -e "${GREEN}  ✓ Log file written${NC}"
  STEP_END=$(date +%s)
  echo -e "${CYAN}  ⏱ Step 8: $((STEP_END - STEP_START))s${NC}"
  
  # Track this VM's completion
  ALL_CREATED_VMS+=("$NEW_VM_NAME")
  ALL_VM_IPS+=("$NEXT_IP")
  ALL_VM_ZONES+=("$AVAILABILITY_ZONE")
  ALL_VM_EXTENSIONS+=("$EXTENSION_STATUS")
  ALL_VM_STATUSES+=("Completed")
  ALL_LOG_FILES+=("$VM_LOG_FILE")
  
  if $MULTI_MODE; then
    echo -e "${GREEN}✓ VM $NEW_VM_NAME creation completed successfully${NC}"
  fi

done  # End of main VM creation loop

#############################################
# Final Summary - Validate and Display
#############################################
echo
echo
echo -e "${BLUE}Validating VM configurations...${NC}"

# Validate each VM's actual configuration
for idx in "${!ALL_CREATED_VMS[@]}"; do
  VM_NAME="${ALL_CREATED_VMS[$idx]}"
  
  # Query VM details
  VM_INFO=$(az vm show -g "$TARGET_RG" -n "$VM_NAME" -d --query "{zone:zones[0],nicId:networkProfile.networkInterfaces[0].id,dataDisks:length(storageProfile.dataDisks)}" -o json 2>/dev/null)
  ACTUAL_ZONE=$(echo "$VM_INFO" | jq -r '.zone // "none"')
  NIC_ID=$(echo "$VM_INFO" | jq -r '.nicId // ""')
  ACTUAL_DATA_DISKS=$(echo "$VM_INFO" | jq -r '.dataDisks // 0')
  
  # Check accelerated networking
  ACTUAL_ACCELNET="false"
  if [[ -n "$NIC_ID" ]]; then
    ACTUAL_ACCELNET=$(az network nic show --ids "$NIC_ID" --query "enableAcceleratedNetworking" -o tsv 2>/dev/null | tr -d '\r' | xargs || echo "false")
  fi
  
  # Check extension with version
  EXTENSION_NAME="MonitorX64Linux"
  ACTUAL_EXT_STATUS="Not required"
  SOURCE_HAS_EXT=$(az vm extension show -g "$SOURCE_RG" --vm-name "$SOURCE_VM_NAME" -n "$EXTENSION_NAME" --query "name" -o tsv 2>/dev/null || echo "")
  if [[ -n "$SOURCE_HAS_EXT" ]]; then
    EXT_INFO=$(az vm extension show -g "$TARGET_RG" --vm-name "$VM_NAME" -n "$EXTENSION_NAME" --query "{status:provisioningState,version:typeHandlerVersion}" -o json 2>/dev/null || echo "{}")
    EXT_STATE=$(echo "$EXT_INFO" | jq -r '.status // "NotFound"')
    EXT_VERSION=$(echo "$EXT_INFO" | jq -r '.version // ""')
    
    if [[ "$EXT_STATE" == "Succeeded" ]] && [[ -n "$EXT_VERSION" ]] && [[ "$EXT_VERSION" != "null" ]]; then
      ACTUAL_EXT_STATUS="$EXTENSION_NAME ($EXT_VERSION)"
    elif [[ "$EXT_STATE" == "Succeeded" ]]; then
      ACTUAL_EXT_STATUS="$EXTENSION_NAME"
    else
      ACTUAL_EXT_STATUS="$EXT_STATE"
    fi
  fi
  
  # Update arrays with validated values
  ALL_VM_ZONES[$idx]="$ACTUAL_ZONE"
  ALL_VM_EXTENSIONS[$idx]="$ACTUAL_EXT_STATUS"
done

echo -e "${GREEN}✓ Validation complete${NC}"
echo
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
if $MULTI_MODE; then
  echo -e "${GREEN}✓ Multi-Instance Clone Complete${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
  echo -e "  ${BLUE}Source VM${NC}             : ${CYAN}$SOURCE_VM_NAME${NC}"
  echo -e "  ${BLUE}Resource Group${NC}        : ${CYAN}$TARGET_RG${NC}"
  echo -e "  ${BLUE}Total VMs Created${NC}     : ${CYAN}${#ALL_CREATED_VMS[@]}${NC}"
  echo -e "${GREEN}──────────────────────────────────────────────────────${NC}"
  
  # Query actual accelerated networking from first VM for display
  if [[ ${#ALL_CREATED_VMS[@]} -gt 0 ]]; then
    FIRST_VM="${ALL_CREATED_VMS[0]}"
    FIRST_NIC_ID=$(az vm show -g "$TARGET_RG" -n "$FIRST_VM" --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null)
    VALIDATED_ACCELNET=$(az network nic show --ids "$FIRST_NIC_ID" --query "enableAcceleratedNetworking" -o tsv 2>/dev/null | tr -d '\r' | xargs || echo "false")
  fi
  
  for idx in "${!ALL_CREATED_VMS[@]}"; do
    echo -e "  ${CYAN}VM $((idx + 1)): ${ALL_CREATED_VMS[$idx]}${NC}"
    echo -e "    Private IP:            ${ALL_VM_IPS[$idx]}"
    echo -e "    Zone:                  ${ALL_VM_ZONES[$idx]}"
    echo -e "    VM Size:               $VM_SIZE"
    echo -e "    Extension Installed:   ${ALL_VM_EXTENSIONS[$idx]}"
    echo -e "    Accelerated Network:   ${VALIDATED_ACCELNET:-$ACCELERATED_NETWORKING}"
    echo -e "    Data Disks:            $DATA_DISK_COUNT"
    echo -e "    Log File:              ${ALL_LOG_FILES[$idx]}"
    if [[ $idx -lt $((${#ALL_CREATED_VMS[@]} - 1)) ]]; then
      echo -e "${GREEN}  ────────────────────────────────────────────────────${NC}"
    fi
  done
  
  echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
  echo -e "  ${BLUE}Snapshots Created${NC}     : ${CYAN}Reused across all VMs${NC}"
  echo -e "  ${BLUE}Accelerated Network${NC}   : ${CYAN}$ACCELERATED_NETWORKING${NC}"
  echo -e "  ${BLUE}Data Disks per VM${NC}     : ${CYAN}$DATA_DISK_COUNT${NC}"
  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))
  MINUTES=$((ELAPSED / 60))
  SECONDS=$((ELAPSED % 60))
  echo -e "  ${BLUE}Total Time${NC}            : ${CYAN}${MINUTES}m ${SECONDS}s${NC}"
else
  echo -e "${GREEN}✓ Clone Complete${NC}"
  echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
  NEW_VM_NAME="${ALL_CREATED_VMS[0]}"
  NEXT_IP="${ALL_VM_IPS[0]}"
  VM_LOG_FILE="${ALL_LOG_FILES[0]}"
  VALIDATED_ZONE="${ALL_VM_ZONES[0]}"
  VALIDATED_EXT="${ALL_VM_EXTENSIONS[0]}"
  
  # Get validated accelerated networking
  FIRST_NIC_ID=$(az vm show -g "$TARGET_RG" -n "$NEW_VM_NAME" --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null)
  VALIDATED_ACCELNET=$(az network nic show --ids "$FIRST_NIC_ID" --query "enableAcceleratedNetworking" -o tsv 2>/dev/null | tr -d '\r' | xargs || echo "false")
  
  echo -e "  ${BLUE}VM Name${NC}               : ${CYAN}$NEW_VM_NAME${NC}"
  echo -e "  ${BLUE}Resource Group${NC}        : ${CYAN}$TARGET_RG${NC}"
  echo -e "  ${BLUE}Private IP${NC}            : ${CYAN}$NEXT_IP${NC} ${GREEN}(static)${NC}"
  echo -e "  ${BLUE}Zone${NC}                  : ${CYAN}$VALIDATED_ZONE${NC}"
  echo -e "  ${BLUE}VM Size${NC}               : ${CYAN}$VM_SIZE${NC}"
  echo -e "  ${BLUE}Extension Installed${NC}   : ${CYAN}$VALIDATED_EXT${NC}"
  echo -e "  ${BLUE}Accelerated Network${NC}   : ${CYAN}$VALIDATED_ACCELNET${NC}"
  echo -e "  ${BLUE}Data Disks${NC}            : ${CYAN}$DATA_DISK_COUNT${NC}"
  echo -e "  ${BLUE}Log File${NC}              : ${CYAN}$VM_LOG_FILE${NC}"
  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))
  MINUTES=$((ELAPSED / 60))
  SECONDS=$((ELAPSED % 60))
  echo -e "  ${BLUE}Total Time${NC}            : ${CYAN}${MINUTES}m ${SECONDS}s${NC}"
fi
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
