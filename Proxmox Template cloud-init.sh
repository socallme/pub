#!/bin/bash
# create-template.sh
#
# 1. Download Ubuntu cloud image (optional).
# 2. Create a VM with scsi + cloudinit drive, QEMU guest agent, etc.
# 3. Generate snippet files for meta-data (and optionally user-data, network-config).
# 4. Attach them to the template with --cicustom (optional).
# 5. Convert the VM into a template.
$ 6. Create a test vm running on 444 (Will delete if it exists)

set -euo pipefail

# --- Configuration --- #
TEMPLATE_VMID=9000
TEMPLATE_NAME="ubuntu-cloudinit-template"
MEMORY=2048
CORES=2
STORAGE="local-lvm"            # Storage target for your disks
CLOUD_IMAGE="noble-server-cloudimg-amd64.img"
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/${CLOUD_IMAGE}"
SNIPPET_STORAGE="local"        # Storage ID for "Snippets" (must allow 'Snippets' in Proxmox)
SNIPPETS_DIR="/var/lib/vz/snippets"

#Creds
USERNAME="adminuser" 
PASSWORD="adminuser"
SSHKEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCk89M59CcvdBxPZDdXnE8wfvFnIZzD9crYWBBiplcOGEdpuePN0frtdvQ"
# --- Download cloud image if needed --- #
if [[ ! -f "$CLOUD_IMAGE" ]]; then
  echo "Downloading $CLOUD_IMAGE..."
  wget -q -O "$CLOUD_IMAGE" "$CLOUD_IMAGE_URL"
fi

# --- Remove old VM (if any) --- #
if qm status "${TEMPLATE_VMID}" &>/dev/null; then
  echo "VM $TEMPLATE_VMID already exists. Deleting it..."
  qm stop "${TEMPLATE_VMID}" || true
  qm destroy "${TEMPLATE_VMID}" --purge || true
fi



# --- Create a new VM shell --- #
#  --serial0 socket --vga serial0 \

echo "Creating new VM ${TEMPLATE_VMID} - ${TEMPLATE_NAME}..."
qm create "${TEMPLATE_VMID}" \
  --name "${TEMPLATE_NAME}" \
  --memory "${MEMORY}" \
  --cores "${CORES}" \
  --net0 virtio,bridge=vmbr0 \
  --boot order=scsi0 \
  --scsihw virtio-scsi-pci \
  --agent enabled=1 \
  --ide2 "${STORAGE}":cloudinit \
  --ipconfig0 ip=dhcp

# --- Import the downloaded disk and attach to scsi0 --- #
echo "Importing disk $CLOUD_IMAGE..."
qm importdisk "${TEMPLATE_VMID}" "${CLOUD_IMAGE}" "${STORAGE}"
qm set "${TEMPLATE_VMID}" \
  --scsihw virtio-scsi-pci \
  --scsi0 "${STORAGE}":vm-"${TEMPLATE_VMID}"-disk-0,discard=on

# --- (Optional) Resize the disk, e.g. +10G --- #
qm resize "${TEMPLATE_VMID}" scsi0 "+10G"

# --- Create minimal snippet files for meta, user, and network (optional) --- #
mkdir -p "${SNIPPETS_DIR}"

META_FILE="${SNIPPETS_DIR}/meta-data-${TEMPLATE_VMID}.yaml"
USER_FILE="${SNIPPETS_DIR}/user-data-${TEMPLATE_VMID}.yaml"
NETWORK_FILE="${SNIPPETS_DIR}/network-config-${TEMPLATE_VMID}.yaml"

cat > "${META_FILE}" <<EOF
instance-id: template-${TEMPLATE_VMID}
local-hostname: ${TEMPLATE_NAME}
EOF

# This user-data snippet runs updates and installs qemu-guest-agent
# plus a few extras. Adjust as needed.
cat > "${USER_FILE}" <<EOF
#cloud-config
users:
  - name: ${USERNAME}
    gecos: Cloud Admin
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    lock_passwd: false
    ssh_authorized_keys:
      - ${SSHKEY}

chpasswd:
  expire: false
  list: |
    ${USERNAME}:${PASSWORD}
ssh_pwauth: true
package_update: true
package_upgrade: true
packages:
  - htop
  - curl
  - prometheus-node-exporter
  - qemu-guest-agent
  - ufw
  - wget
  - apt-transport-https
  - ca-certificates
  - gnupg2
  - software-properties-common
  - tmux
  - jq
  - zip
  - unzip
  - neofetch
runcmd:
  - systemctl enable prometheus-node-exporter
  - systemctl start prometheus-node-exporter
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  - hostnamectl set-hostname "prod-ubuntu-$(date +%y%m%d)-$(shuf -i 100-999 -n1)"
  - reboot now
EOF

# Minimal network config with DHCP.
cat > "${NETWORK_FILE}" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    all-eth-interfaces:
      match:
        name: "e*"
      dhcp4: true
EOF

# --- Attach snippet files to the VM (optional) --- #
# If you'd rather not reference these files on the template,
# you can comment this out and only set it on cloned VMs instead.
qm set "${TEMPLATE_VMID}" --cicustom \
"user=${SNIPPET_STORAGE}:snippets/$(basename "${USER_FILE}"),meta=${SNIPPET_STORAGE}:snippets/$(basename "${META_FILE}"),network=${SNIPPET_STORAGE}:snippets/$(basename "${NETWORK_FILE}")"

echo "Done! VM ${TEMPLATE_VMID} now references:"
echo "  - user-data: ${USER_FILE}"
echo "  - meta-data: ${META_FILE}"
echo "  - network-config: ${NETWORK_FILE}"


# --- Convert the VM into a template --- #
qm template "${TEMPLATE_VMID}"

echo "Template ${TEMPLATE_VMID} created successfully!"
echo
echo "Cloud-Init snippet files generated in:"
echo "  ${META_FILE}"
echo "  ${USER_FILE}"
echo "  ${NETWORK_FILE}"
echo
echo "NOTE: If you don't need the snippet files attached to the template,"
echo "      comment out the 'qm set --cicustom' line above and use them"
echo "      only when you clone new VMs."


echo "Creating clone / deleting existing clone"
TARGET_VMID=444

# 1) Check if the target VM (444) exists
if qm status "$TARGET_VMID" &>/dev/null; then
  # 2) If it exists, see if it's running
  VM_STATE="$(qm status "$TARGET_VMID")"
  
  # The output of `qm status 444` typically looks like:
  #   status: running
  #   or
  #   status: stopped
  #
  # We'll parse it to see if it contains 'running' or 'stopped'.

  if [[ "$VM_STATE" == *"running"* ]]; then
    echo "VM $TARGET_VMID is running. Stopping and destroying..."
    qm stop "$TARGET_VMID"
    # Optional sleep to give Proxmox time to stop the VM
    sleep 5
    qm destroy "$TARGET_VMID" --purge
  else
    echo "VM $TARGET_VMID is not running. Destroying..."
    qm destroy "$TARGET_VMID" --purge
  fi
fi

# 3) Clone VM 1000 to VM 444 (full clone)
echo "Cloning VM $TEMPLATE_VMID to VM $TARGET_VMID..."
qm clone "$TEMPLATE_VMID" "$TARGET_VMID" --full
echo "Clone complete!"
echo "starting test VM"
sleep 5
qm start $TARGET_VMID
