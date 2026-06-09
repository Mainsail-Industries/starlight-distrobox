# Using virt-v2v on Starlight

This guide walks through using **virt-v2v** — the libguestfs tool for
converting foreign-hypervisor VMs (VMware, Hyper-V, Xen, raw disks) into
KVM/libvirt guests — from inside a Fedora 43 distrobox on the Starlight
host (`starlight@192.168.2.82`).

Every command and every output block in this document was captured on
the live host on 2026-06-09 using the `fedora-virt` distrobox created
by `setup-distrobox.sh --virt`.

---

## 1. What virt-v2v Does

> "virt-v2v converts a single guest from a foreign hypervisor to run on KVM."

It reads a VM from a source (vCenter, ESXi, OVA, VMX, raw/qcow2 disk,
libvirt XML) and — for Starlight — writes a KVM-ready VM to local
libvirt: a directory of disk + domain XML, a libvirt storage pool, or a
ready-to-run `qemu` invocation. Along the way it:

- inspects the guest OS,
- installs / configures `virtio` drivers (network, block, balloon, rng),
- removes hypervisor-specific agents (VMware Tools, Hyper-V ICs),
- rewrites bootloader / initrd entries as needed,
- emits a libvirt domain XML matched to the converted disk(s).

It is *not* a live migration tool — the source guest must be powered
off.

## 2. Source / Destination Matrix

The shipped binary on Fedora 43 advertises many input/output modes, but
on Starlight we only use the local-KVM subset:

```
input:   disk | libvirt | libvirtxml | ova | vmx
output:  disk | libvirt | qemu   (local-only — no oVirt / OpenStack / KubeVirt)
convert: linux | windows
transports: ssh (Xen/ESXi), vddk (vCenter)
```

## 3. Anatomy of a virt-v2v Command

```
virt-v2v  -i <input-mode>  [input-options]  <source>
          -o <output-mode> [output-options]
          [--customise-options]
```

Key flags worth memorising:

| Flag | Purpose |
|------|---------|
| `-i disk\|ova\|vmx\|libvirt\|libvirtxml` | Pick the input plug-in |
| `-ic <uri>` | libvirt connection URI (`vpx://`, `esx://`, `xen+ssh://`, ...) |
| `-it ssh\|vddk` | Transport for ESXi-over-SSH or VMware VDDK |
| `-ip <file>` | File holding the source-side password |
| `-o disk\|libvirt\|qemu` | Output plug-in (Starlight uses these only) |
| `-os <storage>` | Output storage (directory for `-o disk`, pool name for `-o libvirt`, etc.) |
| `-of qcow2\|raw` | Output disk format |
| `-on <name>` | Rename the guest |
| `-b in:out`, `--network in:out`, `--mac MAC:network:NAME` | Re-map NICs |
| `--parallel N` | Copy disks in parallel |
| `-m <MB>` | RAM for the conversion appliance (bump if SELinux relabel OOMs) |
| `--print-source` | Read source metadata and exit (great for dry runs) |
| `--in-place` | Convert in-place instead of copying (uses `virt-v2v-in-place`) |
| `--install`, `--firstboot-command`, `--password`, `--hostname` | virt-customize-style guest tweaks |

## 4. Bring Up the Distrobox

On Starlight (Fedora 43 immutable host):

```bash
ssh starlight@192.168.2.82

# Single-file fetch — the host has no git installed.
curl -fsSL -o setup-distrobox.sh \
  https://raw.githubusercontent.com/Mainsail-Industries/starlight-distrobox/main/setup-distrobox.sh
chmod +x setup-distrobox.sh
./setup-distrobox.sh create --virt --name fedora-virt
```

`--virt` installs `virt-manager virt-viewer libvirt-client virt-v2v`
inside the box.

Sanity check from inside the box:

```
$ distrobox enter fedora-virt -- bash -c "virt-v2v --version; rpm -q virt-v2v libguestfs"
virt-v2v 2.10.0fedora=43,release=1.fc43
virt-v2v-2.10.0-1.fc43.x86_64
libguestfs-1.58.1-1.fc43.x86_64
```

Capabilities the binary advertises:

