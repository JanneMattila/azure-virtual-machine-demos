#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Configuration (edit as needed)
# ----------------------------
SUBSCRIPTION_ID="<your-subscription-id>"
LOCATION="swedencentral"                      # Espoo -> use North Europe by default
RG="rg-boost-demo"
VM_NAME="vm-boost-demo"
VM_SIZE="Standard_D8s_v5"                   # Boost-enabled example size
IMAGE="Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"
ADMIN_USERNAME="azureuser"
# Generate a strong password or use SSH keys (recommended for Linux)
# Only used if --authentication-type password
if test -f "static-vm_password.env"; then
  # Password has been created so load it
  source static-vm_password.env
else
  # Generate password and store it
  ADMIN_PASSWORD=$(openssl rand -base64 32)
  echo "ADMIN_PASSWORD=$ADMIN_PASSWORD" > static-vm_password.env
fi
AUTH_TYPE="password"                              # "ssh" or "password"
SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"         # Used when AUTH_TYPE=ssh
VNET_NAME="vnet-boost-demo"
SUBNET_NAME="snet-boost-demo"
NSG_NAME="nsg-boost-demo"
PIP_NAME="pip-boost-demo"
NIC_NAME="nic-boost-demo"
DIAG_STORAGE=""                              # Leave empty to disable boot diagnostics
# Optional Ultra Disk data disk (set USE_ULTRA_DISK=true to attach one)
USE_ULTRA_DISK=true
DATA_DISK_NAME="datadisk-ultra"
DATA_DISK_SIZE_GB=128                        # Ultra Disk size
DATA_DISK_LUN=0
# Tags
TAGS="env=demo workload=boost owner=$USER"

# ----------------------------
# Login & subscription
# ----------------------------
echo "Logging in..."
az account show >/dev/null 2>&1 || az login --only-show-errors
az account set --subscription "$SUBSCRIPTION_ID"

# ----------------------------
# Validate VM size in region (Boost-related)
# ----------------------------
echo "Checking availability of VM size '$VM_SIZE' in '$LOCATION'..."
if ! az vm list-sizes --location "$LOCATION" --query "[?name=='$VM_SIZE']" -o tsv | grep -q "$VM_SIZE"; then
  echo "ERROR: VM size '$VM_SIZE' is not available in region '$LOCATION'."
  echo "Tip: run 'az vm list-sizes --location $LOCATION -o table' and pick a Boost-enabled size (e.g., Dsv5/Lsv3)."
  exit 1
fi

# ----------------------------
# Resource group
# ----------------------------
az group create -n "$RG" -l "$LOCATION" --tags $TAGS

# ----------------------------
# Networking
# ----------------------------
# VNet + Subnet
az network vnet create -g "$RG" -n "$VNET_NAME" -l "$LOCATION" \
  --address-prefixes 10.20.0.0/16 \
  --subnet-name "$SUBNET_NAME" --subnet-prefixes 10.20.1.0/24 \
  --tags $TAGS

# NSG (restrict RDP/SSH by your IP)
MY_IP="$(curl -s https://myip.jannemattila.com)"
az network nsg create -g "$RG" -n "$NSG_NAME" --tags $TAGS
az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" -n "allow-ssh-myip" \
  --priority 1000 --access Allow --direction Inbound --protocol Tcp \
  --source-address-prefixes "$MY_IP/32" --source-port-ranges "*" \
  --destination-address-prefixes "*" --destination-port-ranges 22

# Public IP (Standard SKU, zone-redundant where available)
az network public-ip create -g "$RG" -n "$PIP_NAME" -l "$LOCATION" \
  --sku Standard --allocation-method Static --tags $TAGS

# NIC with accelerated networking (Boost NIC path benefits)
SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" -n "$SUBNET_NAME" --query id -o tsv)
NSG_ID=$(az network nsg show -g "$RG" -n "$NSG_NAME" --query id -o tsv)
PIP_ID=$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query id -o tsv)

az network nic create -g "$RG" -n "$NIC_NAME" \
  --subnet "$SUBNET_ID" \
  --network-security-group "$NSG_ID" \
  --public-ip-address "$PIP_ID" \
  --accelerated-networking true \
  --tags $TAGS

# ----------------------------
# (Optional) Boot diagnostics
# ----------------------------
DIAG_ARGS=()
if [ -n "$DIAG_STORAGE" ]; then
  DIAG_ARGS=(--boot-diagnostics-storage "$DIAG_STORAGE")
fi

