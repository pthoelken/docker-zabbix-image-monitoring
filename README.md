# 🐳 Docker Image Update Monitor — Zabbix 7.4 Template

Automatically discovers all running Docker containers and fires a Zabbix trigger whenever a newer image is available in the registry. No image pull required — only manifest digests are compared.

---

## How It Works

```
Zabbix Agent 2
    │
    ├── docker ps              →  LLD discovery (all running containers)
    ├── docker image inspect   →  reads local image digest (sha256)
    └── skopeo inspect         →  reads remote registry digest (no pull)
                                         │
                              digests differ? → trigger fires
```

The script compares the local `RepoDigest` of each container's image against the current manifest digest from the upstream registry using `skopeo`. This is a read-only, non-destructive operation — nothing is downloaded.

---

## Requirements

| Component | Notes |
|---|---|
| Zabbix Agent 2 | Tested with Zabbix 7.4 |
| `docker` | Must be accessible by the `zabbix` user |
| `skopeo` | `apt install skopeo` / `yum install skopeo` |
| `jq` | `apt install jq` / `yum install jq` |

---

## Files

| File | Purpose |
|---|---|
| `docker_image_check.sh` | The monitoring script called by Zabbix |
| `docker_updates.conf` | Zabbix Agent 2 `UserParameter` definitions |
| `docker_image_updates_template.yaml` | Zabbix 7.4 template (import-ready) |
| `install.sh` | Automated installer for Debian/Ubuntu systems |

---

## Installation

### Automated (recommended)

Run the installer as root on the target host. It handles all dependencies, file placement, permissions, and restarts Zabbix Agent 2 automatically.

```bash
curl -fsSL https://raw.githubusercontent.com/pthoelken/docker-zabbix-image-monitoring/main/install.sh | sudo bash
```

Or clone first and run locally:

```bash
git clone https://github.com/pthoelken/docker-zabbix-image-monitoring.git
cd docker-zabbix-image-monitoring
sudo bash install.sh
```

The installer will:
1. Verify Docker and Zabbix Agent 2 are present
2. Install missing dependencies (`git`, `skopeo`, `jq`) via `apt`
3. Deploy `docker_image_check.sh` to `/etc/zabbix/scripts/` with correct permissions
4. Deploy `docker_updates.conf` to `/etc/zabbix/zabbix_agent2.d/`
5. Add the `zabbix` user to the `docker` group
6. Restart `zabbix-agent2.service`

After the installer completes, continue with [Import the Zabbix template](#4--import-the-zabbix-template) below.

---

### Manual

#### 1 — Install dependencies

```bash
apt install -y skopeo jq
```

#### 2 — Install the script

```bash
mkdir -p /etc/zabbix/scripts
cp docker_image_check.sh /etc/zabbix/scripts/
chmod 755 /etc/zabbix/scripts/docker_image_check.sh
chown root:zabbix /etc/zabbix/scripts/docker_image_check.sh
```

#### 3 — Grant Docker access to the zabbix user

**Option A — simple** (zabbix gets full Docker socket access):

```bash
usermod -aG docker zabbix
```

**Option B — restricted sudo** (recommended for production):

```bash
cat > /etc/sudoers.d/zabbix-docker << 'EOF'
zabbix ALL=(root) NOPASSWD: /usr/bin/docker info
zabbix ALL=(root) NOPASSWD: /usr/bin/docker ps *
zabbix ALL=(root) NOPASSWD: /usr/bin/docker inspect *
zabbix ALL=(root) NOPASSWD: /usr/bin/docker image inspect *
EOF
chmod 440 /etc/sudoers.d/zabbix-docker
```

> If you use Option B, prefix the `docker` calls in `docker_image_check.sh` with `sudo`.

#### 4 — Install the agent configuration

```bash
cp docker_updates.conf /etc/zabbix/zabbix_agent2.d/
```

#### 5 — Increase the agent timeout

Edit `/etc/zabbix/zabbix_agent2.conf`:

```ini
Timeout=30
```

`skopeo` queries a remote registry and can take several seconds, especially under load or for slow registries.

#### 6 — Restart Zabbix Agent 2

```bash
systemctl restart zabbix-agent2
```

---

### 4 — Import the Zabbix template

1. Go to **Data collection → Templates → Import**
2. Upload `docker_image_updates_template.yaml`
3. Click **Import**

### 5 — Assign the template to your host

1. Go to **Data collection → Hosts**
2. Open your Docker host
3. Under **Templates**, add **Docker Image Update Monitor**
4. Save

### 6 — Test the script manually

Run as the `zabbix` user to catch permission problems before Zabbix does:

```bash
sudo -u zabbix /etc/zabbix/scripts/docker_image_check.sh daemon_status
sudo -u zabbix /etc/zabbix/scripts/docker_image_check.sh discover
sudo -u zabbix /etc/zabbix/scripts/docker_image_check.sh check_update <container_name>
```

Expected output for `check_update`: `0` (up to date) or `1` (update available).

---

## Dashboard Setup

Add a **Problems** widget to any dashboard and filter by tag `scope = update` to get a live overview of containers that need updating.

For a full monitoring panel, add a second widget filtered by `scope = availability` to catch Docker daemon outages.

---

## Item Return Codes

| Value | Meaning |
|---|---|
| `0` | Image is up to date |
| `1` | Update available |
| `2` | Cannot check (locally built image or registry unreachable) |
| `3` | Container not found / script error |

---

## Macros

Both macros can be overridden per host under **Host → Macros**.

| Macro | Default | Description |
|---|---|---|
| `{$DOCKER_UPDATE_INTERVAL}` | `1h` | How often to query the registry for updates |
| `{$DOCKER_DISCOVERY_INTERVAL}` | `5m` | How often to re-discover running containers |

---

## Private Registries

If your containers use images from private registries, configure `skopeo` credentials for the `zabbix` user:

```bash
sudo -u zabbix skopeo login registry.example.com -u USERNAME -p PASSWORD
```

Credentials are stored in `~zabbix/.config/containers/auth.json` and picked up automatically on subsequent `skopeo inspect` calls.

For **AWS ECR**, use the [Amazon ECR credential helper](https://github.com/awslabs/amazon-ecr-credential-helper) alongside `skopeo`.

---

## Known Limitations

| Scenario | Behavior |
|---|---|
| Locally built image (never pulled) | Returns `2` — no alarm trigger |
| Image pinned by digest (`@sha256:...`) | Returns `0` — treated as up to date |
| Registry unreachable | Returns `2` — INFO trigger fires |
| Private registry without credentials | Returns `2` — INFO trigger fires |
| Container stops between discovery and check | Returns `3` — INFO trigger fires |

---

## Triggers

| Name | Severity | Fires when |
|---|---|---|
| Docker daemon is not running | High | `docker.daemon.status = 0` |
| Container update available | Warning | `docker.image.update = 1` |
| Update check failed | Info | `docker.image.update >= 2` |

All triggers except the daemon check support **manual close**.

---

## License

MIT