```
$ distrobox enter fedora-virt -- virt-v2v --machine-readable
virt-v2v
virt-v2v-2.0
libguestfs-rewrite
vcenter-https
xen-ssh
vddk
colours-option
vdsm-compat-option
io/oo
mac-option
bandwidth-option
mac-ip-option
parallel-option
customize-ops
block-driver-option
input:disk
input:libvirt
input:libvirtxml
input:ova
input:vmx
output:disk
output:glance
output:kubevirt
output:libvirt
output:null
output:openstack
output:ovirt
output:ovirt-upload
output:qemu
output:vdsm
convert:linux
convert:windows
ovf:ovirt
ovf:ovirtexp
```

## 5. Live Walk-through: Convert a Fedora 43 Cloud Image

### 5.1 Grab a source disk

We use the official Fedora 43 Cloud Base image as the "foreign" VM
(in this case the only thing being converted is the bus/driver layout
and libvirt metadata — the guest is already Linux).

```bash
distrobox enter fedora-virt -- bash -c '
  cd /var/tmp
  curl -sL -o fedora43-cloud.qcow2 \
    https://download-ib01.fedoraproject.org/pub/fedora/linux/releases/43/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2
  qemu-img info fedora43-cloud.qcow2 | head -10
'
```

Captured output:

```
image: fedora43-cloud.qcow2
file format: qcow2
virtual size: 5 GiB (5368709120 bytes)
disk size: 556 MiB
cluster_size: 65536
Format specific information:
    compat: 1.1
    compression type: zlib
    lazy refcounts: false
    refcount bits: 16
```

### 5.2 Inspect with `virt-v2v-inspector` (dry-run)

`virt-v2v-inspector` does the full read-side of a conversion (mounts
the disk, identifies the guest OS) but never writes output — perfect
for previews.

```bash
distrobox enter fedora-virt -- \
  virt-v2v-inspector -i disk /var/tmp/fedora43-cloud.qcow2
```

Captured output (trimmed to the XML payload):

```xml
<?xml version='1.0' encoding='utf-8'?>
<v2v-inspection>
  <!-- generated by virt-v2v-inspector 2.10.0fedora=43,release=1.fc43 -->
  <program>virt-v2v-inspector</program>
  <package>virt-v2v</package>
  <version>2.10.0</version>
  <disks>
    <disk index='0'>
      <virtual-size>5368709120</virtual-size>
      <allocated estimated='true'>801964032</allocated>
    </disk>
  </disks>
  <firmware type='bios'/>
  <operatingsystem>
    <name>linux</name>
    <distro>fedora</distro>
    <osinfo>fedora43</osinfo>
    <arch>x86_64</arch>
    <major_version>43</major_version>
    <minor_version>0</minor_version>
    <package_format>rpm</package_format>
    <package_management>dnf</package_management>
    <product_name>Fedora Linux 43 (Cloud Edition)</product_name>
    <product_variant>unknown</product_variant>
    <root>btrfsvol:/dev/sda4/root</root>
    <mountpoints>
      <mountpoint dev='btrfsvol:/dev/sda4/root'>/</mountpoint>
      <mountpoint dev='btrfsvol:/dev/sda4/var'>/var</mountpoint>
      <mountpoint dev='btrfsvol:/dev/sda4/home'>/home</mountpoint>
      <mountpoint dev='/dev/sda3'>/boot</mountpoint>
      <mountpoint dev='/dev/sda2'>/boot/efi</mountpoint>
    </mountpoints>
  </operatingsystem>
</v2v-inspection>
```

Note `btrfsvol:/dev/sda4/root` — the inspector correctly detected the
Btrfs subvolume layout shipped in the F43 cloud image.

### 5.3 Convert to a local libvirt directory

`-o local` (alias for `-o disk` with libvirt XML metadata) writes the
converted disk plus a libvirt domain XML next to it.

```bash
distrobox enter fedora-virt -- bash -c '
  cd /var/tmp
  mkdir -p out
  virt-v2v -i disk fedora43-cloud.qcow2 \
           -o local -os ./out \
           -of qcow2 -on fedora43-converted
'
```

Captured run (progress bar collapsed):