# ----------------------------
# Cloud-init (Linux) for basic tuning
# ----------------------------
cat > cloud-init.yml <<'YAML'
#cloud-config
package_update: true
packages:
  - htop
  - nvme-cli
runcmd:
  - sysctl -w net.core.rmem_max=134217728
  - sysctl -w net.core.wmem_max=134217728
  - echo "Cloud-init completed" > /var/log/cloud-init.done
YAML

# ----------------------------
# VM creation
# ----------------------------
CREATE_ARGS=(
  az vm create
  -g "$RG"
  -n "$VM_NAME"
  -l "$LOCATION"
  --size "$VM_SIZE"
  --nics "$NIC_NAME"
  --image "$IMAGE"
  --tags $TAGS
  --priority Regular
  --enable-agent
  --assign-identity               # System-assigned managed identity
  --custom-data cloud-init.yml
)

if [ "$AUTH_TYPE" = "ssh" ]; then
  # Ensure SSH key exists
  if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Generating SSH key at $HOME/.ssh/id_rsa..."
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
  fi
  CREATE_ARGS+=(--authentication-type ssh --ssh-key-values "$SSH_KEY_PATH")
else
  CREATE_ARGS+=(--authentication-type password --admin-password "$ADMIN_PASSWORD")
fi

CREATE_ARGS+=(--admin-username "$ADMIN_USERNAME")
"${CREATE_ARGS[@]}" ${DIAG_ARGS[@]}

# ----------------------------
# Ultra Disk (optional high IOPS data disk)
# ----------------------------
if [ "$USE_ULTRA_DISK" = true ]; then
  echo "Enabling UltraDisk capability on the VM..."
  az vm update -g "$RG" -n "$VM_NAME" --set "additionalCapabilities.ultraSSDEnabled=true"

  echo "Creating Ultra Disk ($DATA_DISK_SIZE_GB GiB) ..."
  DISK_ID=$(az disk create -g "$RG" -n "$DATA_DISK_NAME" \
    --size-gb "$DATA_DISK_SIZE_GB" \
    --sku UltraSSD_LRS \
    --query id -o tsv)

  echo "Attaching Ultra Disk to VM (LUN $DATA_DISK_LUN)..."
  az vm disk attach -g "$RG" --vm-name "$VM_NAME" \
    --name "$DATA_DISK_NAME" \
    --lun "$DATA_DISK_LUN" \
    --enable-caching None
fi

# ----------------------------
# Outputs & quick validation
# ----------------------------
echo "Deployment complete."
az vm show -g "$RG" -n "$VM_NAME" --query "{name:name, size:hardwareProfile.vmSize, location:location}" -o json

echo "Public IP:"
PUBLIC_IP=$(az network public-ip show -g "$RG" -n "$PIP_NAME" --query ipAddress -o tsv)
echo "$PUBLIC_IP"

echo "Accelerated networking enabled?"
az network nic show -g "$RG" -n "$NIC_NAME" --query "enableAcceleratedNetworking" -o tsv

ssh $ADMIN_USERNAME@"$PUBLIC_IP"

sshpass -p "$ADMIN_PASSWORD" ssh $ADMIN_USERNAME@"$PUBLIC_IP"


# ----------------------------
# Inside the VM: Performance testing
# ----------------------------
## Install
sudo apt install fio stress-ng numactl -y

## Inside the VM, check NVMe devices (Boost block storage path)
nvme list

# List NUMAs (Boost NUMA awareness)
lscpu | grep NUMA

# Check MANA nic
lspci

# Check MANA driver
grep /mana*.ko /lib/modules/$(uname -r)/modules.builtin || find /lib/modules/$(uname -r)/kernel -name mana*.ko*

# Check network interfaces
ip link

# Check network performance tuning
sysctl net.core.rmem_max
sysctl net.core.wmem_max

# Check disk performance (if Ultra Disk attached)
fio --name=randread --ioengine=libaio --rw=randread --bs=4k --numjobs=4 --size=1G --runtime=60 --group_reporting

# Run CPU, memory, sorting, and forking stress tests bound to NUMA node 0
numactl --cpunodebind=0 --membind=0 stress-ng --cpu 8 --vm 4 --vm-bytes 1G --vmstat 5 --timeout 60s
numactl --cpunodebind=0 --membind=0 stress-ng --cpu 8 --vm 2 --vmstat 5 --qsort 4 --fork 4 --timeout 60s

# Exit from the VM
exit

# ----------------------------
# Cleanup (uncomment to delete resources)
# ----------------------------
echo "Deleting resource group '$RG' and all its resources..."
az group delete -n "$RG" --yes --no-wait
