# NETRUN Node Runtime

Self-contained NETRUN proxy node runtime. This repo is only for the node-agent and proxy generator layer. It does not include orchestrator, Telegram bot, database, SKU, payment, inventory, or business logic.

## Fresh Node Install

```bash
git clone https://github.com/Tmwyw/node_runtime.git /opt/netrun
cd /opt/netrun
bash install_node.sh
```

## Archive Install

```bash
scp netrun-node.tar.gz root@server:/opt/
ssh root@server
cd /opt
tar -xzf netrun-node.tar.gz
cd netrun-node
bash install_node.sh
```

The installer copies the archive contents into `/opt/netrun` and installs the systemd service from there. It does not require `.git` and does not run git commands.

## Dirty Node Reinstall

```bash
bash scripts/clean_node.sh --remove-legacy-root
bash install_node.sh
```

`install_node.sh --clean --remove-legacy-root` is also supported when you explicitly want cleanup before install.

## Health Check

```bash
curl http://127.0.0.1:8085/health | jq .
bash scripts/smoke_health.sh
```

Expected health state:

```json
{
  "success": true,
  "status": "ready"
}
```

## Smoke Generate

```bash
bash scripts/smoke_generate.sh
```

This creates 10 socks5 proxies for job `smoke-30000` using:

```text
proxyCount=10
startPort=30000
proxyType=socks5
ipv6Policy=ipv6_only
networkProfile=high_compatibility
fingerprintProfileVersion=v2_android_ipv6_only_dns_custom
generatorScript=/opt/netrun/node_runtime/soft/generator/proxyyy_automated.sh
```

## Download proxies.list

From your local machine:

```bash
scp root@server:/opt/netrun/jobs/smoke-30000/proxies.list .
```

For a different job, replace `smoke-30000` with the job id.

## Expected Paths

```text
/opt/netrun
/opt/netrun/jobs
/opt/netrun/proxyserver
/opt/netrun/proxyserver/3proxy/bin/3proxy
/opt/netrun/proxyserver/.netrun_bootstrap.json
/etc/systemd/system/netrun-node-agent.service
```

The bundled 3proxy binary must exist at `deploy/node/bin/3proxy`. The installer fails fast with `missing_bundled_3proxy_binary` if it is missing.

## Fingerprint Contract

The proxy layer does not control Android browser fingerprinting. `android_mobile` is an intended client OS profile only. Production logs and job metadata must report:

```text
intended_client_os_profile=android_mobile
actual_client_profile=not_controlled_by_proxy
effective_client_os_profile=not_controlled_by_proxy
client_os_profile_enforcement=not_controlled_by_proxy
ipv6_policy=ipv6_only
effective_ipv6_policy=ipv6_only
```
