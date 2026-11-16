```
                 .---.
               _/_____\_     ________
                ( o.o )     |$ sniff |
                 > ^ <      |$ _     |
                /     \_____|________|
               (__| |__)   /________/

      .·:*¨¨* ❀ nosycat-toolkit ❀ *¨¨*:·.
         post-deploy check-up for linux vps
               ~ sniffing for clues ~
```

<h1 align="center">nosycat-toolkit</h1>

<p align="center"><i>a curious little cat that sniffs your freshly deployed server for the things that bite later</i></p>

<p align="center">
  <img src="https://img.shields.io/badge/bash-4%2B-C9A2A6?style=flat-square&logo=gnubash&logoColor=white" alt="bash 4+">
  <img src="https://img.shields.io/badge/mode-read--only-A3B18A?style=flat-square" alt="read-only">
  <img src="https://img.shields.io/badge/debian%20%C2%B7%20rhel%20%C2%B7%20alpine%20%C2%B7%20arch-B8A9C9?style=flat-square&logo=linux&logoColor=white" alt="distros">
  <img src="https://img.shields.io/badge/shellcheck-passing-A3B18A?style=flat-square" alt="shellcheck">
  <img src="https://img.shields.io/badge/license-MIT-E9D8A6?style=flat-square" alt="MIT license">
</p>

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### what is it

You just deployed a VPS. It boots, SSH works, the app is up. Then, weeks later, a disk fills with container logs, a Redis instance ends up on a scanner list, a detached volume stops the server at boot, or Docker quietly publishes a port that ufw was supposed to block.

`nosycat.sh` is a single Bash script that runs right after deploy and flags those problems while they are still cheap to fix. Each check returns `OK`, `WARN`, `FAIL` or `SKIP`, a one-line reason, and a suggested fix command. It works on Debian/Ubuntu, RHEL/Rocky/Alma, Alpine and Arch, on any provider (Hetzner, Contabo, DigitalOcean, AWS, OVH, Vultr…), and needs nothing beyond Bash 4 and standard userland tools.

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### scope

**in scope**

- one Linux server, checked locally, right after deploy or after a big change
- configuration that commonly causes outages, lockouts or exposure: SSH, firewall, listeners, updates, Docker, services, logs, TLS, mounts, databases
- a baseline snapshot and a diff, to see what changed since deploy
- reports for humans (text, Markdown) and machines (JSON, exit codes)

**out of scope**

- auto-fixing: nosycat prints fix commands, it never runs them
- continuous monitoring or alerting (use a monitoring stack or a HIDS such as Wazuh)
- intrusion forensics, malware or rootkit detection
- Windows and macOS
- provider-side settings (cloud firewalls, security groups), which are not visible from inside the VM

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### safety

- **read-only.** No service is restarted, no package installed, no config edited, no firewall rule touched. Package checks use local metadata (`apt-get -s`, `dnf check-update`, `apk version`).
- **only two opt-in writes:** `--snapshot` saves a baseline to its own state dir (`/var/lib/nosycat`, mode 0700), and `--output DIR` writes the report to the directory you choose.
- **never hangs.** Slow or network-bound commands run under `timeout` (default 10s, `--timeout` to change); missing tools are skipped.
- **nothing leaves the server.** No network calls besides a DNS lookup of `example.com` and whatever your package manager does when queried.
- **works without root,** with reduced visibility: checks that need root are marked `SKIP` instead of guessing.

Read the code before running anything with `sudo`, this one included. It is about 1,700 lines of plain Bash.

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### quick start

```bash
git clone https://github.com/trizdev/nosycat-toolkit.git
cd nosycat-toolkit
sudo ./nosycat.sh
```

```bash
sudo ./nosycat.sh --only access,network,docker     # just a few modules
sudo ./nosycat.sh --skip updates                    # everything but updates
sudo ./nosycat.sh --format json > report.json       # machine-readable
sudo ./nosycat.sh --format md --output ./reports    # markdown file in ./reports
sudo ./nosycat.sh --snapshot                        # right after deploy
sudo ./nosycat.sh --diff                            # later: what changed?
```

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### sample output

> fabricated example for documentation (host `web-01.example.com`, address from the `192.0.2.0/24` documentation range). Abridged.

