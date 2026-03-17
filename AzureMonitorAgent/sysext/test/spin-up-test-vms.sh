#!/bin/bash
# spin-up-test-vms.sh -- Spin up Ubuntu + Flatcar VMs for AMA comparison
#
# Creates two cheap VMs in parallel, waits for both, installs AMA on
# the Ubuntu one, and prints SSH connection info.
#
# Usage:
#   ./spin-up-test-vms.sh [resource-group] [location] [hours]
#
# Defaults:
#   resource-group: ama-sysext-test
#   location:       westeurope
#   hours:          4 (auto-shutdown after this)
#
# Prerequisites:
#   - az cli logged in (az login)
#   - SSH key at ~/.ssh/id_rsa.pub (or set SSH_PUB_KEY)
#
# Cleanup:
#   az group delete --name ama-sysext-test --yes --no-wait

set -euo pipefail

RG="${1:-ama-sysext-test}"
LOCATION="${2:-westeurope}"
HOURS="${3:-4}"
VM_SIZE="Standard_B1s"
SSH_PUB_KEY="${SSH_PUB_KEY:-${HOME}/.ssh/id_rsa.pub}"
ADMIN_USER="azureuser"

FLATCAR_IMAGE="kinvolk:flatcar-container-linux-free:stable-gen2:latest"
UBUNTU_IMAGE="Canonical:ubuntu-24_04-lts:server:latest"
WORKSPACE_NAME="ama-test-law"
DCR_NAME="ama-test-dcr"

SHUTDOWN_TIME=$(date -u -d "+${HOURS} hours" +%H%M 2>/dev/null || \
                date -u -v+${HOURS}H +%H%M 2>/dev/null || echo "2300")

echo "============================================"
echo " AMA Sysext Test VMs"
echo "============================================"
echo " Resource Group: $RG"
echo " Location:       $LOCATION"
echo " VM Size:        $VM_SIZE"
echo " Auto-shutdown:  ${HOURS}h (~${SHUTDOWN_TIME} UTC)"
echo "============================================"
echo ""

[ -f "$SSH_PUB_KEY" ] || { echo "ERROR: SSH key not found: $SSH_PUB_KEY"; exit 1; }

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------

echo "--- Creating resource group ---"
az group create \
    --name "$RG" \
    --location "$LOCATION" \
    --tags "purpose=ama-sysext-test" \
    --output none
echo ""

# ---------------------------------------------------------------------------
# Log Analytics workspace (needed for DCR destination)
# ---------------------------------------------------------------------------

echo "--- Creating Log Analytics workspace ---"
az monitor log-analytics workspace create \
    --resource-group "$RG" \
    --workspace-name "$WORKSPACE_NAME" \
    --location "$LOCATION" \
    --retention-time 30 \
    --output none

WORKSPACE_ID=$(az monitor log-analytics workspace show \
    --resource-group "$RG" \
    --workspace-name "$WORKSPACE_NAME" \
    --query id --output tsv)

echo "  ok: $WORKSPACE_NAME"
echo ""

# ---------------------------------------------------------------------------
# Data Collection Rule (syslog + perf counters)
# ---------------------------------------------------------------------------

echo "--- Creating Data Collection Rule ---"

