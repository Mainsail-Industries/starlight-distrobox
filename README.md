# Fedora 43 Distrobox for Confidential Computing Verification

A comprehensive bash script that creates a Fedora 43 distrobox with Ansible and Dell iDRAC modules to verify Intel TDX or AMD SEV-SNP confidential computing on Dell servers.

## Overview

This solution automatically:
- Creates a Fedora 43 distrobox with systemd support
- Installs Ansible and Dell OpenManage modules
- Generates Ansible playbooks for confidential computing detection and verification
- Auto-detects Intel vs AMD CPUs
- Verifies confidential computing configuration (TDX or SEV-SNP)
- Provides tools to query Dell iDRAC for BIOS settings

## Requirements

- distrobox installed on the host system
- podman or docker as the container runtime
- Dell server with Intel or AMD CPU that supports confidential computing
- Root/sudo access for verification commands
- Host system must already have kernel parameters configured for confidential computing

## Installation & Setup

### Step 1: Create the Distrobox

Run the script to create and configure the distrobox:

```bash
./setup-coco-distrobox.sh create
```

This will:
- Create a Fedora 43 distrobox named `fedora-coco-ansible`
- Install Ansible and all required Python dependencies
- Install Dell OpenManage Python SDK (omsdk)
- Install the `dellemc.openmanage` Ansible collection
- Generate Ansible playbooks in `~/ansible-coco/`

### Step 2: Detect CPU Type

Enter the distrobox and run the detection playbook:

```bash
distrobox enter fedora-coco-ansible
cd ~/ansible-coco
ansible-playbook -i inventory.ini configure_coco.yaml
```

The playbook will:
- Detect your CPU vendor (Intel or AMD)
- Display CPU information
- Optionally query Dell iDRAC for BIOS settings (if configured)

### Step 3: Verify Configuration

Verify that confidential computing is enabled:

**Option A: From the host**
```bash
./setup-coco-distrobox.sh verify
```

**Option B: From inside the distrobox**
```bash
distrobox enter fedora-coco-ansible
cd ~/ansible-coco
ansible-playbook -i inventory.ini verify_coco.yaml
```

## Generated Files

The script creates the following files in `~/ansible-coco/`:

### 1. `configure_coco.yaml`
Main Ansible playbook that:
- Auto-detects Intel vs AMD CPU from `/proc/cpuinfo`
- Displays CPU vendor information
- Includes Dell iDRAC integration examples for querying BIOS settings
- Note: Kernel parameters are assumed to be already configured on the host

### 2. `verify_coco.yaml`
Verification playbook that checks:
- CPU vendor detection
- Confidential computing CPU flags in `/proc/cpuinfo`
- TDX/SEV initialization messages in `dmesg`
- IOMMU configuration and groups
- Kernel command line parameters
- SEV device presence at `/dev/sev` (AMD only)

### 3. `inventory.ini`
Ansible inventory file. Edit this to add your Dell iDRAC IPs for remote BIOS configuration:

```ini
[localhost]
127.0.0.1 ansible_connection=local

[dell_servers]
# Add your Dell iDRAC IPs here, for example:
# idrac1.example.com ansible_user=root ansible_password=password
```

### 4. `README.md`
Documentation for the Ansible playbooks

## Script Commands

### Create Mode (Default)
```bash
./setup-coco-distrobox.sh create
```
Creates the distrobox, installs Ansible and dependencies, and generates playbooks.

### Verify Mode
```bash
./setup-coco-distrobox.sh verify
```
Runs verification checks on the host system to confirm confidential computing is enabled.

## What Gets Verified

### Intel TDX Verification
- ✓ TDX CPU flag in `/proc/cpuinfo`
- ✓ `virt/tdx: module initialized` message in dmesg
- ✓ TDX private KeyID range detection
- ✓ IOMMU groups configuration

### AMD SEV-SNP Verification
- ✓ SEV/SME CPU flags in `/proc/cpuinfo`
- ✓ `sev enabled` and `SEV-SNP API` messages in dmesg
- ✓ CCP (AMD Secure Processor) initialization
- ✓ `/dev/sev` device presence
- ✓ IOMMU groups configuration

## Dell iDRAC Integration

To query Dell iDRAC for BIOS settings and system information:

1. Edit `~/ansible-coco/inventory.ini` and add your iDRAC credentials:
```ini
[dell_servers]
idrac1.example.com ansible_user=root ansible_password=yourpassword
```

2. Enable the iDRAC tasks in `configure_coco.yaml` by changing:
```yaml
when: false  # Set to true when you have iDRAC credentials configured
```
to:
```yaml
when: true  # iDRAC credentials configured
```

3. Run the playbook:
```bash
ansible-playbook -i inventory.ini configure_coco.yaml
```

