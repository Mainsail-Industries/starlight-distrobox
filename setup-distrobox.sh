#!/bin/bash
#
# Fedora 43 Distrobox Setup for Immutable Host Development
#
# Modular distrobox with optional tool categories:
#   --coco   Confidential Computing (Ansible + Dell iDRAC)
#   --dev    Development tools (CLI helpers, editors, toolchains)
#   --k8s    Kubernetes client tooling
#   --cloud  Cloud CLIs (aws, gcloud, az, doctl)
#   --virt   Virtualization (virt-manager, virt-viewer, virsh)
#   --full   All of the above
#
# Usage:
#   ./setup-distrobox.sh create --dev --k8s
#   ./setup-distrobox.sh create --full
#   ./setup-distrobox.sh create --coco --name fedora-coco
#   ./setup-distrobox.sh verify
#

set -euo pipefail

# Configuration
DISTROBOX_NAME="fedora-dev"
FEDORA_VERSION="43"
ANSIBLE_PLAYBOOK_DIR="$HOME/ansible-coco"
DISTROBOX_IMAGE="registry.fedoraproject.org/fedora:${FEDORA_VERSION}"

# Module flags
ENABLE_COCO=false
ENABLE_DEV=false
ENABLE_K8S=false
ENABLE_CLOUD=false
ENABLE_VIRT=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}=== $1 ===${NC}"; }

# --------------------------------------------------------------------------- #
# Help
# --------------------------------------------------------------------------- #
show_help() {
    cat <<'HELPEOF'
Usage: ./setup-distrobox.sh <command> [options]

Commands:
  create    Create and configure the distrobox (default)
  verify    Verify confidential computing is enabled (host-side)
  help      Show this help message

Module flags (used with create):
  --coco    Confidential Computing (Ansible, Dell iDRAC modules, playbooks)
  --dev     Development tools (CLI helpers, editors, language toolchains)
  --k8s     Kubernetes client tooling (kubectl, helm, kustomize, k9s)
  --cloud   Cloud CLIs (aws, gcloud, az, doctl)
  --virt    Virtualization (virt-manager, virt-viewer, virsh)
  --full    Enable all modules

Options:
  --name <name>   Override distrobox container name (default: fedora-dev)

Examples:
  ./setup-distrobox.sh create --dev --k8s
  ./setup-distrobox.sh create --full --name my-toolbox
  ./setup-distrobox.sh create --coco --name fedora-coco
  ./setup-distrobox.sh verify
HELPEOF
}

# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)  DISTROBOX_NAME="$2"; shift 2 ;;
            --coco)  ENABLE_COCO=true;  shift ;;
            --dev)   ENABLE_DEV=true;   shift ;;
            --k8s)   ENABLE_K8S=true;   shift ;;
            --cloud) ENABLE_CLOUD=true; shift ;;
            --virt)  ENABLE_VIRT=true;  shift ;;
            --full)
                ENABLE_COCO=true; ENABLE_DEV=true
                ENABLE_K8S=true;  ENABLE_CLOUD=true
                ENABLE_VIRT=true; shift ;;
            *)       shift ;;
        esac
    done
}

# --------------------------------------------------------------------------- #
# Build DNF package list based on enabled modules
# --------------------------------------------------------------------------- #
build_package_list() {
    local packages=(
        # Base — always installed
        systemd git curl wget jq yq
        strace ltrace
    )

    if $ENABLE_COCO; then
        packages+=(
            ansible python3-pip python3-devel gcc
            redhat-rpm-config openssl-devel libcurl-devel
            python3-requests python3-netaddr python3-jmespath
        )
    fi

    if $ENABLE_DEV; then
        packages+=(
            # CLI helpers
            ripgrep fd-find bat eza fzf tmux htop tealdeer
            # Editors
            vim-enhanced neovim emacs-nox
            # Build tools
            gcc gcc-c++ make cmake golang
            # pyenv build dependencies
            zlib-devel bzip2-devel readline-devel sqlite-devel
            libffi-devel xz-devel tk-devel
            # Linting & utilities
            ShellCheck zip unzip tar
        )
    fi

    if $ENABLE_K8S; then
        packages+=(kubectx)
    fi

    if $ENABLE_CLOUD; then
        packages+=(python3-pip unzip)
    fi

    if $ENABLE_VIRT; then
        packages+=(virt-manager virt-viewer libvirt-client)
    fi

    # Deduplicate and emit
    printf '%s\n' "${packages[@]}" | sort -u | tr '\n' ' '
}