```
[   0.0] Setting up the source: -i disk fedora43-cloud.qcow2
[   1.0] Opening the source
[  11.2] Checking filesystem integrity before conversion
[  12.3] Detecting if this guest uses BIOS or UEFI to boot
[  12.7] Inspecting the source
[  13.9] Detecting the boot device
[  13.9] Checking for sufficient free disk space in the guest
[  13.9] Converting Fedora Linux 43 (Cloud Edition) (fedora43) to run on KVM
virt-v2v: This guest has virtio drivers installed.
[  29.8] Setting a random seed
[  29.8] SELinux relabelling
[  31.2] Mapping filesystem data to avoid copying unused and blank areas
[  32.4] Checking filesystem integrity after conversion
[  33.4] Closing the overlay
[  33.6] Assigning disks to buses
[  33.6] Checking if the guest needs BIOS or UEFI to boot
[  33.6] Setting up the destination: -o disk -os ./out
[  34.6] Copying disk 1/1
       (... progress ...)
[  36.2] Creating output metadata
[  36.2] Finishing off
```

Total wall-clock: **36 seconds**, single disk, no parallelism.

### 5.4 Inspect the output

```
$ distrobox enter fedora-virt -- ls -lh /var/tmp/out/
total 767M
-rw-r--r--. 1 starlight starlight 767M Jun  9 14:22 fedora43-converted-sda
-rw-r--r--. 1 starlight starlight 1.7K Jun  9 14:22 fedora43-converted.xml
```

The generated libvirt domain XML:

```xml
<?xml version='1.0' encoding='utf-8'?>
<domain type='kvm'>
  <!-- generated by virt-v2v 2.10.0fedora=43,release=1.fc43 -->
  <name>fedora43-converted</name>
  <metadata>
    <libosinfo:libosinfo xmlns:libosinfo='http://libosinfo.org/xmlns/libvirt/domain/1.0'>
      <libosinfo:os id='http://fedoraproject.org/fedora/43'/>
    </libosinfo:libosinfo>
  </metadata>
  <memory unit='KiB'>2097152</memory>
  <currentMemory unit='KiB'>2097152</currentMemory>
  <vcpu>1</vcpu>
  <cpu mode='host-model'/>
  <features>
    <acpi/>
    <apic/>
  </features>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
  </os>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>restart</on_crash>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/tmp/./out/fedora43-converted-sda'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <video>
      <model type='vga' vram='16384' heads='1'/>
    </video>
    <graphics type='sdl'/>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
    <memballoon model='virtio'/>
    <panic model='isa'>
      <address type='isa' iobase='0x505'/>
    </panic>
    <vsock model='virtio'/>
    <input type='tablet' bus='usb'/>
    <input type='mouse' bus='ps2'/>
    <console type='pty'/>
    <controller type='virtio-serial' model='virtio'/>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
  </devices>
</domain>
```

Note the disk is bound to `bus='virtio'` as `vda`, the NIC is
`virtio`, plus virtio-rng / virtio-balloon / virtio-serial — that's
the v2v `Converting ... to run on KVM` step at work.

### 5.5 Boot the result on Starlight

If `libvirtd` is reachable from the distrobox (via the shared host
socket), define and start:

```bash
distrobox enter fedora-virt -- bash -c '
  virsh -c qemu:///system define /var/tmp/out/fedora43-converted.xml
  virsh -c qemu:///system start fedora43-converted
'
```

## 6. Recipe Cheat-sheet

Examples below are the canonical invocations — adapt URIs / paths to
your environment.

### 6.1 Raw / qcow2 disk → local libvirt directory

```bash
virt-v2v -i disk guest.img \
         -o local -os /var/tmp/out \
         -of qcow2 -on my-guest
```

### 6.2 VMware ESXi (over SSH) → local libvirt

This is the path you reach for when you have **shell on an ESXi host
but no vCenter** (lab / edge / standalone ESXi). It is the simplest
VMware-side workflow and needs nothing on the ESXi host beyond what
ships in the box.

**What is happening**

- *VMX* is the VM definition file on a VMFS datastore (`/vmfs/volumes/<datastore>/<VM>/<VM>.vmx`).
  It points at one or more `.vmdk` flat files that hold the actual disk
  contents. virt-v2v's `-i vmx` parser reads the VMX, finds the VMDKs
  next to it, and pulls them across the wire.