## Technical Details

### Intel TDX Verification
- Expected kernel parameters: `intel_iommu=on tdx_host=on` (must be pre-configured)
- Verifies TDX kernel module is loaded
- Requires BIOS enablement of Intel TDX
- Checks dmesg for: `virt/tdx: module initialized`

### AMD SEV-SNP Verification
- Expected kernel parameters: `iommu=pt mem_encrypt=on kvm_amd.sev=1` (must be pre-configured)
- Verifies CCP (Cryptographic Co-Processor) module
- Requires BIOS enablement of AMD SEV-SNP
- Checks dmesg for: `SEV-SNP API` version information

### Distrobox Configuration
- Image: `registry.fedoraproject.org/fedora:43`
- Init system: systemd enabled
- Network: host network access for Dell iDRAC connectivity
- Filesystem: host HOME directory mounted

## Troubleshooting

### Distrobox fails to create
```bash
# Check if podman/docker is running
podman ps
# or
docker ps

# Check distrobox version
distrobox version
```

### Ansible collection not found
```bash
# Manually install the Dell collection
distrobox enter fedora-coco-ansible
ansible-galaxy collection install dellemc.openmanage --upgrade
```

### Confidential computing not detected

1. **Check BIOS settings**: Confidential computing must be enabled in BIOS/UEFI
   - Intel: Enable "Intel TDX" or "Trust Domain Extensions"
   - AMD: Enable "SEV-SNP" or "Secure Encrypted Virtualization"

2. **Check kernel parameters are configured**:
```bash
cat /proc/cmdline
# Intel should show: intel_iommu=on tdx_host=on
# AMD should show: iommu=pt mem_encrypt=on kvm_amd.sev=1
```

3. **Check dmesg for errors**:
```bash
# Intel
dmesg | grep -i tdx

# AMD
dmesg | grep -iE "sev|ccp"
```

4. **Verify CPU support**:
```bash
# Intel
grep tdx /proc/cpuinfo

# AMD
grep -E "sev|sme" /proc/cpuinfo
```

### iDRAC connection fails
- Verify network connectivity: `ping idrac-ip`
- Verify credentials in `inventory.ini`
- Check Dell OpenManage collection: `ansible-galaxy collection list | grep dellemc`
- Install OMSDK: `pip3 install --user omsdk --upgrade`

## Important Notes

- **Pre-configured Host**: These playbooks assume kernel parameters are already configured on the host
- **BIOS Configuration Required**: Confidential computing features must be enabled in the BIOS/UEFI settings
- **Verification Only**: The playbooks detect CPU type and verify CoCo configuration, they do not modify system settings
- **Root Access**: The verification playbook requires sudo/root privileges for reading system information
- **Production Use**: Safe to use in production as no system modifications are made

## System Requirements

### Minimum Requirements
- Fedora, RHEL, or compatible Linux distribution on host
- 4GB RAM (for distrobox)
- 10GB free disk space
- Internet connectivity for package installation

### Dell Server Requirements
- Dell PowerEdge server with iDRAC 8 or newer
- Intel CPU with TDX support (4th Gen Xeon Scalable or newer)
  OR
- AMD CPU with SEV-SNP support (EPYC 7003 series or newer)
- BIOS/UEFI with confidential computing support
- Network access to iDRAC interface

## References & Documentation

- [Distrobox Official Documentation](https://distrobox.it/)
- [Distrobox GitHub](https://github.com/89luca89/distrobox)
- [Dell OpenManage Ansible Modules](https://github.com/dell/dellemc-openmanage-ansible-modules)
- [Intel TDX Linux Kernel Documentation](https://docs.kernel.org/arch/x86/tdx.html)
- [AMD SEV Documentation](https://github.com/AMDESE/AMDSEV)
- [Intel TDX Enabling Guide](https://cc-enabling.trustedservices.intel.com/intel-tdx-enabling-guide/)
- [Dell OpenManage Ansible User Guide](https://www.dell.com/support/manuals/en-us/openmanage-ansible-modules/)

## Quick Start Summary

```bash
# 1. Create distrobox and install everything
./setup-coco-distrobox.sh create

# 2. Detect CPU type
distrobox enter fedora-coco-ansible
cd ~/ansible-coco
ansible-playbook -i inventory.ini configure_coco.yaml

# 3. Verify confidential computing
./setup-coco-distrobox.sh verify
# OR from inside distrobox:
ansible-playbook -i inventory.ini verify_coco.yaml
```

## Support & Contribution

For issues or questions:
- Check the Troubleshooting section
- Review Dell OpenManage and distrobox documentation
- Verify BIOS settings for confidential computing features

## License

This script is provided as-is for use with Dell PowerEdge servers and confidential computing configuration.
