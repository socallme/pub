#!/bin/bash

# Define network interface and static IP configuration
INTERFACE="ens18"
STATIC_IP="192.168.1.100/24"
GATEWAY="192.168.1.1"
NETPLAN_FILE="/etc/netplan/50-cloud-init.yaml"

# Backup the existing Netplan configuration
cp $NETPLAN_FILE ${NETPLAN_FILE}.backup_$(date +%F_%T)

# Update Netplan configuration with static IP and dynamic DNS
cat <<EOF > $NETPLAN_FILE
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: false
      addresses:
        - $STATIC_IP
      routes:
        - to: default
          via: $GATEWAY
      dhcp4-overrides:
        use-dns: true
EOF

# Apply the changes
echo "Applying new network configuration..."
netplan apply

# Verify new IP and routes
echo "Updated network settings for $INTERFACE:"
ip a show $INTERFACE
ip route show
