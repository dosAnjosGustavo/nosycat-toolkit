# checks

Every check `nosycat.sh` runs. **Severity** is the worst status a check can return; `SKIP` is used whenever a check does not apply (tool not installed, inside a container, not root). Fix commands are suggestions printed by the tool. nosycat never runs them.

#### environment

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| ENV-001 | distribution from `/etc/os-release` | distro family drives package, firewall and path logic | WARN | run on a supported distro |
| ENV-002 | virtualization (VM, bare metal, container/LXC) | inside a container, kernel, firewall, swap and boot checks describe the host | WARN | run nosycat on the host |
| ENV-003 | provider hint (DMI, cloud-init, hostname) | reminds you that provider firewalls/security groups are invisible from inside | info | none |
| ENV-004 | package manager (apt, dnf/yum, apk, pacman, zypper) | update checks depend on it | WARN | none |
| ENV-005 | init system (systemd, OpenRC, other) | service checks depend on it | info | none |
| ENV-006 | running as root | as non-root, shadow, firewall rules, `sshd -T` and process names are hidden | WARN | `sudo ./nosycat.sh` |

#### cloud_init

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| CLD-001 | hostname is not a provider default (`vmi123`, `ip-10-0-0-1`, `ubuntu-s-1vcpu…`) | generic names make logs and alerts ambiguous | WARN | `hostnamectl set-hostname web-01.example.com` |
| CLD-002 | `cloud-init status` is `done` | errors mean users, keys or packages from user-data may be missing | FAIL | `cloud-init status --long` |
| CLD-003 | default image users (`ubuntu`, `ec2-user`, `rocky`…) still have a login shell | well-known usernames are brute-forced first | WARN | `usermod -L -s /usr/sbin/nologin USER` |
| CLD-004 | `sshd_config.d/*.conf` drop-in sets `PasswordAuthentication yes` | cloud-init drop-ins override `sshd_config`, so editing it alone does nothing | WARN | edit the drop-in, reload sshd |
| CLD-005 | keys in `/root/.ssh/authorized_keys` | deploy-time keys tend to stay forever | WARN | `ssh-keygen -lf /root/.ssh/authorized_keys` |

#### system

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| SYS-001 | hostname resolves (`getent hosts`) | `sudo: unable to resolve host`, mail and Java services fail | WARN | add `127.0.1.1 HOSTNAME` to `/etc/hosts` |
| SYS-002 | timezone set | ambiguous log timestamps and cron times | WARN | `timedatectl set-timezone UTC` |
| SYS-003 | clock synchronized (timedatectl / chrony) | drift breaks TLS, TOTP and log correlation | WARN | `timedatectl set-ntp true` or install chrony |
| SYS-004 | UTF-8 locale, no locale errors | perl/apt warnings, broken non-ASCII handling | WARN | `localectl set-locale LANG=C.UTF-8` |
| SYS-005 | swap present on hosts with < 8 GiB RAM | memory spikes hit the OOM killer instead of slowing down | WARN | create a swapfile |
| SYS-006 | `vm.swappiness` ≤ 60 | high values push app memory to disk early | WARN | `vm.swappiness=10` in sysctl.d |
| SYS-007 | disk usage per filesystem (warn 80%, fail 90%) | full disks corrupt databases and stop logging | FAIL | find large dirs with `du` |
| SYS-008 | inode usage (warn 80%, fail 90%) | "No space left on device" with free bytes | FAIL | find dirs with many files |
| SYS-009 | open-files hard limit ≥ 65536 | "Too many open files" under load | WARN | `LimitNOFILE=` in the unit or limits.conf |
| SYS-010 | OOM-killer events in the last 7 days | services may be dying and restarting silently | WARN | `journalctl -k \| grep -i 'killed process'` |
| SYS-011 | available RAM (warn < 20%, fail < 10%) | no headroom for spikes | FAIL | `ps aux --sort=-rss` |
| SYS-012 | 5-min load vs vCPUs (warn ≥ 1x, fail ≥ 2x) | saturation, I/O wait or provider CPU steal | FAIL | `top` (check `%st`, `%wa`) |

