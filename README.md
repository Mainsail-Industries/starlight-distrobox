# Fedora 43 Distrobox for Immutable Host Development

A modular distrobox setup for development on immutable Linux hosts (Fedora Silverblue, uBlue, etc.). Provides a full mutable development environment inside a container with optional tool categories.

## Overview

This script creates a Fedora 43 distrobox and installs tools in configurable modules:

| Module | What's Included |
|--------|----------------|
| *base* | git, curl, wget, jq, yq, strace, ltrace (always installed) |
| `--coco` | Ansible, Dell iDRAC modules, CoCo BIOS playbooks |
| `--dev` | CLI helpers, editors (vim/neovim/emacs), gcc/cmake/golang, rustup, nvm, pyenv, sdkman |
| `--k8s` | kubectl, helm, kustomize, kubectx/kubens, k9s |
| `--cloud` | AWS CLI v2, Google Cloud CLI, Azure CLI, doctl |
| `--virt` | virt-manager, virt-viewer, virsh (libvirt-client) |
| `--full` | All of the above |

## Requirements

- distrobox installed on the host system
- podman or docker as the container runtime
- Internet connectivity for package and binary downloads

## Quick Start

```bash
# Get the repo
git clone https://github.com/Mainsail-Industries/starlight-distrobox.git
cd starlight-distrobox

# or
curl -L https://github.com/Mainsail-Industries/starlight-distrobox/archive/refs/heads/main.tar.gz | tar -xz
```

```bash
# Dev workstation with Kubernetes tools
./setup-distrobox.sh create --dev --k8s

# Everything
./setup-distrobox.sh create --full

# CoCo-only with a custom container name
./setup-distrobox.sh create --coco --name fedora-coco

# Base only (git, curl, jq, yq, strace, ltrace)
./setup-distrobox.sh create
```

```bash
# Enter the distrobox
distrobox enter fedora-dev
```

## Module Details

### Base (always installed)

Installed via DNF into every distrobox:

- `git`, `curl`, `wget` — essentials
- `jq`, `yq` — JSON/YAML processing
- `strace`, `ltrace` — debugging

### --dev

**DNF packages:**
- CLI helpers: `ripgrep`, `fd-find`, `bat`, `eza`, `fzf`, `tmux`, `htop`, `tealdeer`
- Editors: `vim-enhanced`, `neovim`, `emacs-nox`
- Build tools: `gcc`, `gcc-c++`, `make`, `cmake`, `golang`
- Linting: `ShellCheck`
- pyenv build deps: `zlib-devel`, `bzip2-devel`, `readline-devel`, `sqlite-devel`, `libffi-devel`, `xz-devel`, `tk-devel`

**User-space toolchain installers** (installed to `$HOME`, shared with host):
- **rustup** — Rust toolchain manager (`source ~/.cargo/env`)
- **nvm** — Node.js version manager (`nvm install --lts`)
- **pyenv** — Python version manager (`pyenv install 3.12`)
- **sdkman** — JVM toolchain manager (`sdk install java`)

### --coco

Confidential Computing support for Dell PowerEdge servers:
- Ansible + Dell OpenManage Python SDK + `dellemc.openmanage` collection
- Auto-generates playbooks in `~/ansible-coco/` for Intel TDX and AMD SEV-SNP BIOS configuration via iDRAC

**Requirements for CoCo:**
- Dell PowerEdge server with iDRAC 8+
- Intel 5th Gen Xeon Scalable (TDX) or AMD EPYC 7003+ (SEV-SNP)
- iDRAC credentials with BIOS configuration privileges

### --k8s

- `kubectx` / `kubens` — context and namespace switching (DNF)
- `kubectl` — Kubernetes CLI (binary download)
- `helm` — package manager (install script)
- `kustomize` — manifest customization (binary download)
- `k9s` — terminal UI for Kubernetes (binary download)

### --cloud

- **AWS CLI v2** — bundled installer
- **Google Cloud CLI** — standalone SDK installer
- **Azure CLI** — pip install
- **doctl** — DigitalOcean CLI (binary download)

### --virt

- `virt-manager` — GUI VM management (export to host desktop with `distrobox-export --app virt-manager`)
- `virt-viewer` — SPICE/VNC console viewer
- `libvirt-client` — `virsh` CLI for VM operations

## CoCo Workflow

```bash
# 1. Create distrobox with CoCo support
./setup-distrobox.sh create --coco

# 2. Configure iDRAC credentials
cd ~/ansible-coco
nano inventory.ini
# Add: idrac1.example.com ansible_user=root ansible_password=yourpassword

# 3. Configure BIOS via iDRAC
distrobox enter fedora-dev
cd ~/ansible-coco
ansible-playbook -i inventory.ini configure_coco.yaml

# 4. Reboot the server
sudo reboot

# 5. Verify confidential computing
./setup-distrobox.sh verify
```

### BIOS Settings Configured

**Intel TDX:**
- Memory Encryption: MultiKey
- Global Memory Integrity: Disabled
- Intel TDX: Enabled
- TDX Key Split: 1
- TDX SEAM Loader: Enabled
- Intel VT-d / VT: Enabled
- SR-IOV: Enabled

**AMD SEV-SNP:**
- Secure Memory Encryption: Enabled
- SEV-SNP: Enabled
- SNP Memory Coverage: Enabled
- IOMMU Support: Enabled
- AMD-V: Enabled
- SR-IOV: Enabled

## Troubleshooting

### Distrobox fails to create
```bash
podman ps        # or: docker ps
distrobox version
```

### Re-running module setup
The `create` command replaces any existing distrobox with the same name. To add modules, re-run with the full set of flags you want:
```bash
./setup-distrobox.sh create --dev --k8s --cloud
```

### CoCo not detected after reboot
1. Check BIOS settings via iDRAC web interface
2. Verify kernel parameters: `cat /proc/cmdline`
   - Intel: `intel_iommu=on tdx_host=on`
   - AMD: `iommu=pt mem_encrypt=on kvm_amd.sev=1`
3. Check dmesg: `dmesg | grep -iE "tdx|sev|ccp"`

### iDRAC connection fails
- Verify connectivity: `ping <idrac-ip>`
- Check credentials in `inventory.ini`
- Verify Dell OpenManage collection: `ansible-galaxy collection list | grep dellemc`

### GUI apps (virt-manager) not displaying
Export from inside the distrobox to the host desktop:
```bash
distrobox enter fedora-dev
distrobox-export --app virt-manager
```
Requires a display server (X11/Wayland) on the host.

## Technical Notes

- **Distrobox image:** `registry.fedoraproject.org/fedora:43` with systemd init
- **Home directory:** Shared between host and distrobox — user-space tools (rustup, nvm, pyenv, sdkman, gcloud) are accessible from both
- **Container-only binaries:** Tools installed to `/usr/local/bin/` (kubectl, helm, k9s, etc.) only exist inside the container
- **Default container name:** `fedora-dev` (override with `--name`)

## References

- [Distrobox Documentation](https://distrobox.it/)
- [Dell OpenManage Ansible Modules](https://github.com/dell/dellemc-openmanage-ansible-modules)
- [Intel TDX Documentation](https://docs.kernel.org/arch/x86/tdx.html)
- [AMD SEV Documentation](https://github.com/AMDESE/AMDSEV)