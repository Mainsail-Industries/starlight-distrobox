# Fedora 43 Distrobox for Confidential Computing Configuration

A comprehensive bash script that creates a Fedora 43 distrobox with Ansible and Dell iDRAC modules to configure and verify Intel TDX or AMD SEV-SNP confidential computing on Dell PowerEdge servers.

## Overview

This solution automatically:
- Creates a Fedora 43 distrobox with systemd support
- Installs Ansible and Dell OpenManage modules
- Generates Ansible playbooks to configure Dell BIOS via iDRAC
- Auto-detects Intel vs AMD CPUs
- Configures appropriate BIOS settings for confidential computing (TDX or SEV-SNP)
- Verifies confidential computing is enabled after reboot

## Requirements

- distrobox installed on the host system
- podman or docker as the container runtime
- Dell PowerEdge server with iDRAC 8 or newer
- Intel CPU with TDX support (5th Gen Xeon Scalable) or AMD CPU with SEV-SNP support (EPYC 7003+)
- Dell iDRAC credentials with BIOS configuration privileges
- Network access to iDRAC management interface
- Root/sudo access for verification commands

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

### Step 2: Configure iDRAC Credentials

Edit the inventory file to add your Dell iDRAC details:

```bash
cd ~/ansible-coco
nano inventory.ini
```

Add your iDRAC IP addresses and credentials:
```ini
[dell_servers]
10.0.0.100 ansible_user=root ansible_password=yourpassword
```

### Step 3: Configure BIOS for Confidential Computing

Enter the distrobox and run the configuration playbook:

```bash
distrobox enter fedora-coco-ansible
cd ~/ansible-coco
ansible-playbook -i inventory.ini configure_coco.yaml
```

The playbook will:
- Detect your CPU vendor (Intel or AMD) on localhost
- Connect to Dell iDRAC
- Query current BIOS settings
- Configure BIOS attributes for confidential computing
- Create and execute BIOS configuration job
- Wait for job completion

### Step 4: Reboot the Server

After BIOS configuration completes, reboot the server:
```bash
sudo reboot
```

### Step 5: Verify Configuration

After the server comes back online, verify that confidential computing is enabled:

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
Main Ansible playbook that configures Dell BIOS via iDRAC:
- Auto-detects Intel vs AMD CPU from `/proc/cpuinfo` on localhost
- Connects to Dell iDRAC on target servers
- Queries current BIOS configuration
- Configures BIOS attributes for confidential computing:
  - **Intel TDX**: Memory Encryption (MultiKey), Intel TDX, VT-d, SEAM Loader, etc.
  - **AMD SEV-SNP**: SEV-SNP, SME, IOMMU, SNP Memory Coverage, etc.
- Creates BIOS configuration job and waits for completion
- Provides reboot instructions

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

The playbooks use Dell OpenManage Ansible modules to configure BIOS settings via iDRAC.

### Required Credentials

You need iDRAC credentials with BIOS configuration privileges:
- Typically the `root` account or a user with Administrator privileges
- Network access to iDRAC IP address (usually separate management network)

### BIOS Settings Configured

The playbook automatically configures these BIOS attributes:

**Intel TDX:**
- Memory Encryption: MultiKey (required for TDX)
- Global Memory Integrity: Disabled (must be off for TDX)
- Intel TDX: Enabled
- TDX Key Split: 1 (non-zero value required)
- TDX SEAM Loader: Enabled
- Intel VT-d: Enabled (virtualization for I/O)
- Intel VT: Enabled (CPU virtualization)
- SR-IOV: Enabled

**AMD SEV-SNP:**
- Secure Memory Encryption: Enabled (base SME/SEV)
- SEV-SNP: Enabled
- SNP Memory Coverage: Enabled
- IOMMU Support: Enabled
- AMD-V: Enabled (CPU virtualization)
- SR-IOV: Enabled

### Job Execution

The playbook uses `apply_time: Immediate` and `job_wait: true` to:
1. Create a BIOS configuration job in iDRAC
2. Wait for the job to complete (up to 20 minutes)
3. Report job status

After completion, you must manually reboot the server for changes to take effect.

## Technical Details

### Intel TDX Configuration
- Uses `dellemc.openmanage.idrac_bios` module to configure BIOS
- Requires 5th Gen Intel Xeon Scalable processors (16th Gen PowerEdge or newer)
- Key BIOS attributes: `MemEncryption: MultiKey`, `IntelTdx: Enabled`, `IntelTdxKeySplit: 1`
- BIOS job is executed immediately and playbook waits for completion
- After reboot, kernel will initialize TDX with dmesg: `virt/tdx: module initialized`
- Requires kernel parameters: `intel_iommu=on tdx_host=on` (configure separately)

### AMD SEV-SNP Configuration
- Uses `dellemc.openmanage.idrac_bios` module to configure BIOS
- Requires AMD EPYC 7003 series or newer processors (15th Gen PowerEdge or newer)
- Key BIOS attributes: `SecureMemoryEncryption: Enabled`, `SevSnp: Enabled`, `IommuSupport: Enabled`
- BIOS job is executed immediately and playbook waits for completion
- After reboot, kernel will initialize SEV with dmesg: `SEV-SNP API` version
- Requires kernel parameters: `iommu=pt mem_encrypt=on kvm_amd.sev=1` (configure separately)

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
- Verify iDRAC is accessible via web browser: `https://idrac-ip`
- Check credentials in `inventory.ini` (need Administrator privileges)
- Verify Dell OpenManage collection: `ansible-galaxy collection list | grep dellemc`
- Install OMSDK if missing: `pip3 install --user omsdk --upgrade`
- Check firewall rules allow access to iDRAC (ports 443, 5900)

### BIOS configuration job fails
- Check iDRAC job queue via web interface
- Verify BIOS version supports confidential computing features
- Check iDRAC logs for detailed error messages
- Ensure no other BIOS configuration jobs are pending
- Try manually clearing the job queue in iDRAC

### Changes not applied after reboot
- Verify BIOS job completed successfully (check iDRAC job history)
- Check BIOS settings manually via iDRAC web interface: Configuration → BIOS Settings
- Ensure server was fully rebooted (not just iDRAC reset)
- Some BIOS settings may require multiple reboots to take effect

## Important Notes

- **BIOS Configuration via iDRAC**: The playbooks configure BIOS settings remotely via Dell iDRAC
- **Manual Reboot Required**: After BIOS configuration, you must manually reboot the server
- **Kernel Parameters**: The playbooks configure BIOS but do NOT configure kernel boot parameters - you must add these separately to GRUB
- **iDRAC Credentials**: You need Administrator-level iDRAC credentials to configure BIOS
- **Network Access**: iDRAC must be accessible over the network from where you run the playbook
- **BIOS Version**: Ensure your Dell server BIOS version supports confidential computing (check Dell support site)
- **Production Use**: Test in a non-production environment first, as BIOS changes can affect system stability

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

# 2. Configure iDRAC credentials
cd ~/ansible-coco
nano inventory.ini  # Add your iDRAC IPs and credentials

# 3. Configure BIOS via iDRAC
distrobox enter fedora-coco-ansible
cd ~/ansible-coco
ansible-playbook -i inventory.ini configure_coco.yaml

# 4. Reboot the server
sudo reboot

# 5. After reboot, verify confidential computing
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
