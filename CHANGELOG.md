# Changelog

All notable changes to tartufaio are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

---

## [1.0.0] - 2025-03-14

### Added
- Initial release.
- Accepts a plain-text list of UNC/SMB paths (both `//server/share` and
  `\\server\share` syntax supported).
- Multi-credential file support (`-c`): one `user:pass[:domain]` entry per line;
  blank lines and `#` comments are ignored.
- **First-success mode** (default): the first credential that successfully mounts a
  share is used and remaining credentials are skipped for that share.
- **Try-all mode** (`-a`): every credential is attempted per share; each successful
  mount triggers an independent TruffleHog scan with its own numbered log file.
- Single-credential flags (`-u`, `-p`, `-d`) as a lighter alternative to `-c`.
- Interactive credential prompt fallback when neither `-c` nor `-u` is supplied.
- Auto-installation of `cifs-utils` via `apt-get`, `dnf`, or `yum`.
- Auto-installation of TruffleHog via the official install script (requires `curl`
  or `wget`).
- Shares mounted read-only (`ro`) to avoid any modifications to target systems.
- SMBv3 attempted first; falls back to kernel-negotiated version on failure.
- Log filenames derived from the actual server and share name:
  `trufflehog_<server>_<share>[_N].log`.
- Log files include a header recording the UNC path, credential used, and UTC
  timestamp.
- `scan_errors.log` collects mount and scan failures for later review.
- `trap EXIT` cleanup: mount point is always unmounted and removed, even on crash
  or Ctrl-C.
- Colour-coded terminal output (info / ok / warn / error).
- Scan summary printed at exit showing total / succeeded / failed share counts,
  credential set count, and active mode.
- ASCII art banner depicting a truffle hunter and hog on startup.
