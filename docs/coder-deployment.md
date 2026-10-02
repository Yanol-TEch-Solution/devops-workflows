# Yanol Tech — Coder Deployment (Remote Development Platform)

**Last updated:** 2026-09-03
**Status:** Live (core installation + domain routing working; HTTPS/WebSocket/workspace networking pending)
**Purpose:** Coder is Yanol Tech's internal remote development platform — for **development only**. It is explicitly not a CI/CD or production deployment tool. See `devops-infrastructure-plan.md` §5 for the design intent.

> **Architecture note:** Coder runs on a **separate server** from the main Dokploy VPS
> (23.88.60.140). This server also hosts the Liyana Healthcare application via raw Docker
> + Nginx (not Dokploy). That Liyana deployment predates the standardized platform and
> is a known deviation from `devops-standard.md` §8 (all apps via Dokploy). Documented
> here for accuracy; not a pattern to replicate for new projects.

---

## 1. Deployment Overview

```text
                         INTERNET
                            │
                            ▼
                  coder.yanoltech.com
                            │
                            ▼
                       Cloudflare
                            │
                         HTTPS
                            │
                            ▼
                    Server: 65.86.32.81
                            │
                            ▼
                         Nginx
                            │
                   reverse proxy
                            │
                            ▼
                    127.0.0.1:7080
                            │
                            ▼
                         Coder
                            │
                            ▼
                Coder Built-in PostgreSQL
```

Coder is **not** directly exposed to the Internet on port 7080. It listens only on
`127.0.0.1:7080`. Nginx handles external HTTP/HTTPS traffic.

---

## 2. Server Information

| Field | Value |
|---|---|
| Public IP | `65.86.32.81` |
| OS | AlmaLinux 9.8 (x86_64) |
| CPU | 8 cores |
| RAM | 15 GiB |
| Disk | 320 GB total (~20 GB used, ~300 GB available) |
| Swap | None configured |

This is a **separate server** from the main Dokploy VPS (`23.88.60.140`, Ubuntu, 7.6 GB RAM).
Do not confuse the two. The main VPS runs the standardized platform (Dokploy, shared infra,
8 projects). This server runs Coder + the Liyana Healthcare app.

---

## 3. Existing Applications on the Server

Before installing Coder, the server already hosted the Liyana Healthcare stack via Docker:

| Application | Container | Internal/host port |
|---|---|---|
| Liyana Frontend | `liyana_frontend` | `127.0.0.1:3000` |
| Liyana Admin | `liyana_admin` | `127.0.0.1:3001` |
| Liyana Backend | `liyana_backend` | `127.0.0.1:5000` |
| MySQL | `liyana_db` | Docker/internal `3306` |

Port `3000` was already occupied by the Liyana frontend, which is why Coder was moved to
port `7080` instead of its default `3000`.

> **Deviation from standard:** Liyana Healthcare runs via raw Docker + Nginx, not Dokploy.
> This is a pre-existing deployment, not the standardized pattern. New projects must follow
> `devops-standard.md` (Dokploy on the main VPS).

---

## 4. Coder Installation

Installed via the official script:

```bash
curl -L https://coder.com/install.sh | sh
```

| Field | Value |
|---|---|
| Version | `v2.37.0` (`v2.37.0+8a148a9`) |
| Verify | `coder version` |
| Linux user | `coder` (uid=993, gid=991), member of `docker` group |

The `coder` user is in the `docker` group so Coder can interact with Docker for workspace
provisioning.

---

## 5. Why Coder Does Not Run as Root

Coder's built-in PostgreSQL cannot run as root. Initial manual start as root failed with:

```text
The built-in PostgreSQL cannot run as the root user.
```

Coder now runs as `User=coder` / `Group=coder` under systemd. This is the correct
production approach.

---

## 6. systemd Service

| Field | Value |
|---|---|
| Service | `coder.service` |
| State | `active (running)`, `enabled` (auto-starts on reboot) |
| Config file | `/etc/coder.d/coder.env` |
| Unit file | `/usr/lib/systemd/system/coder.service` (package-managed — do not edit directly) |

Useful commands:

```bash
sudo systemctl status coder --no-pager
sudo systemctl start coder
sudo systemctl stop coder
sudo systemctl restart coder
sudo journalctl -u coder -f              # follow logs
sudo journalctl -u coder -n 100 --no-pager
systemctl is-enabled coder               # expect: enabled
```

---

## 7. Coder Configuration

`/etc/coder.d/coder.env`:

```text
CODER_HTTP_ADDRESS=127.0.0.1:7080
CODER_ACCESS_URL=https://coder.yanoltech.com
```

- `CODER_HTTP_ADDRESS` — Coder listens only on localhost, port 7080.
- `CODER_ACCESS_URL` — the public URL users access Coder through.

Port 7080 was chosen because Coder's default (`127.0.0.1:3000`) collides with the Liyana
frontend. Verify with:

```bash
sudo ss -lntp | grep 7080     # expect: LISTEN 127.0.0.1:7080
```

---

## 8. Coder PostgreSQL

Coder uses its **built-in PostgreSQL** (not the Liyana MySQL, not the shared platform
Postgres on the main VPS). Data lives under:

```text
/home/coder/.config/coderv2/postgres/
```

Separation:

```text
Liyana Healthcare  →  MySQL (liyana_db container)
Coder              →  Built-in PostgreSQL
```

Do **not** connect Coder to the Liyana MySQL or the shared platform Postgres.

---

