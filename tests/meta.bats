#!/usr/bin/env bats
# JSON schema_version, version 0.2.1, and the collaboration files.

load helpers

setup() { load_nosycat; }

@test "json starts with schema_version \"1\" (a string)" {
  HOST_NAME=h OS_NAME=x VIRT=kvm PROVIDER=none INIT_SYS=systemd OS_ID=x
  ok ENV-001 "x"
  run render_json
  printf '%s' "$output" | jq -e '.schema_version == "1"'
  [[ "$output" == '{"schema_version":"1",'* ]]
}

@test "full run json carries schema_version and is valid" {
  run bash "$NOSY_SRC/nosycat.sh" --only environment --format json
  printf '%s' "$output" | jq -e '.schema_version == "1" and .tool == "nosycat-toolkit"'
}

@test "version is 0.2.1 and the CHANGELOG has its section" {
  run bash "$NOSY_SRC/nosycat.sh" --version
  [ "$output" = "nosycat-toolkit 0.2.1" ]
  grep -q '^## \[0.2.1\]' "$NOSY_SRC/CHANGELOG.md"
}

@test "docs describe schema_version and its stability policy" {
  grep -q 'schema_version' "$NOSY_SRC/docs/json.md"
  grep -qi 'breaking' "$NOSY_SRC/docs/json.md"
  grep -q 'schema_version' "$NOSY_SRC/README.md"
}

@test "SECURITY.md covers supported versions, private reporting and scope" {
  local f="$NOSY_SRC/SECURITY.md"
  [ -f "$f" ]
  grep -qi 'supported versions' "$f"
  grep -q 'security/advisories/new' "$f"
  grep -qi 'read-only' "$f"
  grep -qi 'command injection' "$f"
  grep -qi 'temp' "$f"
}

@test "false positive issue template asks for id, distro and json output, with a redaction reminder" {
  local f="$NOSY_SRC/.github/ISSUE_TEMPLATE/false_positive.yml"
  [ -f "$f" ]
  grep -q '^name:' "$f"
  grep -q '^body:' "$f"
  grep -qi 'check id' "$f"
  grep -qi 'distro' "$f"
  grep -q -- '--format json --only' "$f"
  grep -qi 'redact' "$f"
  [ -f "$NOSY_SRC/.github/ISSUE_TEMPLATE/config.yml" ]
  grep -q 'security/advisories/new' "$NOSY_SRC/.github/ISSUE_TEMPLATE/config.yml"
}

@test "every check id used by the backup module is documented" {
  local id
  for id in $(grep -o 'BKP-[0-9]\{3\}' "$NOSY_SRC/modules/backup.sh" | sort -u); do
    grep -q "| $id |" "$NOSY_SRC/docs/checks.md" || { echo "$id missing from docs/checks.md"; return 1; }
  done
}
