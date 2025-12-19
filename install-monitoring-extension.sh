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
# Installs Azure Enhanced Monitoring extension (MonitorX64Linux)
# on a Linux VM
#
# Usage:
#   ./install-monitoring-extension.sh <resource-group> <vm-name>
#
# Example:
#   ./install-monitoring-extension.sh RG-EASTUS sapdl1app02
#############################################

if [[ $# -lt 2 ]]; then
  echo -e "${RED}Usage: $0 <resource-group> <vm-name>${NC}"
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
  echo -e "${YELLOW}  ⚠ Extension already exists${NC}"
  echo -e "${YELLOW}  Skipping installation${NC}"
  exit 0
fi

echo -e "${GREEN}  ✓ No existing extension found${NC}"

# Install the extension
echo -e "${BLUE}[2/2] Installing extension...${NC}"
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
echo -e "${GREEN}✓ Extension Installation Complete${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "  ${BLUE}VM Name${NC}      : ${CYAN}$VM_NAME${NC}"
echo -e "  ${BLUE}Extension${NC}    : ${CYAN}$EXTENSION_NAME${NC}"
echo -e "  ${BLUE}Status${NC}       : ${CYAN}$INSTALL_STATUS${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
