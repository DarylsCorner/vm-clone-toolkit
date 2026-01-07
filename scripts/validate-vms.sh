#!/usr/bin/env bash
set -euo pipefail

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Show help
show_help() {
  cat << EOF
VM Configuration Validator

Quickly validates VM configurations without redeployment.
Checks IP addresses, zones, VM size, extensions, accelerated networking, and data disks.

Usage: $0 <resource-group> <vm-name1> [vm-name2] [vm-name3] ...

Arguments:
  resource-group     Azure resource group containing the VMs
  vm-name1           First VM name to validate (required)
  vm-name2...        Additional VM names to validate (optional)

Output:
  For each VM, displays:
    - Private IP address
    - Availability zone
    - VM size
    - Extension installed (with version)
    - Accelerated networking status
    - Data disk count

Examples:
  # Validate a single VM
  bash scripts/validate-vms.sh RG-EASTUS sapdl1app02

  # Validate multiple VMs
  bash scripts/validate-vms.sh RG-EASTUS sapdl1app02 sapdl1app03 sapdl1app04

  # Validate all VMs in a series
  bash scripts/validate-vms.sh RG-PROD sapx00a52 sapx00a53 sapx00a54 sapx00a55

For more information: https://github.com/DarylsCorner/vm-clone-toolkit
EOF
  exit 0
}

# Parse arguments
if [[ $# -lt 1 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
  show_help
fi

if [[ $# -lt 2 ]]; then
  echo "ERROR: Insufficient arguments"
  echo "Usage: $0 <resource-group> <vm-name1> [vm-name2] [vm-name3] ..."
  echo "Run '$0 --help' for more information"
  exit 1
fi

RG="$1"
shift
VMS=("$@")

echo -e "${BLUE}Validating ${#VMS[@]} VMs in resource group: $RG${NC}"
echo

for VM_NAME in "${VMS[@]}"; do
  echo -e "${CYAN}Validating: $VM_NAME${NC}"
  
  # Query VM details
  VM_INFO=$(az vm show -g "$RG" -n "$VM_NAME" -d --query "{zone:zones[0],nicId:networkProfile.networkInterfaces[0].id,dataDisks:length(storageProfile.dataDisks),privateIP:privateIps,size:hardwareProfile.vmSize}" -o json 2>/dev/null)
  
  if [[ -z "$VM_INFO" ]] || [[ "$VM_INFO" == "null" ]]; then
    echo -e "  ✗ VM not found"
    continue
  fi
  
  ZONE=$(echo "$VM_INFO" | jq -r '.zone // "none"')
  NIC_ID=$(echo "$VM_INFO" | jq -r '.nicId // ""')
  DATA_DISKS=$(echo "$VM_INFO" | jq -r '.dataDisks // 0')
  PRIVATE_IP=$(echo "$VM_INFO" | jq -r '.privateIP // "unknown"')
  VM_SIZE=$(echo "$VM_INFO" | jq -r '.size // "unknown"')
  
  # Check accelerated networking
  ACCEL_NET="false"
  if [[ -n "$NIC_ID" ]]; then
    ACCEL_NET=$(az network nic show --ids "$NIC_ID" --query "enableAcceleratedNetworking" -o tsv 2>/dev/null | tr -d '\r' | xargs || echo "false")
  fi
  
  # Check extension with version
  EXT_INFO=$(az vm extension show -g "$RG" --vm-name "$VM_NAME" -n "MonitorX64Linux" --query "{status:provisioningState,version:typeHandlerVersion}" -o json 2>/dev/null || echo "{}")
  EXT_STATUS=$(echo "$EXT_INFO" | jq -r '.status // "Not installed"')
  EXT_VERSION=$(echo "$EXT_INFO" | jq -r '.version // ""')
  if [[ "$EXT_STATUS" == "Succeeded" ]] && [[ -n "$EXT_VERSION" ]] && [[ "$EXT_VERSION" != "null" ]]; then
    EXT_DISPLAY="MonitorX64Linux ($EXT_VERSION)"
  elif [[ "$EXT_STATUS" == "Succeeded" ]]; then
    EXT_DISPLAY="MonitorX64Linux"
  else
    EXT_DISPLAY="$EXT_STATUS"
  fi
  
  echo -e "  Private IP:            $PRIVATE_IP"
  echo -e "  Zone:                  $ZONE"
  echo -e "  VM Size:               $VM_SIZE"
  echo -e "  Extension Installed:   $EXT_DISPLAY"
  echo -e "  Accelerated Network:   $ACCEL_NET"
  echo -e "  Data Disks:            $DATA_DISKS"
  echo
done

echo -e "${GREEN}✓ Validation complete${NC}"