- The transport `-it ssh` tells virt-v2v to copy those VMDKs by opening
  an SSH session to the ESXi host and reading the files with `cat` /
  `dd`. No VMware libraries required.
- Output `-o local -os /var/tmp` writes a libvirt domain XML plus
  converted disk(s) into `/var/tmp` inside the distrobox — same shape
  as section 5.4.

**Why a vSphere admin would pick this**

- No vCenter licence / vCenter outage / vCenter-less host.
- VDDK (the official VMware copy library) requires download, EULA, and
  a matching ESXi/vSphere version — SSH skips all of that.
- Great for one-off rescues: "this VM has been off in datastore1 for a
  year, get it to KVM."

**How to prepare the ESXi host**

1. **Enable SSH on the host.** In the vSphere Web Client / Host Client:
   `Host → Manage → Services → TSM-SSH → Start`. Or from a console
   shell: `vim-cmd hostsvc/enable_ssh && vim-cmd hostsvc/start_ssh`.
2. **Open SSH in the ESXi firewall** if it's restricted:
   `esxcli network firewall ruleset set --ruleset-id=sshServer --enabled=true`.
3. **Power the VM off** on the source. virt-v2v will refuse a running
   guest — and you don't want a torn disk image. (Snapshots are fine,
   but consolidate them first: vSphere Client → VM → Snapshots →
   *Consolidate*.)
4. **Locate the VMX path** in the datastore browser, e.g.
   `[datastore1] WebSrv01/WebSrv01.vmx`. Translate to the absolute path
   under `/vmfs/volumes/`.
5. **Stage an SSH key for root@esxi** (the ESXi `root` shell honours
   `~/.ssh/authorized_keys`). With a password-only host, virt-v2v will
   prompt; in scripts use `sshpass` or — preferably — drop a key:
   ```bash
   ssh-copy-id root@esxi.example.com
   ```

**How to invoke**

```bash
distrobox enter fedora-virt -- \
  virt-v2v -i vmx -it ssh \
    ssh://root@esxi.example.com/vmfs/volumes/datastore1/WebSrv01/WebSrv01.vmx \
    -o local -os /var/tmp
```

What virt-v2v does next, in order:

1. SSHes in, reads the VMX, enumerates VMDKs.
2. Streams each VMDK over SSH into an overlay on the conversion host.
3. Inspects the guest OS, swaps drivers to virtio, removes VMware Tools,
   rewrites initrd/bootloader as needed.
4. Writes the final qcow2 disk and a libvirt domain XML into
   `/var/tmp`.

**Common gotchas**

- *"vmx parser: cannot find disk"* — the VMX references an SE-Sparse
  or delta VMDK because snapshots weren't consolidated. Consolidate
  in vSphere first.
- *Permission denied opening VMDK* — ESXi's `root` shell can read all
  VMFS files, but a non-root user usually cannot.
- *Slow copy* — SSH is single-threaded and CPU-bound on the ESXi side.
  For VMs larger than a few hundred GB, use the vCenter/VDDK path
  (6.3) which can read concurrently.

### 6.3 VMware vCenter (VDDK transport) → local libvirt

This is the path for **production fleets managed by vCenter**. You
talk to vCenter (not the ESXi host directly), let VMware's own copy
library (VDDK) do the heavy lifting, and get parallel / SAN-accelerated
disk reads.

**What is happening**

- `-ic vpx://...` is a *libvirt connection URI* of the form
  `vpx://<user>@<vcenter-fqdn>/<Datacenter>/<Cluster>/<ESXi-host>`. It
  tells virt-v2v "go ask vCenter for this VM's metadata." (`vpx` is
  vSphere-speak for vCenter's API; `esx://` is the equivalent for a
  standalone ESXi.)
- The guest name at the end of the command (`my-source-guest`) is the
  exact VM inventory name as it appears in vCenter — same string you
  see in the vSphere Client tree.
