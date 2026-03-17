# Testing AMA sysext on Flatcar

All commands below assume you run them from the `sysext/` directory.

## What you need

- `az` CLI logged in
- Docker (for building the sysext image)
- SSH key at `~/.ssh/id_rsa.pub`

## 1. Spin up test VMs

```bash
./test/spin-up-test-vms.sh
source /tmp/ama-test-vms.env
```

This creates an Ubuntu VM (with stock AMA as reference) and a Flatcar VM,
plus a Log Analytics workspace and a DCR with syslog + perf counters.
The stock AMA extension is pushed to both VMs. On Flatcar the install
fails (expected) but WAAgent downloads and extracts the extension files.

## 2. Build the sysext image

Grab the `.deb` and extension binaries from the Flatcar VM (WAAgent
extracted them in the previous step):

```bash
SCP="scp -o StrictHostKeyChecking=no"
SSH_F="ssh -o StrictHostKeyChecking=no azureuser@$FLATCAR_IP"

EXT_F=$($SSH_F "sudo find /var/lib/waagent -maxdepth 1 -name 'Microsoft.Azure.Monitor.AzureMonitorLinuxAgent-*' -type d" | head -1)
EXT_VER=$(echo "$EXT_F" | grep -oP '\d+\.\d+\.\d+$')

$SCP "azureuser@$FLATCAR_IP:$EXT_F/packages/azuremonitoragent_*_x86_64.deb" /tmp/ama.deb
$SSH_F "cd $EXT_F && sudo tar czf /tmp/ama-ext.tar.gz amaCoreAgentBin agentLauncherBin MetricsExtensionBin AstExtensionBin azureotelcollector 2>/dev/null || true"
$SCP "azureuser@$FLATCAR_IP:/tmp/ama-ext.tar.gz" /tmp/ama-ext.tar.gz
mkdir -p /tmp/ama-ext && tar xzf /tmp/ama-ext.tar.gz -C /tmp/ama-ext

./dalec/build.sh x86_64 "$EXT_VER" /tmp/ama.deb /tmp/ama-ext
```

Output: `azuremonitoragent-v<VERSION>-x86-64.raw`

## 3. Copy patched files + sysext image to Flatcar

The patched python files are in this repo. The sysext image was just built.

```bash
# Patched files from this repo
$SCP ../../agent.py ../../sysext_handler.py azureuser@$FLATCAR_IP:~/
$SCP ../../ama_tst/modules/install/supported_distros.py azureuser@$FLATCAR_IP:~/supported_distros.py
$SCP ../../../LAD-AMA-Common/metrics_ext_utils/metrics_ext_handler.py azureuser@$FLATCAR_IP:~/metrics_ext_handler.py
$SCP ../../../LAD-AMA-Common/telegraf_utils/telegraf_config_handler.py azureuser@$FLATCAR_IP:~/telegraf_config_handler.py

# Sysext image
$SCP azuremonitoragent-v*-x86-64.raw azureuser@$FLATCAR_IP:~/

# Place everything into the extension directory
$SSH_F "
sudo cp ~/agent.py $EXT_F/agent.py
sudo cp ~/sysext_handler.py $EXT_F/sysext_handler.py
sudo cp ~/supported_distros.py $EXT_F/ama_tst/modules/install/supported_distros.py
sudo cp ~/metrics_ext_handler.py $EXT_F/metrics_ext_utils/metrics_ext_handler.py
sudo cp ~/telegraf_config_handler.py $EXT_F/telegraf_utils/telegraf_config_handler.py
sudo mkdir -p $EXT_F/sysext
sudo cp ~/azuremonitoragent-v*-x86-64.raw $EXT_F/sysext/azuremonitoragent-v${EXT_VER}-x86-64.raw
echo 'AGENT_VERSION=\"${EXT_VER}\"' | sudo tee $EXT_F/agent.version > /dev/null
"
```

## 4. Write the settings file

agent.py expects the WAAgent JSON wrapper. An empty `{}` won't work.

```bash
cat > /tmp/0.settings <<'EOF'
{
  "runtimeSettings": [
    {
      "handlerSettings": {
        "publicSettings": {},
        "protectedSettings": {}
      }
    }
  ]
}
EOF
$SCP /tmp/0.settings azureuser@$FLATCAR_IP:~/
$SSH_F "sudo cp ~/0.settings $EXT_F/config/0.settings"
```

## 5. Run install + enable

```bash
$SSH_F "sudo bash -c 'cd $EXT_F && NO_PROXY=169.254.169.254 python3 agent.py -install'"
$SSH_F "sudo bash -c 'cd $EXT_F && NO_PROXY=169.254.169.254 python3 agent.py -enable'"
```

Both should exit 0.

## 6. Check it works

```bash
# Services running?
$SSH_F "systemctl is-active azuremonitoragent azuremonitor-coreagent azuremonitor-agentlauncher"

# Send a test message
$SSH_F "logger -t ama-test 'hello from flatcar'"

# After ~5 min, check Log Analytics
az monitor log-analytics query \
    -w $(az monitor log-analytics workspace show -g ama-sysext-test -n ama-test-law --query customerId -o tsv) \
    --analytics-query 'Syslog | summarize count() by Computer'
```

Both `ama-ubuntu` and `ama-flatcar` should show up.

## 7. Cleanup

```bash
az group delete --name ama-sysext-test --yes --no-wait
```
