#!/bin/bash

# Function to rename VM
rename_vm() {
    local vmid="$1"
    local new_name="$2"

    echo "Renaming VM $vmid to $new_name..."

    # Rename VM in Proxmox
    qm set "$vmid" --name "$new_name"

    # Update hostname inside the VM (Assumes guest agent is running)
    echo "Updating hostname inside VM $vmid..."
    qm guest exec "$vmid" -- hostnamectl set-hostname "$new_name"

    # Update /etc/hostname
    qm guest exec "$vmid" -- bash -c "echo '$new_name' > /etc/hostname"

    # Update /etc/hosts (add entry if it doesn't exist)
    qm guest exec "$vmid" -- bash -c "
        if ! grep -q '127.0.1.1 $new_name' /etc/hosts; then
            echo '127.0.1.1 $new_name' >> /etc/hosts
        fi
    "

    echo "Hostname updated inside VM $vmid to $new_name"
}

# Get list of running VMs
running_vms=$(qm list | awk '$3=="running" {print $1}')

if [[ -z "$running_vms" ]]; then
    echo "No running VMs found."
    exit 1
fi

# Loop through each running VM
for vmid in $running_vms; do
    # Get current name
    current_name=$(qm config "$vmid" | grep '^name:' | awk '{print $2}')

    # Define new name logic (Modify as needed)
    new_name="${current_name}"

    # Rename VM and update hostname
    rename_vm "$vmid" "$new_name"
done

echo "All running VMs have been renamed and updated."