# --------------------------------------------------------------------------- #
# Create the distrobox
# --------------------------------------------------------------------------- #
create_distrobox() {
    log_info "Creating Fedora ${FEDORA_VERSION} distrobox: ${DISTROBOX_NAME}"

    if distrobox list | grep -q "${DISTROBOX_NAME}"; then
        log_warn "Distrobox ${DISTROBOX_NAME} already exists. Removing it first..."
        distrobox rm -f "${DISTROBOX_NAME}"
    fi

    local packages
    packages=$(build_package_list)

    log_info "DNF packages: ${packages}"
    log_info "Creating distrobox container..."
    distrobox create \
        --name "${DISTROBOX_NAME}" \
        --image "${DISTROBOX_IMAGE}" \
        --init \
        --yes \
        --additional-packages "${packages}" \
        || { log_error "Failed to create distrobox"; exit 1; }

    log_info "Distrobox created successfully"
}

# --------------------------------------------------------------------------- #
# Post-create: Confidential Computing (Ansible + Dell iDRAC)
# --------------------------------------------------------------------------- #
setup_coco() {
    log_section "Confidential Computing Setup"

    distrobox enter "${DISTROBOX_NAME}" -- bash -c '
        set -euo pipefail

        echo "[INFO] Updating system packages..."
        sudo dnf update -y

        echo "[INFO] Installing Dell OpenManage Python SDK..."
        pip3 install --user omsdk --upgrade

        echo "[INFO] Installing Dell OpenManage Ansible Collection..."
        ansible-galaxy collection install dellemc.openmanage --upgrade

        echo "[INFO] Verifying Ansible installation..."
        ansible --version

        echo "[INFO] Verifying Dell OpenManage collection..."
        ansible-galaxy collection list | grep dellemc.openmanage || echo "Collection may need manual verification"

        echo "[INFO] CoCo setup complete!"
    '

    if [ $? -eq 0 ]; then
        log_info "Ansible and Dell iDRAC modules installed successfully"
    else
        log_error "Failed to setup Ansible inside distrobox"
        exit 1
    fi
}

# --------------------------------------------------------------------------- #
# Post-create: Dev toolchains (rustup, nvm, pyenv, sdkman)
# --------------------------------------------------------------------------- #
setup_dev_toolchains() {
    log_section "Dev Toolchain Installers"

    distrobox enter "${DISTROBOX_NAME}" -- bash -c '
        set -euo pipefail

        echo "[INFO] Installing rustup..."
        curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        echo "[INFO] rustup installed (source ~/.cargo/env to activate)"

        echo "[INFO] Installing nvm..."
        NVM_VERSION=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep tag_name | cut -d\" -f4)
        curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
        echo "[INFO] nvm ${NVM_VERSION} installed"

        echo "[INFO] Installing pyenv..."
        curl -sSL https://pyenv.run | bash
        # Add pyenv to bashrc if not already present
        if ! grep -q "PYENV_ROOT" ~/.bashrc 2>/dev/null; then
            cat >> ~/.bashrc << '\''PYENVEOF'\''
# pyenv
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init - bash)"
PYENVEOF
        fi
        echo "[INFO] pyenv installed"

        echo "[INFO] Installing sdkman..."
        curl -s "https://get.sdkman.io" | bash
        echo "[INFO] sdkman installed"

        echo ""
        echo "[INFO] Dev toolchain installers complete."
        echo "[INFO] Open a new shell or run: source ~/.bashrc"
    '
}

