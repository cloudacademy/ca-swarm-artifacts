#!/bin/bash

# --- START LOGGING ---
LOG_FILE="/var/log/deployment.log"
sudo touch ${LOG_FILE}
sudo chmod 666 ${LOG_FILE}
exec > >(sudo tee -a ${LOG_FILE}) 2>&1

echo "=================================="
echo "Deployment started at: $(date)"
echo "Hostname: $(hostname)"
echo "=================================="

# Print each command to the console before executing it.
set -x

# Script parameters from ARM template's variable, e.g.: clusterScriptCommand variable
MASTER_COUNT=$1
MASTER_VM_PREFIX=$2
MASTER_IP_OCTET4=$3
AZURE_USER=$4
# Parameter $5 is not used
MASTER_IP_PREFIX=$6

echo "Parameters received:"
echo "MASTER_COUNT=$MASTER_COUNT"
echo "MASTER_VM_PREFIX=$MASTER_VM_PREFIX"
echo "MASTER_IP_OCTET4=$MASTER_IP_OCTET4"
echo "AZURE_USER=$AZURE_USER"
echo "MASTER_IP_PREFIX=$MASTER_IP_PREFIX"

# --- 1. System Setup & Docker Installation (Runs on ALL nodes) ---

# Update repos
sudo apt-get update

# Install all prerequisites and Docker in one go
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

# Update to get Docker packages (necessary after adding new repo)
sudo apt-get update

# Install the latest version of Docker Engine
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Add the student user to the 'docker' group to run docker commands without sudo
sudo usermod -aG docker ${AZURE_USER}
echo "Docker installed successfully. User ${AZURE_USER} added to docker group."

# --- 2. Role-Specific Actions (Master vs. Agent) ---

# Get master node IP
MASTER_PRIVATE_IP="${MASTER_IP_PREFIX}${MASTER_IP_OCTET4}"
echo "Master IP will be: ${MASTER_PRIVATE_IP}"

# Check if the current node's hostname matches the master prefix.
if [[ $(hostname) == *"${MASTER_VM_PREFIX}"* ]]; then
  
  # --- MASTER NODE ACTIONS ---
  echo "This is a MASTER node. Initializing Docker Swarm..."
  
  # Ensure Docker is ready
  sleep 5
  
  # Initialise the swarm
  sudo docker swarm init --advertise-addr ${MASTER_PRIVATE_IP}
  
  # Get the complete 'docker swarm join' command for worker nodes
  SWARM_JOIN_COMMAND=$(sudo docker swarm join-token worker -q)
  
  # Write the full join command to a temporary file
  echo "sudo docker swarm join --token ${SWARM_JOIN_COMMAND} ${MASTER_PRIVATE_IP}:2377" > /tmp/join_command.sh
  
  echo "Join command created: $(cat /tmp/join_command.sh)"
  
  # Start a simple listener to serve the join command to agents when they ask for it.
  echo "Starting netcat listener on port 12345..."
  
  # Run netcat in background and continue the script
  nohup bash -c 'while true; do { echo -e "HTTP/1.1 200 OK\r\n"; cat /tmp/join_command.sh; } | sudo nc -l -q 0 12345; done' > /var/log/netcat.log 2>&1 &
  
  # Ensure netcat is listening
  sleep 2
  
  echo "--- MASTER CONFIGURATION COMPLETE ---"
  echo "Swarm is initialized. Netcat listener is ready to serve join tokens."
  echo "Master node is ready - notifying Azure that provisioning is complete."
  
  # NOTIFY AZURE: Master is ready
  echo "=================================="
  echo "Deployment completed at: $(date)"
  echo "=================================="
  exit 0
  
else

  # --- AGENT NODE ACTIONS ---
  echo "This is an AGENT node. Will connect to master once ready."
  echo "Target master IP: http://${MASTER_PRIVATE_IP}:12345"
  
  # NOTIFY AZURE EARLY: Worker is ready (will join swarm in background) to speed-up lab deployment progress
  echo "Worker node is provisioned and ready - notifying Azure."
  echo "Swarm join will continue in background."
  
  # Fork the joining process to background so Azure gets immediate success
  (
    # Re-enable logging for background process
    exec >> ${LOG_FILE} 2>&1
    set -x
    
    echo "=== BACKGROUND PROCESS: Starting swarm join attempt ==="
    
    # Retry attempts and delay
    MAX_RETRIES=30
    RETRY_DELAY=10
    
    for i in $(seq 1 $MAX_RETRIES); do
      echo "Attempt $i of $MAX_RETRIES to reach master..."
      
      if curl --connect-timeout 10 --max-time 20 "http://${MASTER_PRIVATE_IP}:12345" -o /tmp/join_swarm.sh 2>&1; then
        echo "Successfully retrieved join command from master!"
        break
      else
        if [ $i -eq $MAX_RETRIES ]; then
          echo "ERROR: Failed to connect to master after $MAX_RETRIES attempts"
          echo "This could be due to:"
          echo "1. Master not ready yet"
          echo "2. Network connectivity issues"
          echo "3. NSG blocking port 12345"
          exit 1
        fi
        echo "Failed to connect. Waiting ${RETRY_DELAY} seconds before retry..."
        sleep $RETRY_DELAY
      fi
    done
    
    echo "Master is ready. Executing join command..."
    echo "Join command content: $(cat /tmp/join_swarm.sh)"
    
    # Make the script executable and run it
    sudo chmod +x /tmp/join_swarm.sh
    sudo bash /tmp/join_swarm.sh
    
    # Verify joined successfully
    sleep 5
    if sudo docker info | grep -q "Swarm: active"; then
      echo "SUCCESS: Node has joined the swarm successfully!"
    else
      echo "WARNING: Node may not have joined the swarm correctly"
      sudo docker info | grep Swarm
    fi
    
    echo "=== BACKGROUND PROCESS: Agent configuration complete at $(date) ==="
    
  ) &
  
  # Wait a moment to ensure background process started
  sleep 2
  
  echo "--- AGENT PROVISIONING COMPLETE ---"
  echo "Background process (PID: $!) will handle swarm join."
  echo "=================================="
  echo "Deployment completed at: $(date)"
  echo "=================================="
  
  # Exit successfully - this tells Azure the extension succeeded
  exit 0
  
fi
