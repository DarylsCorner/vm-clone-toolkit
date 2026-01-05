#!/usr/bin/env bash
set -euo pipefail

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <resource-group> <vm-name1> [vm-name2] [vm-name3] ..."
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
