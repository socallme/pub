#!/bin/bash

# Global Configuration
VMID=9001                          # Template VM ID
TEMPLATE_NAME="ubuntu-template"    # Proxmox VM name (not guest hostname)
MEMORY=2048                        # Memory in MB
CORES=2                            # CPU cores
NET_BRIDGE="vmbr0"                 # Network bridge
DISK_SIZE="+10G"                   # Disk resize
CLOUD_IMAGE="noble-server-cloudimg-amd64.img"
CLOUD_IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/${CLOUD_IMAGE}"
SNIPPETS_DIR="/var/lib/vz/snippets" # Proxmox snippets directory

# Hostname Convention (customize these!)
DISTRO="ubuntu"                    # Distribution (e.g., ubuntu, debian)
ROLE="node"                        # Role (e.g., web, db, monitor)
ENVIRONMENT="prod"                 # Environment (e.g., prod, staging)
SEQUENCE="01"                      # Sequence number
HOSTNAME="${DISTRO}-${ROLE}-${ENVIRONMENT}-${SEQUENCE}"  # e.g., ubuntu-node-prod-01

# Cloud-Init Credentials
USERNAME="xxx"                  # VM login user
PASSWORD="xxx"                 # VM login password
SSH_KEY=$(cat ~/.ssh/id_rsa.pub)   # Path to your SSH public key

# Checkmk Agent
CHECKMK_AGENT_URL="http://docker.:5000/cmk/check_mk/agents/check-mk-agent_2.3.0p25-1_all.deb"

# ------------------------------------------------------------------------------
# Main Script (No changes needed below this line)
# ------------------------------------------------------------------------------

# Download Ubuntu Cloud Image (if missing)
if [[ ! -f $CLOUD_IMAGE ]]; then
  echo "Downloading Ubuntu Cloud Image..."
  if ! wget -q $CLOUD_IMAGE_URL -O $CLOUD_IMAGE; then
    echo "ERROR: Failed to download cloud image. Exiting."
    exit 1
  fi
else
  echo "Cloud image already exists. Skipping download."
fi

# Create VM
echo "Creating VM with ID $VMID..."
qm create $VMID --name $TEMPLATE_NAME --memory $MEMORY --cores $CORES --net0 virtio,bridge=$NET_BRIDGE

# Import Disk
echo "Importing disk image..."
qm importdisk $VMID $CLOUD_IMAGE local-lvm
qm set $VMID --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-$VMID-disk-0,ssd=1,discard=on

# Configure Cloud-Init
echo "Setting up cloud-init..."
qm set $VMID --ide2 local-lvm:cloudinit
qm set $VMID --boot order=scsi0
qm set $VMID --serial0 socket --vga serial0
qm set $VMID --agent enabled=1,fstrim_cloned_disks=1  # Enable QEMU Guest Agent in Proxmox

qm set $VMID \
  --ipconfig0 "ip=dhcp" \
  --nameserver "192.168.20.5" \

# Resize Disk
echo "Resizing disk..."
qm resize $VMID scsi0 $DISK_SIZE

# Create Cloud-Init YAML Configuration
echo "Generating cloud-init configuration..."
CUSTOM_USERDATA="${SNIPPETS_DIR}/userdata_${VMID}.yaml"
cat << EOF > $CUSTOM_USERDATA
#cloud-config
hostname: ${HOSTNAME}
fqdn: ${HOSTNAME}.local
user: ${USERNAME}
password: ${PASSWORD}
chpasswd: { expire: false }
ssh_pwauth: true
ssh_authorized_keys:
  - ${SSH_KEY}
package_update: true
package_upgrade: true
packages:
  - prometheus-node-exporter
  - qemu-guest-agent
  - ufw
  - wget
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg2
  - software-properties-common
  - htop
  - tmux
  - jq
  - zip
  - unzip
  - neofetch
runcmd:
  # Existing services
  - systemctl enable prometheus-node-exporter
  - systemctl start prometheus-node-exporter
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent

  # Checkmk Agent Installation and Registration
  # Need to clean this up
  - |
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/register_checkmk.sh << 'EOF'
    #!/bin/bash
    CHECKMK_SERVER="http://xxx:5000"
    SITE_NAME="cmk"
    AUTOMATION_USER="xxx"
    AUTOMATION_SECRET="xxx!"
    FOLDER="collected"
    HOST_NAME=\$(hostname -f)
    IP_ADDRESS=\$(hostname -I | awk '{print \$1}')
    AGENT_URL="http://xxx:5000/cmk/check_mk/agents/check-mk-agent_2.3.0p25-1_all.deb"

    wget -q "\$AGENT_URL" -O /tmp/check-mk-agent.deb
    dpkg -i /tmp/check-mk-agent.deb || (apt-get update && apt-get install -f -y)
    rm -f /tmp/check-mk-agent.deb

    API_URL="\${CHECKMK_SERVER}/\${SITE_NAME}/api/1.0/objects/host_config/\${HOST_NAME}"
    curl -s -S -X POST \\
      -H "Authorization: Bearer \${AUTOMATION_USER} \${AUTOMATION_SECRET}" \\
      -H "Accept: application/json" \\
      -H "Content-Type: application/json" \\
      -d "{
        \\"folder\\": \\"\${FOLDER}\\",
        \\"attributes\\": {
          \\"ipaddress\\": \\"\${IP_ADDRESS}\\",
          \\"site\\": \\"\${SITE_NAME}\\",
          \\"tag_agent\\": \\"cmk-agent\\"
        }
      }" \\
      "\${API_URL}" > /dev/null 2>&1
    EOF
  - chmod +x /usr/local/bin/register_checkmk.sh
  - /usr/local/bin/register_checkmk.sh

  # Firewall rules
  - ufw allow 9100/tcp  # Prometheus
  - ufw allow 6556/tcp  # Checkmk
EOF

# Apply Cloud-Init Configuration
qm set $VMID --cicustom "user=local:snippets/userdata_${VMID}.yaml"

# Convert to Template
echo "Converting VM $VMID to template..."
qm template $VMID

echo "----------------------------------------"
echo "Template creation successful!"
echo "VM ID: $VMID"
echo "Hostname: $HOSTNAME"
echo "----------------------------------------"
