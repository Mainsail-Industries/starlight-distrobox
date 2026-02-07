#!/bin/bash
#
# Fedora 43 Distrobox Setup for Confidential Computing Configuration
#
# This script creates a Fedora 43 distrobox with Ansible and Dell iDRAC modules
# to configure Dell BIOS for Intel TDX or AMD SEV-SNP confidential computing.
# The playbooks configure BIOS via iDRAC, then verify after reboot.
#
# Usage:
#   ./setup-coco-distrobox.sh create    # Create and setup the distrobox
#   ./setup-coco-distrobox.sh verify    # Verify confidential computing is enabled
#

set -euo pipefail

# Configuration
DISTROBOX_NAME="fedora-coco-ansible"
FEDORA_VERSION="43"
ANSIBLE_PLAYBOOK_DIR="$HOME/ansible-coco"
DISTROBOX_IMAGE="registry.fedoraproject.org/fedora:${FEDORA_VERSION}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to create the distrobox
create_distrobox() {
    log_info "Creating Fedora ${FEDORA_VERSION} distrobox: ${DISTROBOX_NAME}"

    # Check if distrobox already exists
    if distrobox list | grep -q "${DISTROBOX_NAME}"; then
        log_warn "Distrobox ${DISTROBOX_NAME} already exists. Removing it first..."
        distrobox rm -f "${DISTROBOX_NAME}"
    fi

    # Create the distrobox with init support and necessary packages
    log_info "Creating distrobox container..."
    distrobox create \
        --name "${DISTROBOX_NAME}" \
        --image "${DISTROBOX_IMAGE}" \
        --init \
        --yes \
        --additional-packages "systemd ansible python3-pip python3-devel gcc redhat-rpm-config openssl-devel libcurl-devel python3-requests" \
        || {
            log_error "Failed to create distrobox"
            exit 1
        }

    log_info "Distrobox created successfully"
}

# Function to setup Ansible and dependencies inside distrobox
setup_ansible() {
    log_info "Setting up Ansible and Dell iDRAC modules in distrobox..."

    # Enter distrobox and setup Ansible
    distrobox enter "${DISTROBOX_NAME}" -- bash -c '
        set -euo pipefail

        echo "[INFO] Updating system packages..."
        sudo dnf update -y

        echo "[INFO] Installing additional Python dependencies..."
        sudo dnf install -y python3-netaddr python3-jmespath

        echo "[INFO] Installing Dell OpenManage Python SDK..."
        pip3 install --user omsdk --upgrade

        echo "[INFO] Installing Dell OpenManage Ansible Collection..."
        ansible-galaxy collection install dellemc.openmanage --upgrade

        echo "[INFO] Verifying Ansible installation..."
        ansible --version

        echo "[INFO] Verifying Dell OpenManage collection..."
        ansible-galaxy collection list | grep dellemc.openmanage || echo "Collection may need manual verification"

        echo "[INFO] Setup complete!"
    '

    if [ $? -eq 0 ]; then
        log_info "Ansible and Dell iDRAC modules installed successfully"
    else
        log_error "Failed to setup Ansible inside distrobox"
        exit 1
    fi
}

