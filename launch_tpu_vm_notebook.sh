#!/bin/bash

# --- Configuration ---
# Updated default values as requested
TPU_NAME="stoelinga-notebook"
ZONE="us-central2-b"
PROJECT_ID=$(gcloud config get-value project) # Uses currently set gcloud project, or hardcode: "your-gcp-project-id"
ACCELERATOR_TYPE="v4-8"
TPU_SOFTWARE_VERSION="tpu-ubuntu2204-base"

# --- Jupyter Configuration ---
JUPYTER_TOKEN="test" # Default token set (consider changing for production/shared use)
LOCAL_PORT="8080"
REMOTE_JUPYTER_PORT="8888"
# --- End Configuration ---


# --- Step 1: Check & Create TPU VM (Idempotent) ---
echo "--- Checking for TPU VM: ${TPU_NAME} ---"
gcloud compute tpus tpu-vm describe "${TPU_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" > /dev/null 2>&1

if [[ $? -ne 0 ]]; then
  echo "TPU VM '${TPU_NAME}' not found. Creating (On-Demand)..."

  # Create the On-Demand TPU VM
  gcloud compute tpus tpu-vm create "${TPU_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --accelerator-type="${ACCELERATOR_TYPE}" \
    --version="${TPU_SOFTWARE_VERSION}"

  if [[ $? -ne 0 ]]; then
    echo "Error: TPU VM creation failed." ; exit 1
  fi
  echo "TPU VM created. Waiting for initialization..."
  sleep 30
else
  echo "TPU VM '${TPU_NAME}' already exists. Skipping creation."
fi


# --- Step 2: Setup JupyterLab on TPU VM ---
echo "--- Setting up JupyterLab on ${TPU_NAME} ---"
REMOTE_COMMANDS=$(cat <<EOF
set -x
echo "Running on remote TPU VM"
sudo apt-get update -y && sudo apt-get install -y python3-pip git screen
sudo pip3 install --upgrade pip
sudo pip3 install jupyterlab

echo "[Remote] Starting JupyterLab inside screen session 'jupyter_session'..."
pkill -f "jupyter-lab.*--port=${REMOTE_JUPYTER_PORT}" || true # Kill existing jupyter on the port
pkill -f "screen -S jupyter_session" || true # Kill existing screen session if any
sleep 2

# Start jupyter lab in a detached screen session named 'jupyter_session'
screen -S jupyter_session -dm bash -c 'jupyter lab \
  --no-browser \
  --ip=0.0.0.0 \
  --ServerApp.token="${JUPYTER_TOKEN}" \
  > ~/jupyter.log 2>&1'

sleep 5 # Give screen and jupyter a moment to start

# Check if the jupyter process is running (pgrep should find it even inside screen)
if ! pgrep -f "jupyter-lab.*--port=${REMOTE_JUPYTER_PORT}"; then
  echo "[Remote] Error: JupyterLab process failed to start. Check ~/jupyter.log"; exit 1
fi
echo "[Remote] JupyterLab setup complete."
EOF
)

gcloud compute tpus tpu-vm ssh "${TPU_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --command="${REMOTE_COMMANDS}"

if [[ $? -ne 0 ]]; then
  echo "Error: Failed executing remote setup commands via SSH." ; exit 1
fi
echo "JupyterLab setup initiated. Waiting for server..."
sleep 10


# --- Step 3: Setup SSH Port Forwarding ---
echo "--- Setting up SSH Port Forwarding ---"
echo ">>> Access Jupyter Lab at: http://localhost:${LOCAL_PORT}"
echo ">>> Token: ${JUPYTER_TOKEN}"
echo "(Press Ctrl+C here ONLY WHEN FINISHED to stop forwarding)"
echo "--------------------------------------"

gcloud compute tpus tpu-vm ssh "${TPU_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  -- \
  -L "${LOCAL_PORT}:localhost:${REMOTE_JUPYTER_PORT}" -N

echo "--- SSH Port Forwarding Stopped ---"
echo "--- Remember to delete the TPU VM when finished! ---"
echo "gcloud compute tpus tpu-vm delete ${TPU_NAME} --zone=${ZONE} --project=${PROJECT_ID}"
echo "----------------------------------------------------"
