#!/bin/bash
#
# Fedora 43 Distrobox Setup for Confidential Computing Verification
#
# This script creates a Fedora 43 distrobox with Ansible and Dell iDRAC modules
# to verify Intel TDX or AMD SEV-SNP confidential computing on Dell servers.
# Note: Kernel parameters must be pre-configured on the host.
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

    # Create the main playbook for CoCo verification
    cat > "${ANSIBLE_PLAYBOOK_DIR}/configure_coco.yaml" << 'EOF'
---
- name: Detect System Configuration
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

    - name: Display note about kernel parameters
      ansible.builtin.debug:
        msg: "Note: Kernel parameters are already configured on this host. Skipping configuration."

- name: Query Dell iDRAC for BIOS settings
  hosts: dell_servers
  gather_facts: no
  collections:
    - dellemc.openmanage

  tasks:
    - name: Get iDRAC system information
      dellemc.openmanage.idrac_system_info:
        idrac_ip: "{{ inventory_hostname }}"
        idrac_user: "{{ ansible_user }}"
        idrac_password: "{{ ansible_password }}"
      register: idrac_info
      delegate_to: localhost
      when: false  # Set to true when you have iDRAC credentials configured

    - name: Display iDRAC system info
      ansible.builtin.debug:
        var: idrac_info
      when: false  # Set to true when you have iDRAC credentials configured
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
These playbooks detect and verify Intel TDX or AMD SEV-SNP confidential computing on Dell servers.

## Files
- `inventory.ini`: Ansible inventory file (configure your Dell iDRAC IPs here)
- `configure_coco.yaml`: Main playbook to detect CPU type and query iDRAC
- `verify_coco.yaml`: Verification playbook to check CoCo status

## Usage

### 1. Detect CPU and Query iDRAC
Run from inside the distrobox:
```bash
ansible-playbook -i inventory.ini configure_coco.yaml
```

### 2. Verify Configuration
Run verification:
```bash
ansible-playbook -i inventory.ini verify_coco.yaml
```

### 3. Query Dell iDRAC (Optional)
Edit `inventory.ini` to add your Dell iDRAC credentials, then enable the iDRAC tasks in `configure_coco.yaml` by setting `when: false` to `when: true`.

## Notes
- The playbooks automatically detect Intel vs AMD CPUs
- Kernel parameters are assumed to be already configured on the host
- BIOS settings for confidential computing must be enabled via iDRAC or BIOS setup
- No system reboot is required by these playbooks
EOF

    log_info "Ansible playbooks created in ${ANSIBLE_PLAYBOOK_DIR}"
}

# Function to display usage instructions
display_usage() {
    log_info "Setup complete! Here's how to use your new distrobox:"
    echo ""
    echo "1. Enter the distrobox:"
    echo "   distrobox enter ${DISTROBOX_NAME}"
    echo ""
    echo "2. Navigate to the playbooks directory:"
    echo "   cd ${ANSIBLE_PLAYBOOK_DIR}"
    echo ""
    echo "3. Detect CPU type and query iDRAC (optional):"
    echo "   ansible-playbook -i inventory.ini configure_coco.yaml"
    echo ""
    echo "4. Verify confidential computing configuration:"
    echo "   ansible-playbook -i inventory.ini verify_coco.yaml"
    echo ""
    echo "OR run the verification from the host:"
    echo "   $0 verify"
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