DCR_JSON=$(cat <<DCREOF
{
    "location": "${LOCATION}",
    "kind": "Linux",
    "properties": {
        "dataSources": {
            "syslog": [{
                "name": "syslog-source",
                "streams": ["Microsoft-Syslog"],
                "facilityNames": ["auth", "authpriv", "daemon", "kern", "syslog", "user"],
                "logLevels": ["Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency"]
            }],
            "performanceCounters": [{
                "name": "perfcounter-source",
                "streams": ["Microsoft-Perf"],
                "samplingFrequencyInSeconds": 60,
                "counterSpecifiers": [
                    "Processor(*)\\\\% Processor Time",
                    "Processor(*)\\\\% Idle Time",
                    "Processor(*)\\\\% User Time",
                    "Processor(*)\\\\% Privileged Time",
                    "Memory(*)\\\\% Used Memory",
                    "Memory(*)\\\\% Available Memory",
                    "Memory(*)\\\\Available MBytes Memory",
                    "Logical Disk(*)\\\\% Used Space",
                    "Logical Disk(*)\\\\% Free Space",
                    "Logical Disk(*)\\\\Free Megabytes",
                    "Logical Disk(*)\\\\Disk Transfers/sec",
                    "Logical Disk(*)\\\\Disk Read Bytes/sec",
                    "Logical Disk(*)\\\\Disk Write Bytes/sec",
                    "Network(*)\\\\Total Bytes Transmitted",
                    "Network(*)\\\\Total Bytes Received"
                ]
            }]
        },
        "destinations": {
            "logAnalytics": [{
                "name": "la-destination",
                "workspaceResourceId": "${WORKSPACE_ID}"
            }]
        },
        "dataFlows": [
            {
                "streams": ["Microsoft-Syslog"],
                "destinations": ["la-destination"]
            },
            {
                "streams": ["Microsoft-Perf"],
                "destinations": ["la-destination"]
            }
        ]
    }
}
DCREOF
)

echo "$DCR_JSON" > "/tmp/ama-test-dcr.json"

az monitor data-collection rule create \
    --resource-group "$RG" \
    --name "$DCR_NAME" \
    --location "$LOCATION" \
    --rule-file "/tmp/ama-test-dcr.json" \
    --output none

DCR_ID=$(az monitor data-collection rule show \
    --resource-group "$RG" \
    --name "$DCR_NAME" \
    --query id --output tsv)

echo "  ok: $DCR_NAME"
echo ""

# ---------------------------------------------------------------------------
# Accept Flatcar terms (idempotent, fast)
# ---------------------------------------------------------------------------

az vm image terms accept \
    --publisher kinvolk \
    --offer flatcar-container-linux-free \
    --plan stable-gen2 \
    --output none 2>/dev/null || true

# ---------------------------------------------------------------------------
# Launch BOTH VMs in parallel (backgrounded, each blocks until done)
# ---------------------------------------------------------------------------

COMMON_ARGS=(
    --resource-group "$RG"
    --size "$VM_SIZE"
    --admin-username "$ADMIN_USER"
    --ssh-key-value "@${SSH_PUB_KEY}"
    --public-ip-sku Standard
    --os-disk-size-gb 30
    --output none
)

echo "--- Creating both VMs in parallel (this takes ~2-4 minutes) ---"

az vm create --name "ama-ubuntu"  --image "$UBUNTU_IMAGE"  "${COMMON_ARGS[@]}" &
PID_UBUNTU=$!

az vm create --name "ama-flatcar" --image "$FLATCAR_IMAGE" "${COMMON_ARGS[@]}" &
PID_FLATCAR=$!

FAILED=0
wait $PID_UBUNTU  && echo "  ok: ama-ubuntu ready"  || { echo "  FAIL: ama-ubuntu FAILED"; FAILED=1; }
wait $PID_FLATCAR && echo "  ok: ama-flatcar ready" || { echo "  FAIL: ama-flatcar FAILED"; FAILED=1; }
[ $FAILED -eq 0 ] || { echo "ERROR: One or both VMs failed to create"; exit 1; }

echo ""

# ---------------------------------------------------------------------------
# Auto-shutdown (fire-and-forget, both in parallel)
# ---------------------------------------------------------------------------

echo "--- Setting auto-shutdown ---"
az vm auto-shutdown --resource-group "$RG" --name "ama-ubuntu"  --time "$SHUTDOWN_TIME" --output none 2>/dev/null &
az vm auto-shutdown --resource-group "$RG" --name "ama-flatcar" --time "$SHUTDOWN_TIME" --output none 2>/dev/null &
wait
echo "  ok: Both VMs set to shut down at ~${SHUTDOWN_TIME} UTC"
echo ""

# ---------------------------------------------------------------------------
# Install AMA extension on Ubuntu (this is the slow part, ~2-5 min)
# ---------------------------------------------------------------------------

echo "--- Installing AMA extension on both VMs ---"
echo "  (this takes 2-5 minutes)"

