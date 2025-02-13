#!/bin/bash

set -e  # Exit script on any error
set -o pipefail  # Ensure pipes return error if any command fails

# Variables
WAZUH_VERSION="4.10.1"
OVA_FILE="wazuh-${WAZUH_VERSION}.ova"
VMDK_FILE="wazuh-${WAZUH_VERSION}-disk-1.vmdk"
QCOW2_FILE="wazuh-${WAZUH_VERSION}-disk1.qcow2"
VM_ID=113
VM_NAME="Wazuh-${WAZUH_VERSION}"
STORAGE_POOL="local-lvm"
CPU_CORES=4
RAM_MB=8192
NET_BRIDGE="vmbr0"

echo "Step 1: Downloading Wazuh OVA file..."
if [ ! -f "${OVA_FILE}" ]; then
    wget -c "https://packages.wazuh.com/4.x/vm/${OVA_FILE}"
else
    echo "Wazuh OVA already downloaded, skipping."
fi

echo "Step 2: Extracting OVA file..."
if [ ! -f "${VMDK_FILE}" ]; then
    tar -xvf "${OVA_FILE}"
else
    echo "VMDK file already extracted, skipping."
fi

echo "Step 3: Converting VMDK to QCOW2 format..."
if [ ! -f "${QCOW2_FILE}" ]; then
    qemu-img convert -p -O qcow2 "${VMDK_FILE}" "${QCOW2_FILE}"
else
    echo "QCOW2 file already exists, skipping conversion."
fi

echo "Step 4: Creating Proxmox VM (ID: ${VM_ID})..."
if ! qm status "${VM_ID}" &>/dev/null; then
    qm create "${VM_ID}" --name "${VM_NAME}" --memory "${RAM_MB}" --cores "${CPU_CORES}" --net0 "virtio,bridge=${NET_BRIDGE}" --ostype l26
else
    echo "VM with ID ${VM_ID} already exists, skipping creation."
fi

echo "Step 5: Importing disk into Proxmox VM..."
if ! qm importdisk "${VM_ID}" "${QCOW2_FILE}" "${STORAGE_POOL}" --format qcow2; then
    echo "Error: Failed to import disk into Proxmox VM."
    exit 1
fi

echo "Step 6: Attaching disk to VM..."
DISK_PATH="${STORAGE_POOL}:${VM_ID}/vm-${VM_ID}-disk-0.qcow2"
qm set "${VM_ID}" --scsihw virtio-scsi-pci --scsi0 "${DISK_PATH}"

echo "Step 7: Configuring VM boot options..."
qm set "${VM_ID}" --boot order=scsi0 --serial0 socket --vga serial0

echo "Wazuh VM has been successfully set up in Proxmox!"