#### access

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| SSH-001 | sshd config readable (`sshd -T` as root, parsed config otherwise) | effective values include drop-ins and defaults | info | run as root |
| SSH-002 | `PasswordAuthentication no` (and no PAM keyboard-interactive) | password SSH is brute-forced within minutes | FAIL | `PasswordAuthentication no`, reload sshd |
| SSH-003 | `PermitRootLogin` | `yes` = root by password; `prohibit-password` = root by key | FAIL | `PermitRootLogin no` after creating a sudo user |
| SSH-004 | `PermitEmptyPasswords no` | accounts without password could log in | FAIL | `PermitEmptyPasswords no` |
| SSH-005 | SSH port | informational; port 22 is fine with key-only auth | info | none |
| SSH-006 | a non-root member of sudo/wheel/admin or sudoers exists | no audit trail; root login cannot be disabled | WARN | `adduser deploy && usermod -aG sudo deploy` |
| SSH-007 | home, `~/.ssh`, `authorized_keys` not group/world-writable, correct owner | StrictModes silently ignores keys → lockout | FAIL | `chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys` |
| SSH-008 | login accounts that never logged in (`lastlog`/`lastlog2`) | forgotten accounts are attack surface | WARN | lock or remove the account |
| SSH-009 | accounts with an empty password in `/etc/shadow` | console/su login without password | FAIL | `passwd -l USER` |

#### network

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| NET-001 | sockets on `0.0.0.0` / `::` / public IPs, excluding SSH and DHCP | everything bound there is internet-reachable unless filtered | WARN | bind to 127.0.0.1 or filter |
| NET-002 | host firewall active (ufw, firewalld, nftables, iptables) | FAIL when services are exposed and nothing filters them | FAIL | `ufw allow OpenSSH && ufw enable` |
| NET-003 | IPv6 covered by the firewall when a global IPv6 exists | ufw `IPV6=no` or ip-only nft tables leave IPv6 wide open | FAIL | `IPV6=yes` / `table inet` |
| NET-004 | nameserver configured and `example.com` resolves | updates, ACME and outbound APIs fail | FAIL | check resolv.conf / resolved |
| NET-005 | `net.ipv4.ip_forward` (expected with Docker/VPN) | a plain VPS should not route packets | WARN | `net.ipv4.ip_forward=0` |
| NET-006 | `net.ipv4.tcp_syncookies=1` | SYN-flood resilience | WARN | `net.ipv4.tcp_syncookies=1` |
| NET-007 | `accept_redirects=0` (all, default) | ICMP redirects can re-route traffic | WARN | set both to 0 |

#### updates

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| UPD-001 | pending updates from local metadata (security count where available) | fresh images are often weeks behind | FAIL (security) | `apt full-upgrade` / `dnf upgrade` / `apk upgrade` / `pacman -Syu` |
| UPD-002 | unattended-upgrades / dnf-automatic enabled | unattended servers fall behind on fixes | WARN | install and enable the tool |
| UPD-003 | reboot required (`/var/run/reboot-required`, `needs-restarting -r`, running kernel removed) | fixes not active; new kernel modules fail to load | WARN | reboot in a maintenance window |

#### docker

Skipped entirely when Docker is not installed.

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| DKR-001 | daemon reachable | containers will not start | WARN | `systemctl enable --now docker` |
| DKR-002 | members of the `docker` group | docker group = root | WARN | `gpasswd -d USER docker` |
| DKR-003 | privileged containers | isolation disabled | FAIL | use `cap_add`/`devices` |
| DKR-004 | `docker.sock` mounted into containers | socket access = root on host | WARN | socket proxy or remove |
| DKR-005 | ports published on `0.0.0.0`/`::` | Docker's iptables rules bypass ufw/firewalld | FAIL (with ufw/firewalld) | publish `127.0.0.1:PORT:PORT` |
| DKR-006 | restart policy set | container stays down after reboot | WARN | `restart: unless-stopped` |
| DKR-007 | json-file log `max-size` (per container or daemon.json) | logs fill the disk | WARN | `log-opts` in daemon.json |

