#!/usr/bin/env bash
# modules/environment.sh - what kind of machine is this?
# shellcheck shell=bash

mod_environment() {
  if [ "$OS_ID" = "unknown" ]; then
    warn ENV-001 "distribution not identified" "/etc/os-release is missing or unreadable; distro-specific checks may be skipped" "cat /etc/os-release"
  else
    case "$OS_FAMILY" in
      unknown) warn ENV-001 "distribution: $OS_NAME" "not a tested family (debian, rhel, alpine, arch); results may be incomplete" "" ;;
      *) ok ENV-001 "distribution: $OS_NAME" "family $OS_FAMILY, kernel $(uname -r)" ;;
    esac
  fi

  case "$VIRT_KIND" in
    vm)        ok ENV-002 "virtualization: $VIRT (vm)" "full VM, all host checks apply" ;;
    baremetal) ok ENV-002 "virtualization: none (bare metal)" "all host checks apply" ;;
    container) warn ENV-002 "virtualization: $VIRT (container)" "running inside a container; kernel, firewall, swap and boot checks reflect the host and may be misleading" "run nosycat on the host itself for a full picture" ;;
    *)         warn ENV-002 "virtualization: unknown" "could not detect VM/container type" "install systemd-detect-virt (systemd) or virt-what" ;;
  esac

  if [ "$PROVIDER" = "unknown" ]; then
    ok ENV-003 "provider: not identified" "no DMI or cloud-init hint; provider-specific hints disabled"
  else
    ok ENV-003 "provider: $PROVIDER" "from $PROVIDER_SRC; remember provider-level firewalls/security groups are not visible from inside the VM"
  fi

  if [ "$PKG_MGR" = "none" ]; then
    warn ENV-004 "package manager not found" "update checks will be skipped" ""
  else
    ok ENV-004 "package manager: $PKG_MGR" ""
  fi

  ok ENV-005 "init system: $INIT_SYS" ""

  if [ "$IS_ROOT" -eq 1 ]; then
    ok ENV-006 "running as root" "full visibility"
  else
    # A note about this run, not a server problem: INFO never affects the exit code or "fix first".
    record INFO ENV-006 "running as $(id -un) (not root)" "reduced visibility: firewall rules, shadow, sshd -T, other users' files and process names are hidden; affected checks are marked SKIP. run with sudo for the full picture"
  fi
}
