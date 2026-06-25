# Azure VM Clone Toolkit

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-5.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![Azure CLI](https://img.shields.io/badge/Azure%20CLI-2.x-0078D4.svg)](https://docs.microsoft.com/en-us/cli/azure/)
[![Tested on SLES](https://img.shields.io/badge/tested-SLES%2015-0C322C.svg)](https://www.suse.com/products/server/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/DarylsCorner/vm-clone-toolkit/pulls)

Toolkit for cloning Azure Linux VMs with disk snapshots, accelerated networking, and extension management.

## 📋 Overview

This repository contains scripts to safely clone Azure Linux VMs (tested with SLES 15 SP6) including:
- Complete OS and data disk cloning via snapshots
- Automatic network configuration with static IP assignment
- Accelerated networking preservation
- VM extension management (MonitorX64Linux)
- Resource naming pattern matching
- Safety checks for shared disk configurations
- Comprehensive logging and validation

## 🚀 Features

### clone-app-server.sh
The main cloning script with the following capabilities:

- **Online Cloning**: Creates snapshots without VM shutdown
- **Complete Disk Cloning**: OS disk + all data disks with LUN and caching preservation
- **Multi-Instance Provisioning**: Create multiple VMs from a single snapshot operation
- **Zone Distribution**: Automatically distributes VMs across availability zones (1 and 3) for high availability
- **Smart Networking**: 
  - Automatically selects next available private IP(s) with comprehensive detection
  - Detects IPs used by VMs, Load Balancers, Private Endpoints, and all other network resources
  - Maintains accelerated networking settings
  - Preserves NSG associations, if any
  - Supports availability zone placement with intelligent rotation
- **Resource Naming**: Matches source VM naming patterns (e.g., `sapdl1app01-nic` → `sapdl1app02-nic`)
- **Extension Management**: Automatically installs MonitorX64Linux if present on source VM (with latest update)
- **Hostname Configuration**: Sets hostname in guest OS to match new VM name (default: enabled)
- **Safety Gates**: Blocks cloning of VMs with shared disks to prevent cluster conflicts
- **Comprehensive Logging**: JSON logs with full pre/post configuration metadata

### validate_aem_monitorx64linux.sh
Extension health validation script for MonitorX64Linux (Azure Enhanced Monitoring). Performs comprehensive checks:

**Critical Checks (Must Pass):**
- ✅ Extension artifact directory exists (`/var/lib/waagent/Microsoft.AzureCAT.AzureEnhancedMonitoring.MonitorX64Linux-*`)
- ✅ Handler manifest and configuration files present (`HandlerEnvironment.json`, `HandlerStatus`)
- ✅ Extension process running (`AzureEnhancedMonitoring -monitor`)
- ✅ Metrics endpoint responding on port 11812 (`127.0.0.1:11812/azure4sap/metrics`)

**Optional Checks (May Skip):**
- ⚠️ Legacy PerfCounters directory (`/var/lib/AzureEnhancedMonitor`) - only for older extension versions
- ⚠️ Azure IMDS EnhancedAccess flag - only relevant for SAP workloads
- ⚠️ saposcol process - only needed for SAP workloads

**Output Format:**
- Individual check results with ✔ (pass), ✗ (fail), or ⚠ (skip/warning)
- Summary table showing pass/skip status for all checks
- Overall verdict: "All critical checks passed" or specific failures

### validate-vms.sh
Quick validation script for verifying cloned VM configurations without redeployment:

- Private IP address verification
- Availability zone assignment
- VM size confirmation
- Extension installation status with version
- Accelerated networking validation
- Data disk count verification

### install-monitoring-extension.sh
Standalone extension installer (now integrated into main clone script, kept for reference)

## 📦 Prerequisites

### Required Tools
- **Azure CLI** (`az`) - logged in with appropriate subscription access
- **jq** - JSON processor
- **python3** - for IP address calculations
- **curl** - for validation checks (optional but recommended)

### Azure Permissions
The executing account needs:
- Read access to source VM and resources
- Create/write access for target resource group
- Network contributor role for subnet operations
- VM contributor role for VM creation

## 🔧 Installation

```bash
# Clone the repository
git clone https://github.com/DarylsCorner/vm-clone-toolkit.git
cd vm-clone-toolkit

# Make scripts executable (if not already)
chmod +x clone-app-server.sh
chmod +x scripts/*.sh
```

**Directory Structure:**
```
vm-clone-toolkit/
├── clone-app-server.sh          # Main cloning script
├── scripts/                      # Helper and validation scripts
│   ├── validate-vms.sh          # Quick VM validation
│   ├── validate_aem_monitorx64linux.sh  # Extension health check
│   └── install-monitoring-extension.sh  # Standalone extension installer
└── README.md
```

## 📖 Usage

**Getting Help:**
All scripts include comprehensive `--help` documentation:

```bash
./clone-app-server.sh --help                    # Main cloning script help
bash scripts/validate-vms.sh --help             # VM validator help
bash scripts/install-monitoring-extension.sh --help  # Extension installer help
bash scripts/validate_aem_monitorx64linux.sh --help  # Extension validator help
```

### Basic VM Clone (Single Instance)

```bash
./clone-app-server.sh <source-rg> <source-vm-name> <new-vm-name>
```

**Example:**
```bash
./clone-app-server.sh RG-EASTUS sapdl1app01 sapdl1app02
```

### Multi-Instance VM Provisioning

Create multiple VMs from a single snapshot operation for improved efficiency:

```bash
./clone-app-server.sh <source-rg> <source-vm-name> --multi "vm1 vm2 vm3 ..."
```

**Example:**
```bash
# Create 3 VMs from sapdl1app01 (must provide full VM names)
./clone-app-server.sh RG-EASTUS sapdl1app01 --multi "sapdl1app02 sapdl1app03 sapdl1app04"
```

**Benefits:**
- Snapshots created once and reused across all VMs
- IP addresses allocated upfront for all VMs
- Sequential VM creation with clear progress tracking
- Individual log files per VM with consolidated summary
- Automatic zone distribution for high availability (alternates between zones 1 and 3)

**Performance:**
- Single VM: ~8-10 minutes
- Multi-instance: ~7-8 minutes per VM (sequential creation)
- Example: 4 VMs in ~30 minutes with zone distribution (1→3→1→3)

### Advanced Usage with All Parameters

**Single VM:**
```bash
./clone-app-server.sh <source-rg> <source-vm-name> <new-vm-name> \
  [target-rg] [location] [vm-size] [set-hostname] [log-dir]
```

**Multi-Instance:**
```bash
./clone-app-server.sh <source-rg> <source-vm-name> --multi "vm1 vm2 vm3" \
  [target-rg] [location] [vm-size] [set-hostname] [log-dir]
```

**Parameters:**
- `source-rg` - Source resource group (required)
- `source-vm-name` - Source VM name (required)
- `new-vm-name` - Target VM name (required for single-instance)
- `--multi "vm1 vm2 ..."` - Space-separated list of VM names (required for multi-instance)
- `target-rg` - Target resource group (optional, defaults to source-rg)
- `location` - Azure region (optional, defaults to source VM location)
- `vm-size` - VM size (optional, defaults to source VM size)
- `set-hostname` - Set hostname in guest OS (default: true, set to false to skip)
- `log-dir` - Log directory path (optional, default: current directory)

**Examples:**
```bash
# Single VM with custom settings
./clone-app-server.sh RG-EASTUS sapdl1app01 sapdl1app02 \
  RG-EASTUS eastus Standard_D4s_v5 true ./logs

# Multi-instance with custom settings
./clone-app-server.sh RG-EASTUS sapdl1app01 --multi "sapdl1app02 sapdl1app03 sapdl1app04" \
  RG-EASTUS eastus Standard_D4s_v5 true ./logs
```

### Validate Cloned VMs (Quick Check)

Use the validation script to verify VM configurations without redeployment:

```bash
# Validate multiple VMs at once
bash scripts/validate-vms.sh RG-EASTUS sapdl1app02 sapdl1app03 sapdl1app04

# Output shows for each VM:
# - Private IP address
# - Availability zone
# - VM size
# - Extension installed with version (e.g., MonitorX64Linux (1.93))
# - Accelerated networking status
# - Data disk count
```

### Validate Extension Health (Detailed)

```bash
# From your local machine, run validation inside source VM
az vm run-command invoke -g RG-EASTUS -n sapdl1app01 \
  --command-id RunShellScript \
  --scripts "@scripts/validate_aem_monitorx64linux.sh"

# From your local machine, run validation inside cloned VM
az vm run-command invoke -g RG-EASTUS -n sapdl1app02 \
  --command-id RunShellScript \
  --scripts "@scripts/validate_aem_monitorx64linux.sh"

# Alternative: SSH into VM and run directly
# Copy script to VM first
scp -i ~/.ssh/your-key.pem scripts/validate_aem_monitorx64linux.sh azureuser@<vm-ip-or-hostname>:~

# SSH into VM
ssh -i ~/.ssh/your-key.pem azureuser@<vm-ip-or-hostname>
sudo bash validate_aem_monitorx64linux.sh
```

## 🔍 What Gets Cloned

### ✅ Included
- OS disk (with all data and configuration)
- All data disks (with LUN positions and caching settings)
- VM size and configuration
- Availability zone placement
- License type
- Network interface configuration
- Accelerated networking settings
- Network Security Group associations
- VM extensions (MonitorX64Linux automatically installed if present on source)
- Guest OS hostname (automatically set to match new VM name)
- Resource naming patterns

### ❌ Not Included
- **VM identity** (managed identity - intentionally not cloned to avoid security/access conflicts)
- **Public IP addresses** (not cloned - can be created separately if needed)
- **Boot diagnostics settings** (not implemented - could be added)
- **VM insights/monitoring agents** (except MonitorX64Linux - not cloned)
- **MDE.Linux** (`Microsoft.Azure.AzureDefenderForServers`) — Microsoft Defender for Endpoint is **not cloned**. If the source VM has MDE.Linux installed (e.g. deployed by Terraform), it must be added manually post-clone: `az vm extension set -g <rg> --vm-name <vm> --name MDE.Linux --publisher Microsoft.Azure.AzureDefenderForServers`
- **Tags** (not implemented - could be added, easily done post-clone)
- **Backup policies** (not cloned - must be configured separately)
- **Custom RBAC roles** (assigned to VM resource - not cloned)

## 🛡️ Safety Features

### Shared Disk Protection
The script automatically detects and blocks cloning of VMs with shared disks (maxShares ≥ 2) to prevent:
- Cluster split-brain scenarios
- Data corruption in clustered configurations
- Unintended cluster state duplication

**Behavior:** Script exits with code 2 and logs the finding if shared disk detected.

### Error Handling
- `set -euo pipefail` ensures immediate exit on any error
- Comprehensive error messages with context
- JSON logging of both successful and failed operations
- Multi-instance mode: continues with remaining VMs if one fails
- Rollback not automatic - failed resources remain for troubleshooting

### Multi-Instance Validations
- **Duplicate Name Check**: Prevents creating VMs with duplicate names
- **IP Availability**: Validates subnet has enough IPs before starting
- **Sequential Processing**: Creates VMs one at a time for reliable error tracking
- **Per-VM Status**: Independent success/failure tracking for each VM

## 📊 Logging

### Log File Format

**Single Instance:**
```bash
<new-vm-name>-clone-<timestamp>.json
```

**Multi-Instance:**
```bash
<vm-name>-clone-<timestamp>.json  # One log per VM
```

Example: Creating 3 VMs generates 3 separate log files:
- `sapdl1app02-clone-20251230141409.json`
- `sapdl1app03-clone-20251230141409.json`
- `sapdl1app04-clone-20251230141409.json`

## 🔧 Script Workflow

### clone-app-server.sh Process

1. **Prerequisites Check** - Validates az, jq, python3 availability
2. **Source VM Discovery** - Fetches complete source VM configuration
3. **Shared Disk Safety Check** - Validates no shared disks attached
4. **Zone Selection** - Determines availability zone (multi-instance: rotates between 1 and 3)
5. **IP Address Selection** - Calculates next available static IP(s)
6. **OS Disk Clone** - Creates snapshot → creates new disk in target zone
7. **Data Disk Clone** - Snapshots and recreates all data disks in target zone
8. **NIC Creation** - Creates NIC with static IP and accelerated networking
9. **VM Creation** - Assembles new VM with all components
10. **Hostname Configuration** - Updates guest hostname to match VM name
11. **Extension Installation** - Installs MonitorX64Linux if source has it
12. **Configuration Validation** - Queries actual VM settings (zone, extension, accelerated networking)
13. **Summary & Logging** - Displays validated results and saves JSON log

### Execution Time
- Single VM (2 disks): ~8 minutes
- Multi-instance (4 VMs, 2 disks each): ~30 minutes total (~7-8 min per VM)
- Time varies based on disk sizes, Azure region load, and zone distribution

## 🎯 Use Cases

### Development/Testing
- Clone production VMs to create test environments
- Rapid provisioning of multiple identical VMs
- Create sandbox environments for troubleshooting

### Disaster Recovery
- Quick VM recovery without full backup restore
- Maintain warm standby instances
- Geographic redundancy via cross-region cloning

### SAP Environments
- Clone SAP application servers
- Horizontal scaling of app server tiers
- Test system refreshes from production

### Migration & Upgrades
- Create clones before major changes
- Side-by-side comparisons during migrations
- Blue/green deployment scenarios

## ⚠️ Important Notes

### Network Considerations
- **IP Addressing**: Script assigns next available IP in subnet - verify no conflicts
- **DNS Updates**: Update DNS records manually after cloning
- **Load Balancers**: Backend pool membership not copied
- **Application Gateways**: Backend target configuration not copied

### Extension Behavior
- MonitorX64Linux installs with latest version
- Extension installation polls for 5 minutes max 
- Failed extension installation doesn't block VM creation
- Other extensions are not cloned

### Resource Naming
- New resources follow source naming patterns via string replacement
- Pattern: `${SOURCE_NAME/$SOURCE_VM_NAME/$NEW_VM_NAME}`
- Example: `app01423-nic` becomes `app02423-nic`
- Works with NICs, OS disks, and data disks

### Cleanup After Testing
```bash
# Delete VM and associated resources
az vm delete -g RG-EASTUS -n sapdl1app02 --yes --no-wait

# Clean up NICs
az network nic list -g RG-EASTUS \
  --query "[?contains(name, 'app02')].name" -o tsv | \
  ForEach-Object { az network nic delete -g RG-EASTUS -n $_ --no-wait }

# Clean up disks
az disk list -g RG-EASTUS \
  --query "[?contains(name, 'app02')].name" -o tsv | \
  ForEach-Object { az disk delete -g RG-EASTUS -n $_ --no-wait }

# Clean up snapshots
az snapshot list -g RG-EASTUS \
  --query "[?contains(name, 'app')].name" -o tsv | \
  ForEach-Object { az snapshot delete -g RG-EASTUS -n $_ --no-wait }
```

## 🐛 Troubleshooting

### Common Issues

**1. "No available IPs found in subnet"**
- Solution: Expand subnet CIDR or remove unused NICs
- Check: Verify subnet isn't at capacity

**2. "Extension installation timeout"**
- Solution: Extension may still be provisioning in background
- Check: `az vm extension list -g <rg> --vm-name <vm>`
- Note: VM creation succeeds even if extension times out

**3. "Shared disk detected"**
- Solution: This is intentional protection - do not clone clustered VMs
- Alternative: Use Azure Site Recovery for clustered workloads

**4. Permission denied errors**
- Solution: Verify Azure RBAC permissions on both source and target resources
- Check: `az account show` confirms correct subscription

**5. Accelerated networking not enabled**
- Solution: Verify source VM size supports accelerated networking
- Check: Some VM sizes don't support this feature

### Debug Mode

Add debug output to scripts:
```bash
# Add to top of script after set -euo pipefail
set -x  # Enable debug tracing
```

### Validation Commands

```bash
# Verify VM settings match
az vm show -g RG-EASTUS -n sapdl1app01 \
  --query "{Name:name, Size:hardwareProfile.vmSize, License:licenseType}"
  
az vm show -g RG-EASTUS -n sapdl1app02 \
  --query "{Name:name, Size:hardwareProfile.vmSize, License:licenseType}"

# Check accelerated networking
az network nic show -g RG-EASTUS -n <nic-name> \
  --query "{Name:name, AccelNet:enableAcceleratedNetworking}"

# Verify extensions
az vm extension list -g RG-EASTUS --vm-name sapdl1app02 \
  --query "[].{Name:name, Status:provisioningState, Version:typeHandlerVersion}"
```

## 🔐 Security Best Practices

### Pre-Deployment
- ✅ Review Azure subscription limits before cloning multiple VMs
- ✅ Ensure source VM has no sensitive data that shouldn't be duplicated
- ✅ Verify target resource group has appropriate access controls
- ✅ Use least-privilege service principals for automation

### Post-Deployment
- ✅ Update cloned VM hostname and identity
- ✅ Regenerate SSH keys if present
- ✅ Update application configurations with new IP/hostname
- ✅ Review and update NSG rules if needed
- ✅ Configure monitoring and alerts
- ✅ Apply backup policies
- ✅ Update CMDB/inventory systems

### Script Security
- ✅ No hardcoded credentials or secrets
- ✅ Uses Azure CLI authentication (managed identity or user context)
- ✅ Error handling prevents information leakage
- ✅ Logs don't contain sensitive data
- ✅ All operations auditable via Azure Activity Log

## 📝 Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success - clone completed |
| 1 | General error (missing tools, invalid parameters, Azure API errors) |
| 2 | Shared disk detected - clone aborted for safety |

## 🤝 Contributing

Contributions welcome! Please:
1. Test thoroughly in non-production environments
2. Follow existing code style (bash best practices)
3. Update documentation for new features
4. Add validation logic where appropriate

## 📄 License

This project is provided as-is for use in Azure environments. Please review and test in your specific environment before production use.

## 🔗 Related Resources

- [Azure CLI Documentation](https://docs.microsoft.com/en-us/cli/azure/)
- [Azure VM Documentation](https://docs.microsoft.com/en-us/azure/virtual-machines/)
- [Azure Enhanced Monitoring Extension for SAP](https://docs.microsoft.com/en-us/azure/virtual-machines/workloads/sap/deployment-guide)
- [Azure Accelerated Networking](https://docs.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview)

## 📞 Support

For issues or questions:
1. Check the Troubleshooting section above
2. Review Azure Activity Log for API errors
3. Examine JSON log files for operation details
4. Validate prerequisites and permissions

---

**Version**: 1.0  
**Last Updated**: December 2025  
**Tested On**: SLES 15 VMs, Azure CLI 2.x, Windows 11 with VS Code terminal