```
  v0.1.0 · host web-01.example.com · 2026-11-16 18:02 UTC · read-only

❀ environment
  [OK]   ENV-001  distribution: Ubuntu 24.04.1 LTS
  [OK]   ENV-002  virtualization: kvm (vm)
  [OK]   ENV-003  provider: hetzner
                  why: from dmi/hostname; remember provider-level firewalls/security groups are not visible from inside the VM

❀ cloud_init
  [OK]   CLD-002  cloud-init finished: done
  [WARN] CLD-004  sshd drop-in enables password auth: /etc/ssh/sshd_config.d/50-cloud-init.conf
                  why: provider/cloud-init drop-ins (e.g. 50-cloud-init.conf) are read before sshd_config and override it, so editing sshd_config alone does nothing
                  fix: sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config.d/50-cloud-init.conf && sudo systemctl reload ssh

❀ system
  [WARN] SYS-005  no swap configured (1963 MiB RAM)
                  why: on small VPS a memory spike (apt, composer, builds) triggers the OOM killer instead of slowing down

❀ access
  [FAIL] SSH-002  SSH password authentication is enabled
                  why: internet-facing SSH with passwords is brute-forced within minutes of deploy
  [OK]   SSH-006  non-root admin user(s): deploy

❀ network
  [WARN] NET-001  2 service(s) listening on all interfaces: 80/tcp(nginx), 443/tcp(nginx)
  [OK]   NET-002  host firewall active: ufw

❀ docker
  [FAIL] DKR-005  ports published on all interfaces: grafana 3000>3000/tcp
                  why: Docker writes its own iptables rules, so these ports are public even if ufw denies them
                  fix: publish as '127.0.0.1:8080:80' behind a reverse proxy, or filter in the DOCKER-USER chain
  [WARN] DKR-007  json-file logs without size limit: grafana, app

❀ databases
  [OK]   DB-001   databases bound to loopback only: postgresql on 127.0.0.1:5432

.·:*¨¨* ❀ *¨¨*:·.
  summary: 41 OK · 9 WARN · 2 FAIL · 15 SKIP
  fix the FAIL items first; they are the ones that usually bite right after deploy.
```

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### modules

| module | what it sniffs |
|---|---|
| `environment` | distro, VM/container/LXC, provider hint, package manager, init system, root or not |
| `cloud_init` | cloud-init errors, default provider hostname, default image users, sshd drop-ins re-enabling passwords, injected root keys |
| `system` | hostname resolution, timezone, NTP, locale, swap, swappiness, disk and inodes, open-files limit, OOM kills, RAM and load |
| `access` | effective sshd config (`sshd -T`), password and root login, port, non-root sudo user, `~/.ssh` permissions, unused accounts, empty passwords |
| `network` | listeners on `0.0.0.0`/`::`, host firewall, IPv6 without rules, DNS, `ip_forward`, SYN cookies, ICMP redirects |
| `updates` | pending (security) updates, unattended-upgrades / dnf-automatic, reboot required |
| `docker` | docker group, privileged containers, mounted `docker.sock`, ports bypassing ufw, restart policy, log size limits |
| `services` | failed units, enabled-but-dead services, persistent journal and size cap, logrotate |
| `web_tls` | `nginx -t`, default site, apache configtest, certificates expiring in < 21 days, certbot renewal timer |
| `security` | fail2ban / CrowdSec, SELinux / AppArmor, world-writable files, unexpected SUID, `/tmp` noexec, fstab `nofail` |
| `databases` | MySQL/MariaDB, PostgreSQL, Redis, MongoDB, Memcached, Elasticsearch… on non-loopback, Redis without auth |
| `snapshot` | `--snapshot` / `--diff`: listeners, services, users, admin groups, cron, authorized_keys, packages, containers |

Every check, with its id, rationale, severity and fix, is listed in [`docs/checks.md`](docs/checks.md).

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### output formats & exit codes

| `--format` | use |
|---|---|
| `text` | colored terminal output, printed as checks run (default) |
| `md` | Markdown report with an environment table and one table per module |
| `json` | `{tool, version, host, environment, summary, checks[]}`, one object per check with `id`, `module`, `status`, `title`, `detail`, `fix` |

| exit code | meaning |
|---|---|
| `0` | everything OK (SKIPs do not count) |
| `1` | at least one WARN |
| `2` | at least one FAIL |
| `3` | usage error or missing baseline |

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### using it with cron, ansible & wazuh

**cron:** weekly JSON report, kept locally:

```cron
0 6 * * 1  root  /opt/nosycat-toolkit/nosycat.sh --format json --output /var/log/nosycat >/dev/null 2>&1
```

**ansible:** run after provisioning and fail the play on `FAIL`:

```yaml
- name: nosycat post-deploy check-up
  ansible.builtin.command: /opt/nosycat-toolkit/nosycat.sh --format json
  register: nosy
  changed_when: false
  failed_when: nosy.rc >= 2
```

**wazuh:** point a `localfile` at the JSON reports so each run lands in the SIEM:

```xml
<localfile>
  <log_format>json</log_format>
  <location>/var/log/nosycat/*.json</location>
</localfile>
```

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### roadmap

- [ ] config file to silence accepted findings (`.nosycat.ignore`)
- [ ] JSON lines output (one event per check) for SIEM ingestion
- [ ] Podman and rootless Docker checks
- [ ] backup presence and age (restic, borg, provider snapshots)
- [ ] kernel hardening sysctl profile (`kptr_restrict`, `dmesg_restrict`, `rp_filter`)
- [ ] remote mode over SSH for several hosts
- [ ] bats test suite with fixture configs

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### disclaimer

nosycat is a checklist in script form. It reports common misconfigurations; it does not prove a server is secure, and a clean run is not an audit. Fix commands are generic suggestions: read them, adapt them to your setup, and keep a second SSH session open before touching SSH or firewall settings. Run it only on systems you own or are authorized to assess.

<p align="center">.·:*¨¨* ❀ *¨¨*:·.</p>

#### license

[MIT](LICENSE) © Ana Beatriz
