# Azure VM Clone Toolkit

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/bash-5.0%2B-green.svg)](https://www.gnu.org/software/bash/)
[![Azure CLI](https://img.shields.io/badge/Azure%20CLI-2.x-0078D4.svg)](https://docs.microsoft.com/en-us/cli/azure/)
[![Tested on SLES](https://img.shields.io/badge/tested-SLES%2015-0C322C.svg)](https://www.suse.com/products/server/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/DarylsCorner/vm-clone-toolkit/pulls)

Toolkit for cloning Azure Linux VMs with disk snapshots, accelerated networking, and extension management.

## 📋 Overview

This repository contains scripts to safely clone Azure Linux VMs (tested with SLES 15) including:
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
- **Smart Networking**: 
  - Automatically selects next available private IP
  - Maintains accelerated networking settings
  - Preserves NSG associations
  - Supports availability zone placement
- **Resource Naming**: Matches source VM naming patterns (e.g., `app01423_z1` → `app02423_z1`)
- **Extension Management**: Automatically installs MonitorX64Linux if present on source VM
- **Hostname Configuration**: Sets hostname in guest OS to match new VM name (default: enabled)
- **Safety Gates**: Blocks cloning of VMs with shared disks to prevent cluster conflicts
- **Comprehensive Logging**: JSON logs with full pre/post configuration metadata

### validate_aem_monitorx64linux.sh
Extension health validation script that checks:

- Extension files and manifest presence
- Running processes and daemons
- Metrics endpoint availability (port 11812)
- Legacy PerfCounters (if applicable)
- Azure Instance Metadata Service integration
- Optional saposcol detection

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
chmod +x validate_aem_monitorx64linux.sh
chmod +x install-monitoring-extension.sh
```

## 📖 Usage

### Basic VM Clone

```bash
./clone-app-server.sh <source-rg> <source-vm-name> <new-vm-name>
```

**Example:**
```bash
./clone-app-server.sh RG-EASTUS sapdl1app01 sapdl1app02
```

### Advanced Usage with All Parameters

```bash
./clone-app-server.sh <source-rg> <source-vm-name> <new-vm-name> \
  [target-rg] [location] [vm-size] [set-hostname] [log-dir]
```

**Parameters:**
- `source-rg` - Source resource group (required)
- `source-vm-name` - Source VM name (required)
- `new-vm-name` - Target VM name (required)
- `target-rg` - Target resource group (optional, defaults to source-rg)
- `location` - Azure region (optional, defaults to source VM location)
- `vm-size` - VM size (optional, defaults to source VM size)
- `set-hostname` - Set hostname in guest OS (default: true, set to false to skip)
- `log-dir` - Log directory path (optional, default: current directory)

**Example:**
```bash
./clone-app-server.sh RG-EASTUS sapdl1app01 sapdl1app02 \
  RG-EASTUS eastus Standard_D4s_v5 true ./logs
```

### Validate Extension Health

```bash
# From your local machine, run validation inside source VM
az vm run-command invoke -g RG-EASTUS -n sapdl1app01 \
  --command-id RunShellScript \
  --scripts "@validate_aem_monitorx64linux.sh"

# From your local machine, run validation inside cloned VM
az vm run-command invoke -g RG-EASTUS -n sapdl1app02 \
  --command-id RunShellScript \
  --scripts "@validate_aem_monitorx64linux.sh"

# Alternative: SSH into VM and run directly
# Copy script to VM first
scp -i ~/.ssh/your-key.pem validate_aem_monitorx64linux.sh azureuser@<vm-ip-or-hostname>:~

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
- Rollback not automatic - failed resources remain for troubleshooting

## 📊 Logging

### Log File Format
Each clone operation generates a JSON log file:

```bash
clone-<new-vm-name>-<timestamp>.json
```

**Log Contents:**
```json
{
  "timestamp": "20251219193000",
  "source": {
    "resourceGroup": "RG-EASTUS",
    "vmName": "sapdl1app01",
    "location": "eastus",
    "vmSize": "Standard_D2s_v3"
  },
  "target": {
    "resourceGroup": "RG-EASTUS",
    "vmName": "sapdl1app02",
    "vmSize": "Standard_D2s_v3"
  },
  "preConfig": {
    "osDisk": "...",
    "dataDisks": [...],
    "networkInterface": "...",
    "acceleratedNetworking": true
  },
  "postConfig": {
    "vmId": "...",
    "privateIP": "10.0.0.4",
    "monitoringExtension": "Succeeded"
  },
  "safety": {
    "sharedDiskCheck": "passed",
    "findings": []
  },
  "status": "completed"
}
```

## 🔧 Script Workflow

### clone-app-server.sh Process

1. **Prerequisites Check** - Validates az, jq, python3 availability
2. **Source VM Discovery** - Fetches complete source VM configuration
3. **Shared Disk Safety Check** - Validates no shared disks attached
4. **IP Address Selection** - Calculates next available static IP
5. **OS Disk Clone** - Creates snapshot → creates new disk
6. **Data Disk Clone** - Snapshots and recreates all data disks
7. **NIC Creation** - Creates NIC with static IP and accelerated networking
8. **VM Creation** - Assembles new VM with all components
9. **Extension Installation** - Installs MonitorX64Linux if source has it
10. **Hostname Configuration** - Updates guest hostname (optional)
11. **Summary & Logging** - Displays results and saves JSON log

### Execution Time
- Small VM (2 disks): ~3-5 minutes
- Large VM (8+ disks): ~8-12 minutes
- Time varies based on disk sizes and Azure region load

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
- Example: `app01423_z1` becomes `app02423_z1`
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
