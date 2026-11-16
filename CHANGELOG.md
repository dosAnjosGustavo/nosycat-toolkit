# changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-16

### added

- `nosycat.sh` runner with `--only`, `--skip`, `--format text|md|json`, `--output`, `--no-color`, `--snapshot`, `--diff`, `--state-dir`, `--timeout`, `--list`, `--help`, `--version`.
- 11 check modules: environment, cloud_init, system, access, network, updates, docker, services, web_tls, security, databases (67 checks, see `docs/checks.md`).
- snapshot module: baseline of listeners, enabled units, users, admin groups, cron/timers, authorized_keys hashes, package count and containers, with `--diff` against it.
- Exit codes: 0 all OK, 1 WARN present, 2 FAIL present, 3 usage/runtime error.
- Support for Debian/Ubuntu, RHEL/Rocky/Alma, Alpine and Arch (apt, dnf/yum, apk, pacman, zypper; ufw, firewalld, nftables, iptables).
- Per-command timeouts so no check can hang the run.
- CI: `bash -n`, ShellCheck and test runs in Ubuntu, Debian, Rocky Linux and Alpine containers.