# Function to create Ansible playbook directory and files
create_ansible_playbooks() {
    log_info "Creating Ansible playbooks for confidential computing setup..."

    # Create playbook directory on host
    mkdir -p "${ANSIBLE_PLAYBOOK_DIR}"

    # Create inventory file
    cat > "${ANSIBLE_PLAYBOOK_DIR}/inventory.ini" << 'EOF'
[localhost]
127.0.0.1 ansible_connection=local

[dell_servers]
# Add your Dell iDRAC IPs here, for example:
# idrac1.example.com ansible_user=root ansible_password=password
EOF

    # Create the main playbook for CoCo BIOS configuration
    cat > "${ANSIBLE_PLAYBOOK_DIR}/configure_coco.yaml" << 'EOF'
---
- name: Detect CPU Type on Local Host
  hosts: localhost
  gather_facts: yes
  become: yes

  tasks:
    - name: Gather CPU information
      ansible.builtin.command: cat /proc/cpuinfo
      register: cpuinfo_output
      changed_when: false

    - name: Detect CPU vendor
      ansible.builtin.set_fact:
        is_intel: "{{ 'GenuineIntel' in cpuinfo_output.stdout }}"
        is_amd: "{{ 'AuthenticAMD' in cpuinfo_output.stdout }}"

    - name: Display detected CPU vendor
      ansible.builtin.debug:
        msg: "Detected CPU: {{ 'Intel' if is_intel else 'AMD' if is_amd else 'Unknown' }}"

    - name: Fail if CPU vendor is not Intel or AMD
      ansible.builtin.fail:
        msg: "This playbook only supports Intel or AMD processors"
      when: not (is_intel or is_amd)

    - name: Set CPU vendor fact for use in other plays
      ansible.builtin.set_fact:
        cpu_vendor: "{{ 'intel' if is_intel else 'amd' if is_amd else 'unknown' }}"
        cacheable: yes

- name: Configure Dell BIOS for Confidential Computing
  hosts: dell_servers
  gather_facts: no
  collections:
    - dellemc.openmanage
  vars:
    cpu_vendor: "{{ hostvars['localhost']['cpu_vendor'] }}"

  tasks:
    - name: Display target server and CPU type
      ansible.builtin.debug:
        msg: "Configuring {{ inventory_hostname }} for {{ cpu_vendor | upper }} Confidential Computing"

    - name: Get current BIOS configuration
      dellemc.openmanage.idrac_system_info:
        idrac_ip: "{{ inventory_hostname }}"
        idrac_user: "{{ ansible_user }}"
        idrac_password: "{{ ansible_password }}"
        validate_certs: no
      register: system_info
      delegate_to: localhost

    - name: Display current system information
      ansible.builtin.debug:
        msg:
          - "Model: {{ system_info.system_info.Model | default('Unknown') }}"
          - "Service Tag: {{ system_info.system_info.ServiceTag | default('Unknown') }}"
          - "BIOS Version: {{ system_info.system_info.BiosVersion | default('Unknown') }}"

    # Intel TDX BIOS Configuration
    - name: Configure BIOS for Intel TDX
      dellemc.openmanage.idrac_bios:
        idrac_ip: "{{ inventory_hostname }}"
        idrac_user: "{{ ansible_user }}"
        idrac_password: "{{ ansible_password }}"
        validate_certs: no
        attributes:
          MemOpMode: "OptimizerMode"  # Memory Operating Mode
          MemEncryption: "MultiKey"   # Memory Encryption - required for TDX
          GlobalMemIntegrity: "Disabled"  # Must be disabled for TDX
          IntelTdx: "Enabled"  # Intel Trusted Domain Extensions
          IntelTdxKeySplit: "1"  # TME-MT/TDX Key Split (non-zero value)
          TdxSeamLoader: "Enabled"  # TDX Secure Arbitration Mode Loader
          SriovGlobalEnable: "Enabled"  # SR-IOV support
          VtForDirectIo: "Enabled"  # Intel VT-d
          ProcVirtualization: "Enabled"  # Intel VT
        apply_time: Immediate
        job_wait: true
        job_wait_timeout: 1200
      delegate_to: localhost
      register: intel_bios_result
      when: cpu_vendor == 'intel'

    - name: Display Intel BIOS configuration result
      ansible.builtin.debug:
        msg:
          - "BIOS Configuration Status: {{ intel_bios_result.msg | default('N/A') }}"
          - "Job Status: {{ intel_bios_result.job_details.JobState | default('N/A') }}"
      when: cpu_vendor == 'intel' and intel_bios_result is defined

    # AMD SEV-SNP BIOS Configuration
    - name: Configure BIOS for AMD SEV-SNP
      dellemc.openmanage.idrac_bios:
        idrac_ip: "{{ inventory_hostname }}"
        idrac_user: "{{ ansible_user }}"
        idrac_password: "{{ ansible_password }}"
        validate_certs: no
        attributes:
          MemOpMode: "OptimizerMode"  # Memory Operating Mode
          SecureMemoryEncryption: "Enabled"  # SME/SEV base feature
          SevSnp: "Enabled"  # SEV-SNP specific
          SnpMemCoverage: "Enabled"  # SNP Memory Coverage
          SriovGlobalEnable: "Enabled"  # SR-IOV support
          IommuSupport: "Enabled"  # IOMMU support
          ProcVirtualization: "Enabled"  # AMD-V
        apply_time: Immediate
        job_wait: true
        job_wait_timeout: 1200
      delegate_to: localhost
      register: amd_bios_result
      when: cpu_vendor == 'amd'

    - name: Display AMD BIOS configuration result
      ansible.builtin.debug:
        msg:
          - "BIOS Configuration Status: {{ amd_bios_result.msg | default('N/A') }}"
          - "Job Status: {{ amd_bios_result.job_details.JobState | default('N/A') }}"
      when: cpu_vendor == 'amd' and amd_bios_result is defined

    - name: Display reboot instruction
      ansible.builtin.debug:
        msg:
          - "=========================================="
          - "BIOS CONFIGURATION COMPLETE"
          - "=========================================="
          - "The server has been configured for Confidential Computing."
          - "A system reboot is REQUIRED for changes to take effect."
          - ""
          - "Please reboot the server now, then run the verification playbook:"
          - "  ansible-playbook -i inventory.ini verify_coco.yaml"
          - "=========================================="
EOF

    # Create verification playbook
    cat > "${ANSIBLE_PLAYBOOK_DIR}/verify_coco.yaml" << 'EOF'
---
- name: Verify Confidential Computing Configuration
  hosts: localhost
  gather_facts: yes
  become: yes

  tasks:
    - name: Gather CPU information
      ansible.builtin.command: cat /proc/cpuinfo
      register: cpuinfo_output
      changed_when: false

    - name: Detect CPU vendor
      ansible.builtin.set_fact:
        is_intel: "{{ 'GenuineIntel' in cpuinfo_output.stdout }}"
        is_amd: "{{ 'AuthenticAMD' in cpuinfo_output.stdout }}"

    - name: Display CPU vendor
      ansible.builtin.debug:
        msg: "CPU Vendor: {{ 'Intel' if is_intel else 'AMD' if is_amd else 'Unknown' }}"

    # Intel TDX Verification
    - name: Intel TDX verification tasks
      when: is_intel
      block:
        - name: Check TDX CPU flag
          ansible.builtin.shell: grep -c 'tdx' /proc/cpuinfo || true
          register: tdx_flag
          changed_when: false

        - name: Check TDX in dmesg
          ansible.builtin.shell: dmesg | grep -i tdx || echo "No TDX messages found"
          register: tdx_dmesg
          changed_when: false

        - name: Display Intel TDX status
          ansible.builtin.debug:
            msg:
              - "TDX CPU flag count: {{ tdx_flag.stdout }}"
              - "TDX dmesg output:"
              - "{{ tdx_dmesg.stdout_lines }}"

    # AMD SEV-SNP Verification
    - name: AMD SEV-SNP verification tasks
      when: is_amd
      block:
        - name: Check SEV CPU flags
          ansible.builtin.shell: grep -E 'sev|sme' /proc/cpuinfo | head -5 || echo "No SEV flags found"
          register: sev_flags
          changed_when: false

        - name: Check SEV in dmesg
          ansible.builtin.shell: dmesg | grep -iE 'sev|ccp' || echo "No SEV messages found"
          register: sev_dmesg
          changed_when: false

        - name: Check for SEV device
          ansible.builtin.stat:
            path: /dev/sev
          register: sev_device

        - name: Display AMD SEV-SNP status
          ansible.builtin.debug:
            msg:
              - "SEV CPU flags:"
              - "{{ sev_flags.stdout_lines }}"
              - "SEV dmesg output:"
              - "{{ sev_dmesg.stdout_lines }}"
              - "SEV device exists: {{ sev_device.stat.exists }}"

    # Common verification
    - name: Check IOMMU groups
      ansible.builtin.shell: find /sys/kernel/iommu_groups/ -type l 2>/dev/null | wc -l
      register: iommu_groups
      changed_when: false

    - name: Display IOMMU status
      ansible.builtin.debug:
        msg: "Number of IOMMU groups: {{ iommu_groups.stdout }}"

    - name: Check kernel command line
      ansible.builtin.command: cat /proc/cmdline
      register: cmdline
      changed_when: false

    - name: Display kernel command line
      ansible.builtin.debug:
        msg: "Kernel command line: {{ cmdline.stdout }}"
EOF

    # Create a README
    cat > "${ANSIBLE_PLAYBOOK_DIR}/README.md" << 'EOF'
# Confidential Computing Ansible Playbooks

## Overview
These playbooks configure Dell BIOS via iDRAC for Intel TDX or AMD SEV-SNP confidential computing, then verify the configuration after reboot.

## Files
- `inventory.ini`: Ansible inventory file (configure your Dell iDRAC IPs here)
- `configure_coco.yaml`: Configure Dell BIOS for confidential computing via iDRAC
- `verify_coco.yaml`: Verification playbook to check CoCo status after reboot

## Prerequisites
- Dell iDRAC credentials with BIOS configuration privileges
- Network access to iDRAC interface
- Dell OpenManage Ansible collection installed (already included)

## Usage

### Step 1: Configure inventory.ini
Edit `inventory.ini` and add your Dell server iDRAC IP addresses and credentials:

```ini
[dell_servers]
idrac1.example.com ansible_user=root ansible_password=yourpassword
# Add more servers as needed
```

### Step 2: Configure BIOS for Confidential Computing
Run from inside the distrobox:
```bash
ansible-playbook -i inventory.ini configure_coco.yaml
```

This playbook will:
- Detect your CPU type (Intel or AMD)
- Connect to Dell iDRAC
- Query current BIOS settings
- Configure appropriate BIOS settings for confidential computing:
  - **Intel**: TDX, Memory Encryption, VT-d, etc.
  - **AMD**: SEV-SNP, SME, IOMMU, etc.
- Create and execute BIOS configuration job
- Wait for job completion

### Step 3: Reboot the Server
After BIOS configuration completes, manually reboot the server:
```bash
sudo reboot
```

### Step 4: Verify Configuration
After the server comes back online, verify confidential computing is working:
```bash
ansible-playbook -i inventory.ini verify_coco.yaml
```

## BIOS Settings Configured

### Intel TDX
- Memory Encryption: MultiKey
- Global Memory Integrity: Disabled
- Intel TDX: Enabled
- TDX Key Split: 1
- TDX SEAM Loader: Enabled
- Intel VT-d: Enabled
- Intel VT: Enabled
- SR-IOV: Enabled

### AMD SEV-SNP
- Secure Memory Encryption: Enabled
- SEV-SNP: Enabled
- SNP Memory Coverage: Enabled
- IOMMU Support: Enabled
- AMD-V: Enabled
- SR-IOV: Enabled

## Troubleshooting

### iDRAC Connection Failed
- Verify network connectivity: `ping <idrac-ip>`
- Verify credentials in inventory.ini
- Check iDRAC is accessible via web browser

### BIOS Job Failed
- Check iDRAC job queue for errors
- Verify BIOS version supports confidential computing
- Review Dell support documentation for your server model

### Configuration Not Applied
- Ensure server was rebooted after BIOS configuration
- Check BIOS settings manually via iDRAC web interface
- Run verification playbook to see detailed status
EOF

    log_info "Ansible playbooks created in ${ANSIBLE_PLAYBOOK_DIR}"
}