## 9. Coder Data Directory

```text
/home/coder/.config/coderv2
```

Created and owned by `coder:coder`:

```bash
sudo mkdir -p /home/coder/.config/coderv2
sudo chown -R coder:coder /home/coder/.config
```

Contains Coder's local state including the built-in PostgreSQL data. Treat as important
data — include in backups.

---

## 10. DNS

| Field | Value |
|---|---|
| Domain | `coder.yanoltech.com` |
| A record | `65.86.32.81` |
| Verify | `dig +short coder.yanoltech.com` → `65.86.32.81` |

DNS is proxied through Cloudflare (confirmed by `Server: cloudflare` and `CF-RAY` headers).

---

## 11. Nginx Reverse Proxy

Nginx is already installed on this server handling ports 80/443 for the Liyana apps.
Coder was added as an additional virtual host.

Existing routing (Liyana):

```text
liyanahealthcare.com        → 127.0.0.1:3000
admin.liyanahealthcare.com  → 127.0.0.1:3001
api.liyanahealthcare.com    → 127.0.0.1:5000
```

Coder routing:

```text
coder.yanoltech.com         → 127.0.0.1:7080
```

Config file: `/etc/nginx/conf.d/coder.yanoltech.com.conf`

```nginx
server {
    listen 80;
    listen [::]:80;

    server_name coder.yanoltech.com;

    location / {
        proxy_pass http://127.0.0.1:7080;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
```

The `Upgrade` / `Connection "upgrade"` headers are **required** for Coder's WebSocket
connectivity. Do not remove them.

---

## 12. Network Ports

| Port | Binding | Purpose |
|---:|---|---|
| 22 | `0.0.0.0` | SSH |
| 80 | `0.0.0.0` | Nginx HTTP |
| 443 | `0.0.0.0` | Nginx HTTPS |
| 3000 | `127.0.0.1` | Liyana frontend |
| 3001 | `127.0.0.1` | Liyana admin |
| 5000 | `127.0.0.1` | Liyana backend |
| 7080 | `127.0.0.1` | Coder |

**7080 is NOT publicly exposed.** External users access `https://coder.yanoltech.com`,
never `http://65.86.32.81:7080`.

---

## 13. Verification Completed

```bash
curl -I http://coder.yanoltech.com
# HTTP/1.1 200 OK
# X-Coder-Build-Version: v2.37.0+8a148a9
```

Coder's CSP contains `wss://coder.yanoltech.com`, confirming Coder recognizes the
configured external hostname.

---

## 14. Reboot Behavior

```text
Server boots
    ├── Docker starts   → Liyana containers
    ├── Nginx starts    → ports 80/443
    └── Coder starts    → 127.0.0.1:7080 + built-in PostgreSQL
```

Coder is `enabled`, so it auto-starts after reboot without manual intervention.

---

## 15. Pending Work

The core installation and domain routing work. Still to verify/configure:

- **HTTPS** — confirm `https://coder.yanoltech.com` works through Cloudflare + Nginx.
- **Cloudflare SSL mode** — should be `Full (strict)`, not `Flexible`.
- **WebSocket verification** — confirm Coder WebSocket connections work through
  Cloudflare + Nginx.
- **Workspace networking** — if Coder workspace apps need to be reachable via domains
  like `app.workspace.coder.yanoltech.com`, additional wildcard DNS + reverse-proxy +
  TLS configuration is required. Configure separately; do not change the working
  dashboard config prematurely.
- **Backups** — `/home/coder/.config/coderv2` (Coder state + built-in PG data) is not
  yet backed up. Add to the backup strategy once R2 is stood up (see `devops-standard.md` §14).
- **Monitoring** — add UptimeRobot monitor for `https://coder.yanoltech.com` and a
  Netdata alert for the `coder.service` unit.

---

## 16. Important Files

| File | Purpose |
|---|---|
| `/etc/coder.d/coder.env` | Coder environment config |
| `/usr/lib/systemd/system/coder.service` | systemd unit (package-managed) |
| `/home/coder/.config/coderv2` | Coder data + built-in PostgreSQL |
| `/etc/nginx/conf.d/coder.yanoltech.com.conf` | Nginx vhost for Coder |
| `/etc/nginx/conf.d/` | All Nginx configs (Liyana + Coder) |

---

## 17. Quick Reference

```text
SERVER IP              65.86.32.81
OS                     AlmaLinux 9.8
CODER VERSION          v2.37.0
CODER DOMAIN           coder.yanoltech.com
CODER INTERNAL ADDRESS 127.0.0.1:7080
CODER CONFIG           /etc/coder.d/coder.env
CODER DATA             /home/coder/.config/coderv2
CODER SERVICE          coder.service
NGINX CONFIG           /etc/nginx/conf.d/coder.yanoltech.com.conf
PUBLIC ACCESS          https://coder.yanoltech.com
```

Fundamental rule:

```text
DO NOT expose 7080 publicly.

Internet → Cloudflare → Nginx :443 → 127.0.0.1:7080 → Coder
```

---

## 18. Maintenance Commands

```bash
# Coder
sudo systemctl status coder --no-pager
sudo systemctl restart coder
sudo journalctl -u coder -f
sudo ss -lntp | grep 7080

# DNS
dig +short coder.yanoltech.com

# Nginx
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl status nginx --no-pager

# Test Coder locally
curl -I http://127.0.0.1:7080

# Test through domain
curl -I http://coder.yanoltech.com
curl -I https://coder.yanoltech.com
```
