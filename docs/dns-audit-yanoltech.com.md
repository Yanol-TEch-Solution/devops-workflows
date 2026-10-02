# DNS Audit — yanoltech.com (cPanel Zone Editor dump)

**Captured:** 2026-08-24
**Source:** cPanel Zone Editor (yegarahosting / hostns.io nameservers)
**Purpose:** Phase 1 audit artifact. Preserved here so the full record set is recoverable if cPanel DNS is lost during Cloudflare migration.

**Configured nameservers at cPanel:** ns1.hostns.io, ns2.hostns.io (note: ns1/ns2.yanoltech.com A records also exist pointing to 75.2.86.204 / 166.117.220.151 — these are vestigial glue records, irrelevant once Cloudflare is NS)

**Key IPs:**
- 91.204.209.19 — cPanel server (main shared host for all apps + email)
- 196.188.225.194 — git.yanoltech.com (self-hosted Git)
- 196.188.225.211 — auth.yanoltech.com, portainer.yanoltech.com (Docker host)

---

## Critical email records (MUST replicate in Cloudflare)

| Name | Type | Record |
|---|---|---|
| yanoltech.com | MX | priority 0 → yanoltech.com |
| yanoltech.com | TXT (SPF) | `v=spf1 ip4:91.204.209.19 include:spf.hostns.io +a +mx -all` |
| _dmarc | TXT | `v=DMARC1; p=none;` |
| default._domainkey | TXT (DKIM) | `v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApwc8QGQ0QAjsHvogwF71pzmK95eC3Tr6JbbFrLN6RaAgLyoh1GmVMx1IA56Zp0SYMbkP6z1iiZuEYPJnHpVXRCj4Q6TRRVE/Lju8IwUwk7nfsL0OcaTxygRHhVbOVFEeaCw6uhfe/3kYSs9/OIFXcfwJIdVMYIAeoLtut0cvGVKxwL9s/er6C7S290T2pgggapUG8WuhBVnnVs1kq7zJ2BRgm8+Qic9fZal1OtmOQiOe8goeYfCXiNKydlAQfz7ptjHzW5JowviTini+qrJ2pdecim2bxsQ9VVi6fx9o2i0DB75Srm4NceZna8Ux4ls+RxuGVB4HaVjm55EU4cwmjQIDAQAB;` |
| mail | CNAME | yanoltech.com |
| webmail | A | 91.204.209.19 |
| autodiscover | A | 91.204.209.19 |
| autoconfig | A | 91.204.209.19 |
| _autodiscover._tcp | SRV | 0 0 443 cpanelemaildiscovery.cpanel.net |

**Migration note:** MX target must change from `yanoltech.com` to `mail.yanoltech.com` (A record, DNS-only) because the root A will be Cloudflare-proxied and Cloudflare doesn't proxy port 25.

---

## App subdomains (all → A 91.204.209.19)

Each has a `www.<sub>.yanoltech.com` A record too, plus cPanel boilerplate (cpcalendars, cpcontacts, webdisk, whm, cpanel, webmail, autodiscover, autoconfig, _caldav/_carddav/_caldavs/_carddavs SRV+TXT, default._domainkey DKIM) — boilerplate omitted here, only the app A records matter.

| Subdomain | Notes |
|---|---|
| gms | |
| ims | |
| nora-resort | |
| yanet | |
| liyana | |
| unit-tech | |
| nora | |
| menu | |
| noora | |
| menu-back | |
| ygh | |
| gelancity | |
| yanetv1 | |
| wereda | |
| sheger | |
| gelancity-v2 | |
| menuu | |
| gelancity-v3 | |
| housingnumber | |
| hn | |
| galancity | |
| lhc | |
| api | |
| liyaana | |
| yanetapi | |
| inventory | |
| housing-number | |
| shegercitty | |
| gelansubcity | |
| book | |
| liyanabook | |
| liyanahealthcare | |

---

## Non-cPanel hosts (different IPs — do not lose)

| Subdomain | IP | Purpose |
|---|---|---|
| git | 196.188.225.194 | Self-hosted Git server |
| auth | 196.188.225.211 | Auth service (Docker host) |
| portainer | 196.188.225.211 | Portainer (Docker host) |

---

## Records safe to drop after Cloudflare migration

- ns1.yanoltech.com, ns2.yanoltech.com (vestigial glue)
- ftp.yanoltech.com
- All per-subdomain cPanel boilerplate: cpcalendars, cpcontacts, webdisk, whm, cpanel, webmail, autodiscover, autoconfig, _caldav/_carddav/_caldavs/_carddavs SRV+TXT
- _acme-challenge.* (cPanel auto-SSL; Cloudflare handles TLS)
- _cpanel-dcv-test-record
- Per-subdomain default._domainkey (only root DKIM needed for email)
