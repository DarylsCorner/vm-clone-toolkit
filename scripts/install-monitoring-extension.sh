#!/usr/bin/env bash
set -euo pipefail

# Color codes for better readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

#############################################
# install-monitoring-extension.sh
#
# Installs or updates Azure Enhanced Monitoring extension (MonitorX64Linux)
# on a Linux VM
#############################################

# Show help
show_help() {
  cat << EOF
Azure Enhanced Monitoring Extension Installer

Installs or updates the MonitorX64Linux extension on Azure VMs.
If an older version exists, it will be updated to the latest version.

Usage: $0 <resource-group> <vm-name>

Arguments:
  resource-group     Azure resource group containing the VM
  vm-name           Name of the VM to install/update the extension on

Examples:
  # Install extension on a VM
  $0 RG-EASTUS sapdl1app02

  # Update existing extension to latest version
  $0 RG-PROD sap-prod-app01

Extension Details:
  Name:      MonitorX64Linux
  Publisher: Microsoft.AzureCAT.AzureEnhancedMonitoring
  Purpose:   Azure Enhanced Monitoring for SAP workloads

For more information: https://github.com/DarylsCorner/vm-clone-toolkit
EOF
  exit 0
}

# Parse arguments
if [[ $# -lt 1 ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
  show_help
fi

if [[ $# -lt 2 ]]; then
  echo -e "${RED}ERROR: Insufficient arguments${NC}"
  echo -e "${RED}Usage: $0 <resource-group> <vm-name>${NC}"
  echo "Run '$0 --help' for more information"
  exit 1
fi

RESOURCE_GROUP="$1"
VM_NAME="$2"

EXTENSION_NAME="MonitorX64Linux"
PUBLISHER="Microsoft.AzureCAT.AzureEnhancedMonitoring"

echo -e "${BLUE}Installing Azure Enhanced Monitoring Extension${NC}"
echo -e "${CYAN}  VM: $VM_NAME${NC}"
echo -e "${CYAN}  Resource Group: $RESOURCE_GROUP${NC}"
echo ""

# Check if VM already has the extension
echo -e "${BLUE}[1/2] Checking VM for existing extension...${NC}"
EXISTING_EXT=$(az vm extension show \
  -g "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  -n "$EXTENSION_NAME" \
  --query "name" \
  -o tsv 2>/dev/null || echo "")

if [[ -n "$EXISTING_EXT" ]]; then
  EXISTING_VERSION=$(az vm extension show \
    -g "$RESOURCE_GROUP" \
    --vm-name "$VM_NAME" \
    -n "$EXTENSION_NAME" \
    --query "typeHandlerVersion" \
    -o tsv 2>/dev/null || echo "unknown")
  echo -e "${YELLOW}  ⚠ Extension already exists (version: $EXISTING_VERSION)${NC}"
  echo -e "${YELLOW}  Will update to latest version if available${NC}"
else
  echo -e "${GREEN}  ✓ No existing extension found${NC}"
fi

# Install or update the extension
echo -e "${BLUE}[2/2] Installing/updating extension...${NC}"
echo -e "${YELLOW}  → Installing $EXTENSION_NAME...${NC}"

az vm extension set \
  -g "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --name "$EXTENSION_NAME" \
  --publisher "$PUBLISHER" \
  --only-show-errors \
  >/dev/null 2>&1

# Verify installation with polling
MAX_WAIT=60  # 60 iterations × 5 seconds = 5 minutes max
WAIT_COUNT=0
INSTALL_STATUS="Unknown"

while [[ $WAIT_COUNT -lt $MAX_WAIT ]]; do
  INSTALL_STATUS=$(az vm extension show \
    -g "$RESOURCE_GROUP" \
    --vm-name "$VM_NAME" \
    -n "$EXTENSION_NAME" \
    --query "provisioningState" \
    -o tsv 2>/dev/null | tr -d '\r' | xargs || echo "Unknown")
  
  if [[ "$INSTALL_STATUS" == "Succeeded" ]]; then
    echo -e "${GREEN}  ✓ Extension installed successfully${NC}"
    break
  elif [[ "$INSTALL_STATUS" == "Failed" ]]; then
    echo -e "${RED}  ✗ Extension installation failed${NC}"
    exit 1
  fi
  
  sleep 5
  WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [[ "$INSTALL_STATUS" != "Succeeded" ]]; then
  echo -e "${RED}  ✗ Extension installation timed out. Final status: $INSTALL_STATUS${NC}"
  exit 1
fi

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ Extension Installation/Update Complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "  ${BLUE}VM Name${NC}      : ${CYAN}$VM_NAME${NC}"
echo -e "  ${BLUE}Extension${NC}    : ${CYAN}$EXTENSION_NAME${NC}"
echo -e "  ${BLUE}Status${NC}       : ${CYAN}$INSTALL_STATUS${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