# Function to display usage instructions
display_usage() {
    log_info "Setup complete! Here's how to use your new distrobox:"
    echo ""
    echo "1. Configure iDRAC credentials:"
    echo "   Edit ${ANSIBLE_PLAYBOOK_DIR}/inventory.ini"
    echo "   Add your Dell iDRAC IP addresses and credentials"
    echo ""
    echo "2. Enter the distrobox:"
    echo "   distrobox enter ${DISTROBOX_NAME}"
    echo ""
    echo "3. Configure BIOS for confidential computing:"
    echo "   cd ${ANSIBLE_PLAYBOOK_DIR}"
    echo "   ansible-playbook -i inventory.ini configure_coco.yaml"
    echo ""
    echo "4. Reboot the server:"
    echo "   sudo reboot"
    echo ""
    echo "5. After reboot, verify confidential computing:"
    echo "   $0 verify"
    echo "   OR: ansible-playbook -i inventory.ini verify_coco.yaml"
    echo ""
}

# Function to verify confidential computing is enabled
verify_coco() {
    log_info "Verifying Confidential Computing configuration..."

    # Check CPU vendor
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        log_info "Intel CPU detected - checking for TDX..."

        # Check for TDX CPU flag
        if grep -q "tdx" /proc/cpuinfo; then
            log_info "✓ TDX CPU flag found in /proc/cpuinfo"
        else
            log_warn "✗ TDX CPU flag NOT found in /proc/cpuinfo"
        fi

        # Check dmesg for TDX
        echo ""
        log_info "Checking dmesg for TDX initialization..."
        if dmesg | grep -i "tdx" | grep -q "initialized"; then
            log_info "✓ TDX module initialized"
            dmesg | grep -i "tdx" | tail -10
        else
            log_warn "TDX initialization messages:"
            dmesg | grep -i "tdx" || log_warn "No TDX messages found in dmesg"
        fi

    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        log_info "AMD CPU detected - checking for SEV-SNP..."

        # Check for SEV CPU flags
        if grep -qE "sev|sme" /proc/cpuinfo; then
            log_info "✓ SEV/SME CPU flags found in /proc/cpuinfo"
            grep -E "sev|sme" /proc/cpuinfo | head -3
        else
            log_warn "✗ SEV/SME CPU flags NOT found in /proc/cpuinfo"
        fi

        # Check dmesg for SEV
        echo ""
        log_info "Checking dmesg for SEV initialization..."
        if dmesg | grep -iE "sev|ccp" | grep -qE "enabled|initialized|API"; then
            log_info "✓ SEV module initialized"
            dmesg | grep -iE "sev|ccp" | grep -E "enabled|initialized|API|active"
        else
            log_warn "SEV initialization messages:"
            dmesg | grep -iE "sev|ccp" || log_warn "No SEV messages found in dmesg"
        fi

        # Check for SEV device
        if [ -e /dev/sev ]; then
            log_info "✓ /dev/sev device exists"
        else
            log_warn "✗ /dev/sev device not found"
        fi

    else
        log_error "Unknown CPU vendor"
        exit 1
    fi

    # Check IOMMU
    echo ""
    log_info "Checking IOMMU configuration..."
    iommu_count=$(find /sys/kernel/iommu_groups/ -type l 2>/dev/null | wc -l)
    if [ "$iommu_count" -gt 0 ]; then
        log_info "✓ IOMMU is enabled ($iommu_count groups found)"
    else
        log_warn "✗ IOMMU groups not found - IOMMU may not be enabled"
    fi

    # Display kernel command line
    echo ""
    log_info "Current kernel command line:"
    cat /proc/cmdline
    echo ""
}

# Main execution
main() {
    case "${1:-create}" in
        create)
            log_info "Starting Fedora ${FEDORA_VERSION} distrobox setup for Confidential Computing..."
            create_distrobox
            setup_ansible
            create_ansible_playbooks
            display_usage
            ;;
        verify)
            verify_coco
            ;;
        *)
            echo "Usage: $0 {create|verify}"
            echo "  create  - Create and setup the distrobox (default)"
            echo "  verify  - Verify confidential computing is enabled"
            exit 1
            ;;
    esac
}

main "$@"
