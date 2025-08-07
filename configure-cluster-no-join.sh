#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Print each command to the console before executing it.
set -x

# Script parameters from the ARM template
MASTER_COUNT=$1
MASTER_VM_PREFIX=$2
MASTER_IP_OCTET4=$3
AZURE_USER=$4
# Parameter $5 is not used
MASTER_IP_PREFIX=$6

# --- 1. System Setup & Docker Installation (Runs on ALL nodes) ---

# Update package lists and install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl netcat-openbsd

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the Docker repository to Apt sources
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# Install the latest version of Docker Engine
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add the student user to the 'docker' group to run docker commands without sudo
sudo usermod -aG docker ${AZURE_USER}
echo "Docker installed successfully. User ${AZURE_USER} added to docker group."


# --- 2. Role-Specific Actions (Master vs. Agent) ---

# The first master node has a static IP defined in the template
MASTER_PRIVATE_IP="${MASTER_IP_PREFIX}${MASTER_IP_OCTET4}"

# Check if the current node's hostname matches the master prefix.
if [[ $(hostname) == *"${MASTER_VM_PREFIX}"* ]]; then
  
  # --- MASTER NODE ACTIONS ---
  echo "This is a MASTER node. Initializing Docker Swarm..."
  
  # Initialise the swarm
  sudo docker swarm init --advertise-addr ${MASTER_PRIVATE_IP}
  
  echo "--- MASTER CONFIGURATION COMPLETE ---"

else

  echo "--- AGENT CONFIGURATION COMPLETE ---"

fi