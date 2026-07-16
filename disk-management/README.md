# disk-management

Azure VM disk management scripts for attaching and configuring data disks on Linux VMs.
All scripts require the Azure CLI (`az`) to be installed and authenticated.

---

> **⚠ Important: SDAF-managed VMs**
>
> These scripts add disks **outside of Terraform**, which means the new disks will **not be tracked in the SDAF state file**. For VMs managed by SDAF:
>
> - A subsequent `terraform apply` may attempt to **remove** manually added disks as untracked resources
> - SDAF Ansible playbooks determine disk configuration from Terraform outputs and will **not configure disks** that are not in the state
>
> **For SDAF-managed VMs, the correct approach is:**
> 1. Update `custom_disk_sizes_filename` in the system tfvars with the new disk layout
> 2. Re-run pipeline `03-sap-system-deployment.yml` — Terraform provisions the disks and records them in state
> 3. Re-run pipeline `05-DB-and-SAP-installation.yml` — Ansible configures the newly provisioned disks
>
> **These scripts are appropriate for:**
> - VMs provisioned outside of SDAF
> - Post-installation capacity expansion on running SAP systems where OS configuration is handled manually
> - Lab and test environments where Terraform state drift is acceptable

---

## Scripts

### 1. `add-disks-simple.sh` — Quick attach (no LVM)

Creates and attaches one or more disks of the same size to a VM. No on-VM configuration — use when the OS, Ansible, or another tool will handle disk setup.

```bash
# Attach a single 256GB disk
./add-disks-simple.sh \
  --vm myvm --rg my-rg --location swedencentral \
  --size 256

# Attach 3x512GB disks named backup-01, backup-02, backup-03
./add-disks-simple.sh \
  --vm myvm --rg my-rg --location swedencentral \
  --count 3 --size 512 --name backup

# Preview without making changes
./add-disks-simple.sh \
  --vm myvm --rg my-rg --location swedencentral \
  --count 2 --size 512 --dry-run
```

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `--vm` | ✓ | | VM name |
| `--rg` | ✓ | | Resource group |
| `--location` | ✓ | | Azure region |
| `--count` | | `1` | Number of disks |
| `--size` | | `128` | Size in GB |
| `--sku` | | `Premium_LRS` | `Premium_LRS`, `StandardSSD_LRS`, `UltraSSD_LRS` |
| `--caching` | | `ReadOnly` | `ReadOnly`, `None`, `ReadWrite` |
| `--name` | | `<vm>-disk` | Disk name prefix |
| `--lun-start` | | `0` | Starting LUN (auto-skips used LUNs) |
| `--dry-run` | | | Preview only, no changes |

---

### 2. `add-disks-param.sh` — Parameterised with LVM + auto-mount

Creates and attaches disks, then SSHs into the VM and configures LVM, filesystem, and `/etc/fstab` automatically. All disks in one run are striped into a single volume group.

```bash
# Add 2x512GB for /usr/sap on an app server
./add-disks-param.sh \
  --vm <app-vm-name> --rg <resource-group> \
  --location <region> --ip <vm-private-ip> \
  --count 2 --size 512 --mount /usr/sap \
  --vg vg_usrsap --lv lv_usrsap

# Add 4x1TB striped HANA data disks
./add-disks-param.sh \
  --vm <db-vm-name> --rg <resource-group> \
  --location <region> --ip <vm-private-ip> \
  --count 4 --size 1024 \
  --mount /hana/data --vg vg_hana_data --lv lv_hana_data

# Add 2x512GB HANA log disks (no caching, start at LUN 10)
./add-disks-param.sh \
  --vm <db-vm-name> --rg <resource-group> \
  --location <region> --ip <vm-private-ip> \
  --count 2 --size 512 --caching None \
  --mount /hana/log --vg vg_hana_log --lv lv_hana_log \
  --suffix hanalog --lun-start 10

# Dry run preview
./add-disks-param.sh --vm <vm-name> ... --dry-run
```

**Parameters:**

| Parameter | Required | Default | Description |
|---|---|---|---|
| `--vm` | ✓ | | VM name |
| `--rg` | ✓ | | Resource group |
| `--location` | ✓ | | Azure region |
| `--ip` | ✓ | | VM private IP for SSH |
| `--count` | | `2` | Number of disks |
| `--size` | | `512` | Size in GB |
| `--sku` | | `Premium_LRS` | Disk SKU |
| `--caching` | | `ReadOnly` | `ReadOnly` (data), `None` (log) |
| `--mount` | | `/data` | Mount point |
| `--vg` | | `vg_data` | LVM volume group name |
| `--lv` | | `lv_data` | LVM logical volume name |
| `--fs` | | `xfs` | Filesystem type |
| `--suffix` | | `datadisk` | Disk name suffix |
| `--lun-start` | | `0` | Preferred starting LUN |
| `--key` | | `~/.ssh/id_rsa` | SSH private key path |
| `--user` | | `azureadm` | SSH username |
| `--iops` | | | Custom IOPS (UltraSSD only) |
| `--mbps` | | | Custom throughput MB/s (UltraSSD only) |
| `--dry-run` | | | Preview only, no changes |

---

### 3. `add-disks-layout.sh` — Predefined multi-disk layout with LVM + auto-mount

For complex layouts with mixed disk sizes, names, and multiple volume groups (e.g. replicating an existing VM's disk layout). Edit the `DISK_CONFIGS` array at the top of the script before running.

```bash
# Edit parameters at the top of the script, then run:
./add-disks-layout.sh
```

**Config format:**
```bash
DISK_CONFIGS=(
    "SUFFIX:SIZE_GB:LUN:CACHING:VG_NAME:LV_NAME:MOUNT_POINT"
)

# Example:
DISK_CONFIGS=(
    "DDB1:1250:1:ReadOnly:vg_dbdata:lv_dbdata:/db/data"
    "DDB2:1250:2:ReadOnly:vg_dbdata:lv_dbdata:/db/data"  # same VG = striped
    "cache:2048:3:ReadOnly:vg_cache:lv_cache:/db/cache"
    "jobs:128:4:None:vg_jobs:lv_jobs:/db/work"
)
```

> Disks sharing the same `VG_NAME` are automatically striped into one logical volume.

---

## Caching Reference

| Disk purpose | Recommended caching |
|---|---|
| OS disk | `ReadWrite` |
| HANA data | `ReadOnly` |
| HANA log | `None` |
| HANA shared | `ReadOnly` |
| `/usr/sap` | `ReadOnly` |
| Backup | `None` |

## LUN Assignment

All scripts automatically detect which LUNs are already in use on the VM and skip them. The `--lun-start` parameter sets the preferred starting point — use different ranges for different disk groups to keep layouts predictable:

| Disk group | Suggested `--lun-start` |
|---|---|
| `/hana/data` | `0` |
| `/hana/log` | `10` |
| `/hana/shared` | `20` |
| `/usr/sap` | `30` |
| Backup | `40` |

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Contributor access to the VM's resource group
- For `add-disks-param.sh` and `add-disks-layout.sh`: SSH access from the deployer to the target VM

## Notes

- All scripts auto-detect the VM's availability zone and create disks in the same zone
- If a mount point already has an entry in `/etc/fstab`, a warning is printed and the entry is **not** overwritten — review manually if needed
- SDAF VM names include the resource group prefix (e.g. `<RG>_<vm-short-name>`) — use the full name with `--vm`