az vm extension set \
    --resource-group "$RG" \
    --vm-name "ama-ubuntu" \
    --name AzureMonitorLinuxAgent \
    --publisher Microsoft.Azure.Monitor \
    --output none &
EXT_PID_UBUNTU=$!

# This will fail (Flatcar not supported by stock installer) but WAAgent
# downloads and extracts the extension files, which is what we need.
az vm extension set \
    --resource-group "$RG" \
    --vm-name "ama-flatcar" \
    --name AzureMonitorLinuxAgent \
    --publisher Microsoft.Azure.Monitor \
    --output none 2>/dev/null &
EXT_PID_FLATCAR=$!

# ---------------------------------------------------------------------------
# Get IPs + associate DCR while extension installs
# ---------------------------------------------------------------------------

UBUNTU_IP=$(az vm show --resource-group "$RG" --name "ama-ubuntu" \
    --show-details --query publicIps --output tsv)
FLATCAR_IP=$(az vm show --resource-group "$RG" --name "ama-flatcar" \
    --show-details --query publicIps --output tsv)

UBUNTU_VM_ID=$(az vm show --resource-group "$RG" --name "ama-ubuntu" \
    --query id --output tsv)
FLATCAR_VM_ID=$(az vm show --resource-group "$RG" --name "ama-flatcar" \
    --query id --output tsv)

echo ""

# Associate DCR with both VMs (parallel, fire-and-forget)
echo "--- Associating DCR with both VMs ---"
az monitor data-collection rule association create \
    --name "ubuntu-dcra" \
    --resource "$UBUNTU_VM_ID" \
    --rule-id "$DCR_ID" \
    --output none &

az monitor data-collection rule association create \
    --name "flatcar-dcra" \
    --resource "$FLATCAR_VM_ID" \
    --rule-id "$DCR_ID" \
    --output none &

wait
echo "  ok: DCR associated with both VMs"
echo ""

# Wait for extensions to finish
echo "  Waiting for AMA extensions..."
wait $EXT_PID_UBUNTU  && echo "  ok: AMA extension installed on Ubuntu" || echo "  WARN: AMA extension install on Ubuntu may have failed"
wait $EXT_PID_FLATCAR 2>/dev/null; echo "  ok: AMA extension files extracted on Flatcar (install failure is expected)"
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo "============================================"
echo " READY"
echo "============================================"
echo ""
echo " Ubuntu (dpkg AMA):     ssh ${ADMIN_USER}@${UBUNTU_IP}"
echo " Flatcar (sysext AMA):  ssh ${ADMIN_USER}@${FLATCAR_IP}"
echo ""
echo " Auto-shutdown: ~${SHUTDOWN_TIME} UTC (${HOURS}h from creation)"
echo ""
echo " Log Analytics: $WORKSPACE_NAME"
echo " DCR:           $DCR_NAME (syslog + perf counters)"
echo ""
echo " Check logs after ~5 min:"
echo "   az monitor log-analytics query -w \$(az monitor log-analytics workspace show -g $RG -n $WORKSPACE_NAME --query customerId -o tsv) --analytics-query 'Syslog | take 10'"
echo ""
echo " Cleanup:"
echo "   az group delete --name ${RG} --yes --no-wait"
echo ""
echo "============================================"

cat > "/tmp/ama-test-vms.env" <<EOF
UBUNTU_IP=${UBUNTU_IP}
FLATCAR_IP=${FLATCAR_IP}
ADMIN_USER=${ADMIN_USER}
RG=${RG}
WORKSPACE_NAME=${WORKSPACE_NAME}
DCR_NAME=${DCR_NAME}
DCR_ID=${DCR_ID}
# ssh ${ADMIN_USER}@${UBUNTU_IP}
# ssh ${ADMIN_USER}@${FLATCAR_IP}
# az monitor log-analytics query -w $(az monitor log-analytics workspace show -g ${RG} -n ${WORKSPACE_NAME} --query customerId -o tsv) --analytics-query 'Syslog | take 10'
# az group delete --name ${RG} --yes --no-wait
EOF

echo " Connection info: /tmp/ama-test-vms.env"
echo " Source it:  source /tmp/ama-test-vms.env"