# --------------------------------------------------------------------------- #
# Post-create: Kubernetes client tools
# --------------------------------------------------------------------------- #
setup_k8s() {
    log_section "Kubernetes Client Tools"

    distrobox enter "${DISTROBOX_NAME}" -- bash -c '
        set -euo pipefail

        ARCH=$(uname -m)
        case $ARCH in
            x86_64)  ARCH_ALT="amd64" ;;
            aarch64) ARCH_ALT="arm64" ;;
            *) echo "[ERROR] Unsupported architecture: $ARCH"; exit 1 ;;
        esac

        echo "[INFO] Installing kubectl..."
        KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
        curl -sLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH_ALT}/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm -f kubectl
        echo "[INFO] kubectl ${KUBECTL_VERSION} installed"

        echo "[INFO] Installing helm..."
        curl -sSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        echo "[INFO] helm installed"

        echo "[INFO] Installing kustomize..."
        cd /tmp
        curl -sL "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh" | bash
        sudo mv /tmp/kustomize /usr/local/bin/kustomize
        cd -
        echo "[INFO] kustomize installed"

        echo "[INFO] Installing k9s..."
        K9S_VERSION=$(curl -s https://api.github.com/repos/derailed/k9s/releases/latest | grep tag_name | cut -d\" -f4)
        curl -sLO "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_${ARCH_ALT}.tar.gz"
        tar xzf "k9s_Linux_${ARCH_ALT}.tar.gz" k9s
        sudo install -o root -g root -m 0755 k9s /usr/local/bin/k9s
        rm -f k9s "k9s_Linux_${ARCH_ALT}.tar.gz"
        echo "[INFO] k9s ${K9S_VERSION} installed"

        echo "[INFO] Kubernetes tools installed."
    '
}

# --------------------------------------------------------------------------- #
# Post-create: Cloud CLIs
# --------------------------------------------------------------------------- #
setup_cloud() {
    log_section "Cloud CLIs"

    distrobox enter "${DISTROBOX_NAME}" -- bash -c '
        set -euo pipefail

        ARCH=$(uname -m)
        case $ARCH in
            x86_64)  ARCH_ALT="amd64" ;;
            aarch64) ARCH_ALT="arm64" ;;
            *) echo "[ERROR] Unsupported architecture: $ARCH"; exit 1 ;;
        esac

        # --- AWS CLI v2 ---
        echo "[INFO] Installing AWS CLI v2..."
        curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip
        unzip -qo /tmp/awscliv2.zip -d /tmp
        sudo /tmp/aws/install
        rm -rf /tmp/aws /tmp/awscliv2.zip
        echo "[INFO] AWS CLI installed: $(aws --version)"

        # --- Google Cloud CLI ---
        echo "[INFO] Installing Google Cloud CLI..."
        curl -sSL https://sdk.cloud.google.com > /tmp/install_gcloud.sh
        bash /tmp/install_gcloud.sh --disable-prompts --install-dir="$HOME" 2>&1
        rm -f /tmp/install_gcloud.sh
        if ! grep -q "google-cloud-sdk" ~/.bashrc 2>/dev/null; then
            echo "source \$HOME/google-cloud-sdk/path.bash.inc" >> ~/.bashrc
            echo "source \$HOME/google-cloud-sdk/completion.bash.inc" >> ~/.bashrc
        fi
        echo "[INFO] Google Cloud CLI installed"

        # --- Azure CLI ---
        echo "[INFO] Installing Azure CLI via pip..."
        pip3 install --user azure-cli
        echo "[INFO] Azure CLI installed"

        # --- doctl (DigitalOcean) ---
        echo "[INFO] Installing doctl..."
        DOCTL_VERSION=$(curl -s https://api.github.com/repos/digitalocean/doctl/releases/latest | grep tag_name | cut -d\" -f4 | sed "s/v//")
        curl -sLO "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-${ARCH_ALT}.tar.gz"
        tar xzf "doctl-${DOCTL_VERSION}-linux-${ARCH_ALT}.tar.gz"
        sudo install -o root -g root -m 0755 doctl /usr/local/bin/doctl
        rm -f doctl "doctl-${DOCTL_VERSION}-linux-${ARCH_ALT}.tar.gz"
        echo "[INFO] doctl ${DOCTL_VERSION} installed"

        echo "[INFO] Cloud CLIs installed."
    '
}

