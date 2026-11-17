# json report

`./nosycat.sh --format json` prints one JSON object. It is meant for Ansible, Wazuh, jq and anything else that reads reports without a human.

```json
{
  "schema_version": "1",
  "tool": "nosycat-toolkit",
  "version": "0.2.0",
  "generated_at": "2026-11-16T21:02:00Z",
  "host": "web-01.example.com",
  "problems_only": false,
  "environment": { "os": "Ubuntu 24.04.1 LTS", "os_id": "ubuntu", "family": "debian", "kernel": "6.8.0-48-generic",
                   "virt": "kvm", "virt_kind": "vm", "provider": "hetzner", "pkg_manager": "apt-get",
                   "init": "systemd", "firewall": "ufw", "root": true },
  "summary": { "ok": 31, "warn": 4, "fail": 1, "skip": 6, "ignored": 2, "info": 0, "ignore_expired": 1 },
  "checks": [
    { "id": "NET-002", "module": "network", "status": "OK", "title": "host firewall active: ufw", "detail": "", "fix": "" },
    { "id": "SEC-005", "module": "security", "status": "IGNORED", "title": "/tmp is not mounted noexec",
      "detail": "ignored, was WARN: installer needs exec (until 2027-01-31) · ...", "fix": "...",
      "original_status": "WARN", "ignore_reason": "installer needs exec", "ignore_until": "2027-01-31" },
    { "id": "BKP-003", "module": "backup", "status": "WARN", "title": "last backup 9 day(s) ago",
      "detail": "ignore expired 2026-11-01 (moving to restic) · newest: borg remote repo; ...", "fix": "...",
      "ignore_expired": "2026-11-01", "ignore_reason": "moving to restic" }
  ]
}
```

#### fields

| field | type | meaning |
|---|---|---|
| `schema_version` | string | version of this format, `"1"` today (see the policy below) |
| `tool`, `version` | string | `nosycat-toolkit` and its release version |
| `generated_at` | string | UTC time, ISO 8601 |
| `host` | string | hostname |
| `problems_only` | boolean | `true` with `-q`: `checks` holds only `WARN` and `FAIL`; `summary` still counts every check |
| `environment` | object | what nosycat detected about the server |
| `summary` | object | count per status, plus `ignore_expired` (ignores whose `until` date has passed) |
| `checks[]` | array | one object per check, in run order |
| `checks[].status` | string | `OK`, `WARN`, `FAIL`, `SKIP`, `INFO` or `IGNORED` |
| `checks[].original_status`, `ignore_reason`, `ignore_until` | string, string, string or null | only on `IGNORED`: what it would have been, your reason, and the last day the ignore applies (`null` = permanent) |
| `checks[].ignore_expired`, `ignore_reason` | string | only on a check whose ignore has expired: the date it expired and the reason it had |

Check ids are stable: an id keeps its meaning, and a removed check's id is never reused. All ids are listed in [`checks.md`](checks.md).

#### stability policy for `schema_version`

- **Not breaking, same `schema_version`:** new fields (top level, in `environment`, `summary` or a check), new modules and new check ids, new wording in `title`, `detail` and `fix`. Consumers should ignore fields they do not know and should not parse the free-text fields.
- **Breaking, `schema_version` goes up (`"2"`):** removing or renaming a field, changing a field's type or meaning, a new value for `status`, or changing what the exit codes mean. A breaking change is announced in the CHANGELOG under the release that makes it.
- `schema_version` is a string so a later format can be compared exactly (`== "1"`), not numerically.

Example guard in a pipeline:

```bash
sudo ./nosycat.sh --format json > report.json
jq -e '.schema_version == "1"' report.json >/dev/null || { echo "nosycat report format changed, check docs/json.md"; exit 1; }
```
