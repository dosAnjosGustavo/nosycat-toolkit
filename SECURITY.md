# security policy

nosycat-toolkit is a security tool that people run with `sudo` on their servers, so a bug that breaks its promises is taken seriously.

#### supported versions

| version | supported |
|---|---|
| latest release (`0.2.x`) | yes |
| older releases | no, please upgrade |
| `main` | best effort; run a tagged release on servers |

Fixes land on `main` and ship in the next release with a CHANGELOG entry and new checksums.

#### reporting a vulnerability

Please report privately through **GitHub Security Advisories**: [open a private report](https://github.com/trizdev/nosycat-toolkit/security/advisories/new) (Security tab → "Report a vulnerability"). Do not open a public issue for a vulnerability.

Include the nosycat version, the distro, the command line you ran, and steps or a minimal file that reproduces it. If the private form is not available, open an issue that only says you have a security report and asks for a private channel, with no details.

You can expect an answer within 7 days. Once a fix is released, the advisory is published with credit, unless you prefer to stay anonymous.

#### scope

nosycat promises to be **read-only**: no service restarted, no package installed, no config, firewall rule or file changed. The only writes are the opt-in `--snapshot` (its own state dir, mode 0700) and `--output DIR`. It never runs the fix commands it prints, and never reads backup passwords, env files or keyrings.

**Counts as a vulnerability**

- any write, delete, permission change or service action outside `--snapshot` and `--output`
- command injection or code execution through anything nosycat parses: config files (`sshd_config`, nginx, `rsnapshot.conf`, cron, unit files), `.nosycat.ignore`, command output (`ss`, `nft`, `docker`), file names, hostnames or container names
- unsafe temporary files: predictable paths, symlink or race attacks on temp dirs, the state dir or report files, especially when run as root
- reading or printing secrets it should not touch (passwords, private keys, tokens), or leaking them into reports
- a network call beyond what the README documents (one DNS lookup, the package manager's own metadata)
- escape sequences from parsed data that can rewrite the terminal output
- a hang that ignores `--timeout`

**Not a vulnerability** (please open a normal issue)

- a false positive or false negative in a check: use the "false positive" issue template
- a suggested fix command that is wrong for your setup (fix commands are printed, never run)
- findings on a server you are not authorized to assess