# --------------------------------------------------------------------------- #
# Dispatcher: run post-create setups for enabled modules
# --------------------------------------------------------------------------- #
run_post_create() {
    log_info "Running post-create setup for enabled modules..."

    $ENABLE_COCO  && setup_coco
    $ENABLE_DEV   && setup_dev_toolchains
    $ENABLE_K8S   && setup_k8s
    $ENABLE_CLOUD && setup_cloud
    # --virt is fully handled by DNF packages, no post-create needed

    $ENABLE_COCO  && create_ansible_playbooks

    return 0
}

# --------------------------------------------------------------------------- #
# Create Ansible playbooks for CoCo (written on the host)
# --------------------------------------------------------------------------- #
create_ansible_playbooks() {
    log_section "Ansible Playbooks"
    log_info "Creating Ansible playbooks for confidential computing setup..."

    mkdir -p "${ANSIBLE_PLAYBOOK_DIR}"

    # Inventory file
    cat > "${ANSIBLE_PLAYBOOK_DIR}/inventory.ini" << 'EOF'
[localhost]
127.0.0.1 ansible_connection=local

[dell_servers]
# Add your Dell iDRAC IPs here, for example:
# idrac1.example.com ansible_user=root ansible_password=password
EOF

    # Main CoCo BIOS configuration playbook
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
          MemOpMode: "OptimizerMode"
          MemEncryption: "MultiKey"
          GlobalMemIntegrity: "Disabled"
          IntelTdx: "Enabled"
          IntelTdxKeySplit: "1"
          TdxSeamLoader: "Enabled"
          SriovGlobalEnable: "Enabled"
          VtForDirectIo: "Enabled"
          ProcVirtualization: "Enabled"
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
          MemOpMode: "OptimizerMode"
          SecureMemoryEncryption: "Enabled"
          SevSnp: "Enabled"
          SnpMemCoverage: "Enabled"
          SriovGlobalEnable: "Enabled"
          IommuSupport: "Enabled"
          ProcVirtualization: "Enabled"
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

    # Verification playbook
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

    # Playbook README
    cat > "${ANSIBLE_PLAYBOOK_DIR}/README.md" << 'EOF'
# Confidential Computing Ansible Playbooks

## Files
- `inventory.ini` — Ansible inventory (configure Dell iDRAC IPs here)
- `configure_coco.yaml` — Configure Dell BIOS for CoCo via iDRAC
- `verify_coco.yaml` — Verify CoCo status after reboot

## Usage

1. Edit `inventory.ini` with your iDRAC IPs and credentials
2. Run: `ansible-playbook -i inventory.ini configure_coco.yaml`
3. Reboot the server
4. Run: `ansible-playbook -i inventory.ini verify_coco.yaml`
EOF

    log_info "Ansible playbooks created in ${ANSIBLE_PLAYBOOK_DIR}"
}

# --------------------------------------------------------------------------- #
# Display post-create usage instructions
# --------------------------------------------------------------------------- #
display_usage() {
    log_section "Setup Complete"
    echo ""
    echo "Enter the distrobox:"
    echo "  distrobox enter ${DISTROBOX_NAME}"
    echo ""

    if $ENABLE_COCO; then
        echo "Confidential Computing:"
        echo "  1. Edit ${ANSIBLE_PLAYBOOK_DIR}/inventory.ini with iDRAC credentials"
        echo "  2. distrobox enter ${DISTROBOX_NAME}"
        echo "  3. cd ${ANSIBLE_PLAYBOOK_DIR}"
        echo "  4. ansible-playbook -i inventory.ini configure_coco.yaml"
        echo "  5. Reboot, then: ./setup-distrobox.sh verify"
        echo ""
    fi

    if $ENABLE_DEV; then
        echo "Dev toolchains (activate in a new shell inside distrobox):"
        echo "  rustup  — source ~/.cargo/env"
        echo "  nvm     — nvm install --lts"
        echo "  pyenv   — pyenv install <version>"
        echo "  sdkman  — sdk install java"
        echo ""
    fi

    if $ENABLE_K8S; then
        echo "Kubernetes tools available: kubectl, helm, kustomize, kubectx, kubens, k9s"
        echo ""
    fi

    if $ENABLE_CLOUD; then
        echo "Cloud CLIs available: aws, gcloud, az, doctl"
        echo ""
    fi

    if $ENABLE_VIRT; then
        echo "Virtualization tools available: virt-manager, virt-viewer, virsh"
        echo "  Export GUI apps: distrobox-export --app virt-manager"
        echo ""
    fi
}