- `-it vddk` switches the disk-read transport to the **VMware Virtual
  Disk Development Kit**: VMware's official C library for reading
  VMDKs. With it you get NBD/NBDSSL/SAN/HotAdd modes, parallelism,
  thin-aware reads, and CBT — exactly the same stack VMware's own
  backup vendors use.
- `-io vddk-libdir=...` points at the unpacked VDDK distribution on
  disk. virt-v2v will `dlopen()` `libvixDiskLib.so` from there.

**Why a vSphere admin would pick this**

- vCenter is the source of truth — names, networks, hardware version,
  snapshots, and folder placement are all there.
- VDDK pulls disks **much** faster than SSH, especially over 10/25 GbE
  fabrics or directly from SAN LUNs.
- vCenter handles auth (SSO, AD, MFA via a service account) — no
  per-host root credential sprawl.
- It's the only mode where Changed Block Tracking is meaningful if you
  later want to redo the conversion against a fresher snapshot.

**How to prepare vCenter / VDDK**

1. **Create (or pick) a service account** with at minimum:
   - `Virtual machine → Provisioning → Allow read-only disk access`
   - `Virtual machine → Provisioning → Allow disk access`
   - `Virtual machine → Provisioning → Allow virtual machine download`
   - `Virtual machine → Interaction → Power off`

   Grant it on the Datacenter/Cluster/Folder containing the source
   VMs. (Plain "Read-only" is *not* sufficient — VDDK needs the
   download privileges.)
2. **Power the VM off (or take a snapshot)**. virt-v2v will refuse a
   powered-on guest unless you point it at a snapshot.
3. **Find the connection URI fragments**:
   - `Datacenter` — the top-level inventory object in the vSphere
     Client (left tree).
   - `Cluster` — the cluster the host belongs to. For a standalone
     host, use `host` in place of the cluster name.
   - `ESXi-host` — the FQDN of the host where the VM is currently
     registered.
4. **Download and unpack the VDDK** from VMware's developer portal
   (Broadcom login required). The 8.x release works against modern
   vCenter:
   ```bash
   tar xzf VMware-vix-disklib-8.0.3-23416773.x86_64.tar.gz \
       -C /opt/   # -> /opt/vmware-vix-disklib-distrib
   ```
   Make sure the **VDDK major version matches or exceeds** the
   vCenter / ESXi major version.
5. **Stash the password in a file** (virt-v2v refuses passwords on the
   command line):
   ```bash
   printf '%s' 'svc-v2v-password' > /tmp/vpw
   chmod 600 /tmp/vpw
   ```
6. **Verify the thumbprint** (HTTPS pin). virt-v2v will print the
   expected thumbprint on the first connection — capture it and pass
   via `-io vddk-thumbprint=AA:BB:...` for unattended runs.

**How to invoke**

```bash
distrobox enter fedora-virt -- \
  virt-v2v \
    -ic 'vpx://svc-v2v@vsphere.local@vcenter.example.com/DC1/Cluster01/esxi-01.example.com?no_verify=1' \
    -ip /tmp/vpw \
    -it vddk \
    -io vddk-libdir=/opt/vmware-vix-disklib-distrib \
    -io vddk-thumbprint=AA:BB:CC:DD:... \
    WebSrv01 \
    -o local -os /var/tmp
```

What virt-v2v does next, in order:

1. Authenticates to vCenter, locates `WebSrv01`, reads its OVF/VMX
   metadata (CPU, RAM, NICs, disks, hardware version, BIOS vs UEFI).
2. Spins up VDDK in NBD mode against the ESXi host that owns the VM
   and streams each VMDK into an overlay locally.
3. Same conversion pass as the SSH path: virtio drivers, Tools
   removal, bootloader fix-ups, SELinux relabel for Linux guests.
4. Writes the qcow2 + libvirt domain XML to `/var/tmp`.

**Common gotchas**

- *"VDDK library not found"* — wrong `vddk-libdir` path, or the VDDK
  tarball was extracted incorrectly. The directory must contain
  `lib64/libvixDiskLib.so`.
- *"Permission to perform this operation was denied"* — the service
  account is missing the "Allow virtual machine download" privilege
  family.
- *Hostname mismatch / certificate errors* — append `?no_verify=1` to
  the URI in lab environments, or import the vCenter CA into the
  distrobox's trust store for production.
