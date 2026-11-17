# changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-11-16

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
- **NET-002 / fail2ban and CrowdSec:** IP ban lists are not a firewall. Rules that only drop/reject listed sources (`ip saddr @set`, `saddr { ... }`, a single `saddr`; iptables `-s IP` and `-m set --match-set NAME src`) no longer count, and the `f2b-*` and `crowdsec*` nftables tables are ignored entirely, so a server with only fail2ban or CrowdSec is a FAIL/WARN instead of "firewall active". Allowlists (`saddr != @trusted drop`, `! -s NET -j DROP`) and a real firewall next to fail2ban are still detected; the NET-002 detail says when fail2ban or CrowdSec was seen.
- Titles, details and fix commands are trimmed, so SVC-001 no longer ends in a stray space (`failed units: casper-md5check.service `).
- **WEB-004:** only certificates used by the enabled config count (`nginx -T` as root, else `nginx.conf`, `conf.d`, `sites-enabled`; apache `sites-enabled`, `conf-enabled`, `conf.d`). Expired certs in `sites-available` no longer FAIL; unused Let's Encrypt lineages are a WARN.

### added

- `.nosycat.ignore` in the state dir and `--ignore FILE` (repeatable): accepted WARN/FAIL results become `IGNORED`, keep `original_status` and `ignore_reason` in JSON, and do not affect the exit code.
- Pretty text summary: a boxed card with FAIL/WARN/OK/SKIP counts and a proportional bar colored by status, status by module in two columns, a "fix first" list (FAIL before WARN, top 8, `+N more`), a verdict with a cat face (`=x.x=` failures, `=o.o=` warnings, `=^.^=` all clear) and how many of the skipped checks need root (`4 of 5 skipped checks need root`). Laid out by display width so it stays aligned and fits 80 columns. Same indentation as the check stream: headings (`❀ by module`, `❀ fix first`, the divider) at column 0, the box and every item at column 2.
- `INFO` status for notes about the run itself: counted in JSON (`summary.info`) and Markdown, never in "fix first" or the exit code.
- Single-file release asset: `nosycat.sh` with `lib/` and `modules/` inlined (`scripts/bundle.sh`, reproducible), published with its `.sha256` next to the tarball. CI checks that it runs on its own and gives the same JSON and text output as the source tree.
- Pastel palette in truecolor or 256 colors (8-color fallback), also on the per-check status tags, ids and fix commands. `--color auto|always|never`; `auto` colors only a terminal and honours `NO_COLOR` and `TERM=dumb`. `--no-color` is `--color never`.
- ASCII fallback for the box, bar, symbols and banner when the locale is not UTF-8, or with `--ascii`.
- bats test suite (105 tests) with fixtures under `tests/`, run in CI on the runner and in the Ubuntu, Debian, Rocky Linux and Alpine containers. `NOSY_ETC` and `NOSY_FX_*` generalize the old `NOSY_FSTAB` fixture hook.
- Release workflow: pushing a `v*` tag runs lint and tests, then publishes `nosycat-toolkit-X.Y.Z.tar.gz`, the single-file `nosycat.sh` and a `.sha256` for each. The README documents a verified install from a release.

### changed

- Less noise: a web server (nginx, apache, caddy, traefik, haproxy, lighttpd, envoy) on tcp 80/443 is expected in NET-001, and `/dev/shm` without `noexec` (Debian default) is noted in SEC-005's detail instead of raising a WARN.
- **ENV-006:** running without root is an `INFO` note (and the top-of-run note names the user) instead of a WARN, so it no longer leads "fix first" or turns the exit code into 1.
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