# --------------------------------------------------------------------------- #
# Verify confidential computing (runs on the host)
# --------------------------------------------------------------------------- #
verify_coco() {
    log_info "Verifying Confidential Computing configuration..."

    if grep -q "GenuineIntel" /proc/cpuinfo; then
        log_info "Intel CPU detected — checking for TDX..."

        if grep -q "tdx" /proc/cpuinfo; then
            log_info "TDX CPU flag found in /proc/cpuinfo"
        else
            log_warn "TDX CPU flag NOT found in /proc/cpuinfo"
        fi

        echo ""
        log_info "Checking dmesg for TDX initialization..."
        if dmesg | grep -i "tdx" | grep -q "initialized"; then
            log_info "TDX module initialized"
            dmesg | grep -i "tdx" | tail -10
        else
            log_warn "TDX initialization messages:"
            dmesg | grep -i "tdx" || log_warn "No TDX messages found in dmesg"
        fi

    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        log_info "AMD CPU detected — checking for SEV-SNP..."

        if grep -qE "sev|sme" /proc/cpuinfo; then
            log_info "SEV/SME CPU flags found in /proc/cpuinfo"
            grep -E "sev|sme" /proc/cpuinfo | head -3
        else
            log_warn "SEV/SME CPU flags NOT found in /proc/cpuinfo"
        fi

        echo ""
        log_info "Checking dmesg for SEV initialization..."
        if dmesg | grep -iE "sev|ccp" | grep -qE "enabled|initialized|API"; then
            log_info "SEV module initialized"
            dmesg | grep -iE "sev|ccp" | grep -E "enabled|initialized|API|active"
        else
            log_warn "SEV initialization messages:"
            dmesg | grep -iE "sev|ccp" || log_warn "No SEV messages found in dmesg"
        fi

        if [ -e /dev/sev ]; then
            log_info "/dev/sev device exists"
        else
            log_warn "/dev/sev device not found"
        fi

    else
        log_error "Unknown CPU vendor"
        exit 1
    fi

    echo ""
    log_info "Checking IOMMU configuration..."
    iommu_count=$(find /sys/kernel/iommu_groups/ -type l 2>/dev/null | wc -l)
    if [ "$iommu_count" -gt 0 ]; then
        log_info "IOMMU is enabled ($iommu_count groups found)"
    else
        log_warn "IOMMU groups not found — IOMMU may not be enabled"
    fi

    echo ""
    log_info "Current kernel command line:"
    cat /proc/cmdline
    echo ""
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
main() {
    case "${1:-help}" in
        create)
            shift
            parse_args "$@"

            # Show what's enabled
            local modules=()
            $ENABLE_COCO  && modules+=("coco")
            $ENABLE_DEV   && modules+=("dev")
            $ENABLE_K8S   && modules+=("k8s")
            $ENABLE_CLOUD && modules+=("cloud")
            $ENABLE_VIRT  && modules+=("virt")

            if [ ${#modules[@]} -eq 0 ]; then
                log_warn "No modules selected — creating base distrobox only (git, curl, jq, yq, strace, ltrace)"
                log_info "Available modules: --coco --dev --k8s --cloud --virt --full"
            else
                log_info "Modules: ${modules[*]}"
            fi

            log_info "Starting Fedora ${FEDORA_VERSION} distrobox setup..."
            create_distrobox
            run_post_create
            display_usage
            ;;
        verify)
            verify_coco
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            echo "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"