- *VM not found* — the trailing name is **case-sensitive** and must
  match the inventory name, not the guest hostname or UUID.
- *Snapshots present* — virt-v2v will convert the **current** state
  including delta chains; consolidate first unless you specifically
  want a point-in-time.

**ESXi-direct alternative**: swap `vpx://` for
`esx://root@esxi-01.example.com/?no_verify=1` to skip vCenter when the
host is standalone — VDDK still works.

### 6.4 OVA appliance → local libvirt

```bash
virt-v2v -i ova /path/to/appliance.ova \
         -o local -os /var/tmp
```

### 6.5 Convert directly into a libvirt pool

```bash
virt-v2v -i disk guest.qcow2 \
         -o libvirt -os default \
         -on imported-guest
```

### 6.6 Just produce a bootable qemu command-line

```bash
virt-v2v -i disk guest.qcow2 -o qemu -os /var/tmp
# Writes /var/tmp/<name>.sh that runs qemu-system-x86_64 directly.
```

### 6.7 In-place conversion (no copy)

```bash
virt-v2v-in-place -i disk guest.qcow2          # or
virt-v2v --in-place -i libvirt my-stopped-guest
```

Use when you have already copied the disk to your target storage and
just want the OS to be virtio-ified.

## 7. Customisation at Conversion Time

`virt-v2v` re-exports the entire `virt-customize` flag set, so you can
modify the guest as it lands:

```bash
virt-v2v -i disk guest.qcow2 -o local -os /var/tmp \
  --hostname converted-host \
  --root-password password:redhat \
  --install qemu-guest-agent,cloud-init \
  --firstboot-command 'systemctl enable --now qemu-guest-agent' \
  --upload ./company-ca.pem:/etc/pki/ca-trust/source/anchors/
```

## 8. Troubleshooting Cheat-sheet

| Symptom | Likely cause / fix |
|---------|--------------------|
| `inspection could not detect ... operating system` | Source is a blank/unsupported disk (e.g. cirros/busybox). Verify with `virt-filesystems -a <img>` and `guestfish --ro -a <img> -i`. |
| `error: out of memory` during SELinux relabel | Bump appliance RAM: `-m 4096`. |
| Windows guest reboots forever on first boot | Disable Fast Startup / hibernation pre-conversion, ensure virtio-win ISO is reachable. |
| `vddk-libdir` missing for vCenter | Install VMware VDDK from VMware and point `-io vddk-libdir=` at the extracted distrib. |
| Conversion succeeds but VM has no network | Map source NIC into a present libvirt network: `--bridge sourceBridge:virbr0` or `--network vmnet1:default`. |
| Disk space exhausted in `/var/tmp` | Override scratch dir: `export VIRT_V2V_TMPDIR=/big/scratch`. |
| LUKS-encrypted root won't open | Pass keys: `--key /dev/sda3:key:s3cret`. TPM-sealed keys won't survive — re-seal post-conversion. |

## 9. Pre / Post-conversion Checklist

**Before**

- Shut the guest down cleanly on the source hypervisor. Snapshots are
  fine; running VMs are not.
- Windows: disable BitLocker (or supply key), disable Fast Startup,
  loosen PowerShell `ExecutionPolicy` if firstboot scripts need to run,
  remove AV / Group Policy locks.
- Linux: make sure a real (non-Xen-PV) kernel is installed if the
  source is Xen PV.

**After**

- Boot the converted guest *with no console interruption* the first
  time — Windows will install virtio drivers and reboot several times.
- Remove VMware Tools manually if v2v's automatic removal failed.
- Re-IP the guest if the new bridge is on a different subnet.
- Re-attach data disks that were intentionally skipped during
  conversion.

## 10. References

- virt-v2v(1) man page: <https://libguestfs.org/virt-v2v.1.html>
- virt-v2v-inspector(1): <https://libguestfs.org/virt-v2v-inspector.1.html>
- libguestfs project home: <https://libguestfs.org/>
- Source: `setup-distrobox.sh --virt` module (this repo) installs
  `virt-manager virt-viewer libvirt-client virt-v2v` from the Fedora 43
  repos.
