# changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.1] - Unreleased

### fixed

- **NET-002 / firewall detection:** nftables and iptables count as a firewall only when a chain hooked on `input` filters (policy drop, or a drop/reject rule in that chain or a chain it jumps to). Before, any `drop` anywhere matched, so the `DOCKER-ISOLATION-*` chains on a Docker host made an unfiltered server look protected. A lone `ct state invalid drop` no longer counts either.
- **DKR-005:** published container ports are a FAIL with any active host firewall (ufw, firewalld, nftables, iptables), since Docker bypasses INPUT for all of them; without a firewall it stays a WARN next to the NET-002 FAIL.
- **DB-002:** Redis is probed on the host:port it actually listens on (private IPs and non-default ports included), and is OK only on a `NOAUTH` reply. Connection refused, timeouts and other replies are a SKIP with the reason; `DENIED` (protected mode, no password) is a WARN. A `REDISCLI_AUTH` in the caller's environment is ignored.
- **CLD-004:** compares with the effective `PasswordAuthentication` (`sshd -T`, or the parsed config with first-value-wins), so a `50-cloud-init.conf` "yes" overridden by an earlier "no" is OK.
- `addr_scope`: the whole `fe80::/10` link-local range (`fe8x`-`febx`) is private, and `fd::`-style addresses are no longer mistaken for ULA.
- `ssh_ports` collects every `Port` and `ListenAddress host:port`, so SSH on a second port is not reported as exposed in NET-001.
- Fix commands reload the right unit: `ssh` on Debian/Ubuntu, `sshd` on RHEL and others, `rc-service sshd` on OpenRC.
- `--diff` fails if `mktemp -d` fails instead of using a predictable `/tmp/nosycat.PID` path, and temp dirs are removed on exit, Ctrl-C and TERM.
- **SEC-004:** SUID binaries must be owned by a package (`dpkg -S`, `rpm -qf`, `apk info --who-owns`, `pacman -Qo`, merged-`/usr` aware). A SUID file named `sudo` in `/opt` is no longer "known". The name list is only a fallback when no ownership tool exists.
- **WEB-004:** only certificates used by the enabled config count (`nginx -T` as root, else `nginx.conf`, `conf.d`, `sites-enabled`; apache `sites-enabled`, `conf-enabled`, `conf.d`). Expired certs in `sites-available` no longer FAIL; unused Let's Encrypt lineages are a WARN.

### added

- `.nosycat.ignore` in the state dir and `--ignore FILE` (repeatable): accepted WARN/FAIL results become `IGNORED`, keep `original_status` and `ignore_reason` in JSON, and do not affect the exit code.
- bats test suite (69 tests) with fixtures under `tests/`, run in CI on the runner and in the Ubuntu, Debian, Rocky Linux and Alpine containers. `NOSY_ETC` and `NOSY_FX_*` generalize the old `NOSY_FSTAB` fixture hook.
- Release workflow: pushing a `v*` tag runs lint and tests, then publishes `nosycat-toolkit-X.Y.Z.tar.gz` and its `.sha256`. The README documents a verified install from a release.

### changed

- Less noise: a web server (nginx, apache, caddy, traefik, haproxy, lighttpd, envoy) on tcp 80/443 is expected in NET-001, and `/dev/shm` without `noexec` (Debian default) is noted in SEC-005's detail instead of raising a WARN.
- The script banner is the README art (the cat typing `$ sniff`).
- README: CI status badge instead of the static ShellCheck badge. All GitHub Actions are pinned by commit SHA.

## [0.1.0] - 2026-11-16

### added

- `nosycat.sh` runner with `--only`, `--skip`, `--format text|md|json`, `--output`, `--no-color`, `--snapshot`, `--diff`, `--state-dir`, `--timeout`, `--list`, `--help`, `--version`.
- 11 check modules: environment, cloud_init, system, access, network, updates, docker, services, web_tls, security, databases (67 checks, see `docs/checks.md`).
- snapshot module: baseline of listeners, enabled units, users, admin groups, cron/timers, authorized_keys hashes, package count and containers, with `--diff` against it.
- Exit codes: 0 all OK, 1 WARN present, 2 FAIL present, 3 usage/runtime error.
- Support for Debian/Ubuntu, RHEL/Rocky/Alma, Alpine and Arch (apt, dnf/yum, apk, pacman, zypper; ufw, firewalld, nftables, iptables).
- Per-command timeouts so no check can hang the run.
- CI: `bash -n`, ShellCheck and test runs in Ubuntu, Debian, Rocky Linux and Alpine containers.