#### services

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| SVC-001 | failed systemd units (crashed OpenRC services) | broken config or missing dependency | WARN | `systemctl status UNIT` |
| SVC-002 | enabled long-running services that are inactive (oneshot, timer/socket-activated and condition-skipped units excluded) | expected to run, but down | WARN | start or disable it |
| SVC-003 | persistent journal | logs lost on reboot, crash cause unknown | WARN | `mkdir /var/log/journal` or `Storage=persistent` |
| SVC-004 | journal size cap (`SystemMaxUse`) | default 10% of fs (max 4G) is a lot on small disks | WARN | `SystemMaxUse=500M` |
| SVC-005 | logrotate installed and scheduled | `/var/log` grows forever | WARN | install / enable `logrotate.timer` |

#### web_tls

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| WEB-001 | `nginx -t` | next reload takes the site down | FAIL | fix the reported line |
| WEB-002 | nginx `sites-enabled/default` still enabled | IP scans and unknown Hosts hit the default site | WARN | remove the symlink |
| WEB-003 | `apachectl -t` / `httpd -t` | next reload fails | FAIL | fix the reported line |
| WEB-004 | certificates in `/etc/letsencrypt/live` and nginx/apache config expire in < 21 days (`CERT_WARN_DAYS`) | renewal is broken; expired = FAIL | FAIL | `certbot renew --dry-run` |
| WEB-005 | certbot timer/cron present | certs silently expire after 90 days | WARN | `systemctl enable --now certbot.timer` |

#### security

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| SEC-001 | fail2ban or CrowdSec running | nothing bans brute-force sources | WARN | install fail2ban or CrowdSec |
| SEC-002 | SELinux enforcing / AppArmor enabled | compromised services are not confined | WARN | enable the distro's MAC |
| SEC-003 | world-writable files, and dirs without sticky bit, in `/etc`, `/usr/*bin`, systemd dirs, `/var/www`, `/opt`, `/srv`, `/root` | anyone can alter config or binaries | FAIL (system dirs) | `chmod o-w PATH` |
| SEC-004 | SUID binaries on `/` outside a known list; SUID in `/tmp`, `/home`, `/var/www` | privilege escalation / backdoor | FAIL (writable dirs) | verify package, `chmod u-s` |
| SEC-005 | `/tmp` and `/dev/shm` mounted `noexec` | exploits drop and run payloads there | WARN | tmpfs with `noexec` |
| SEC-006 | fstab data mounts without `nofail`, network mounts without `_netdev` | a detached volume drops boot into emergency mode, no SSH | WARN | add `nofail` / `_netdev` |

#### databases

| id | what | why it matters | severity | fix |
|---|---|---|---|---|
| DB-001 | MySQL/MariaDB, PostgreSQL, Redis, MongoDB, Memcached, Elasticsearch, CouchDB, InfluxDB listening beyond loopback (default port or process name) | exposed databases are scanned and ransomed within hours; private-network = WARN | FAIL | bind to 127.0.0.1 and firewall |
| DB-002 | Redis answers `PING` without auth | data read/write, file writes via `CONFIG SET` | FAIL (if public) | `requirepass` / ACLs |

#### snapshot (`--diff`)

`--snapshot` stores a baseline (default `/var/lib/nosycat/baseline`, mode 0700). `--diff` compares the live server to it. Each changed category is a WARN listing up to 5 added/removed entries.

| id | category |
|---|---|
| SNP-000 | baseline metadata (date) |
| SNP-001 | listening sockets (proto, address:port, process) |
| SNP-002 | enabled services, timers, sockets |
| SNP-003 | user accounts (name, uid, shell) |
| SNP-004 | members of sudo/wheel/admin/docker/root groups |
| SNP-005 | cron files (sha256) and systemd timers |
| SNP-006 | SSH authorized keys (sha256 per key, per user) |
| SNP-007 | installed package count |
| SNP-008 | containers (name, image) |
