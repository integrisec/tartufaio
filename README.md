# tartufaio 🐗

```
  +------------------------------------------------------------------+
  |                                                                  |
  |                    T  A  R  T  U  F  A  I  O                     |
  |                     SMB Share Secret Scanner                     |
  |                    "il cacciatore di tartufi"                    |
  |                                                                  |
  |          _______                                                 |
  |         (_______) .---.                                          |
  |         ( o   o )/     \           _______                       |
  |          \ ___ / | BAG |          / o   o \                      |
  |           \___/   \___/          (  (vvv)  )~~  *sniff sniff*    |
  |           /| |\     |             \_______/                      |
  |          / | | \    | <-- stick      | |                         |
  |         /  | |  \   |            ~~~-+-+~~~                      |
  |        /___|_|___\  |                                            |
  |                     |                                            |
  +------------------------------------------------------------------+
```

**tartufaio** (*il cacciatore di tartufi* — "the truffle hunter") is a Bash script for
automated secret scanning across SMB/CIFS network shares. It mounts each share, runs
[TruffleHog](https://github.com/trufflesecurity/trufflehog) against the filesystem, saves
the results, unmounts, and moves on — iterating through a list of UNC paths and a list of
credential sets automatically.

Designed for internal red team engagements, penetration tests, and security audits where
multiple shares and credential sets need to be evaluated quickly.

---

## Features

- Accepts a plain-text list of UNC/SMB paths (`//server/share` or `\\server\share`)
- Multi-credential support — supply a credential file with one `user:pass[:domain]` entry
  per line; each share is tried against all credentials in order
- **First-success mode** (default) — stops at the first credential that mounts a share
- **Try-all mode** (`-a`) — attempts every credential per share, producing a separate scan
  log for each successful mount (useful for spotting permission differences between accounts)
- Auto-installs `cifs-utils` (via `apt`, `dnf`, or `yum`) and TruffleHog if not present
- Mounts shares **read-only** — no modifications to target systems
- Cleans up mount points automatically, even on crash or Ctrl-C (`trap EXIT`)
- color-coded output; scan summary at the end
- Log filenames encode the actual server and share name:
  `trufflehog_<server>_<share>.log`

---

## Requirements

| Requirement | Notes |
|---|---|
| Linux (x86_64) | Tested on Ubuntu 22.04 / 24.04, RHEL 8/9 |
| `bash` ≥ 4.0 | Ships with all modern distros |
| `root` / `sudo` | Required for `mount`/`umount` |
| `cifs-utils` | Auto-installed if missing |
| `curl` or `wget` | Used to install TruffleHog if missing |
| TruffleHog ≥ 3.x | Auto-installed to `/usr/local/bin` if missing |

---

## Installation

```bash
git clone https://github.com/youruser/tartufaio.git
cd tartufaio
chmod +x tartufaio.sh
```

---

## Usage

```
sudo ./tartufaio.sh -i <shares_file> -o <output_folder> [OPTIONS]
```

### Options

| Flag | Description | Default |
|---|---|---|
| `-i <file>` | UNC/SMB shares input file | *(required)* |
| `-o <dir>` | Output folder for scan logs | *(required)* |
| `-c <file>` | Credentials file (`user:pass[:domain]` per line) | *(prompted if omitted)* |
| `-u <user>` | Single SMB username (alternative to `-c`) | — |
| `-p <pass>` | Single SMB password (alternative to `-c`) | — |
| `-d <domain>` | SMB domain/workgroup for use with `-u`/`-p` | `WORKGROUP` |
| `-m <dir>` | Base directory for the mount point | `/mnt/smb_scan` |
| `-a` | Try **all** credentials per share, not just the first that works | off |
| `-h` | Show help and exit | — |

### Credential priority

`-c` credentials file > `-u`/`-p`/`-d` flags > interactive prompt

---

## Input file formats

### Shares file (`-i`)

One UNC path per line. Both slash styles are accepted. Lines beginning with `#` and blank
lines are ignored.

```
# Domain file servers
//fileserver01/Finance
//fileserver01/HR
\\nas.corp.local\Backups

# Remote office
//ro-fs01/Public
```

### Credentials file (`-c`)

Format: `username:password[:domain]` — one set per line. The domain field is optional and
defaults to `WORKGROUP`. Passwords may be empty (guest / null session).

```
# Domain admin
CORP\jsmith:P@ssw0rd!:CORP

# Local administrator fallback
administrator:Welcome1

# Guest / null session
guest:
```

> **Security note:** Restrict permissions on this file (`chmod 600 creds.txt`) and never
> commit it to version control. See `.gitignore`.

---

## Examples

**Single credential, stop at first success:**
```bash
sudo ./tartufaio.sh -i shares.txt -o /tmp/results -u jsmith -p 'P@ssw0rd!' -d CORP
```

**Credential file, stop at first success:**
```bash
sudo ./tartufaio.sh -i shares.txt -o /tmp/results -c creds.txt
```

**Credential file, try all credentials per share (`-a`):**
```bash
sudo ./tartufaio.sh -i shares.txt -o /tmp/results -c creds.txt -a
```

**Custom mount base:**
```bash
sudo ./tartufaio.sh -i shares.txt -o /tmp/results -c creds.txt -m /tmp/mnt
```

---

## Output

Each successfully scanned share produces a log file in the output folder:

```
/tmp/results/
  trufflehog_fileserver01_Finance.log        ← first (or only) successful credential
  trufflehog_fileserver01_Finance_2.log      ← second working credential (only with -a)
  trufflehog_nas.corp.local_Backups.log
  scan_errors.log                            ← mount/scan failures (if any)
```

Each log file begins with a header identifying the share and the credential used:

```
# TruffleHog scan of: //fileserver01/Finance
# Mounted with:       jsmith@CORP
# Scan started:       2025-03-14T10:23:01Z
# ─────────────────────────────────────────────
<trufflehog output>
```

---

## Disclaimer

This tool is intended for **authorised security testing only**. Only run it against systems
you own or have explicit written permission to test. Unauthorised access to computer systems
is illegal. The authors accept no liability for misuse.

---

## License

MIT — see [LICENSE](LICENSE).
