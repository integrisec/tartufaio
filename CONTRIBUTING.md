# Contributing to tartufaio

Thanks for taking the time to contribute. The following guidelines keep the codebase
consistent and the review process smooth.

---

## Reporting issues

- Search [existing issues](../../issues) before opening a new one.
- Include: OS and version, Bash version (`bash --version`), exact command run,
  full terminal output, and (redacted) input files if relevant.
- For **security vulnerabilities** please do not open a public issue — contact the
  maintainers privately instead.

---

## Development setup

```bash
git clone https://github.com/youruser/tartufaio.git
cd tartufaio
chmod +x tartufaio.sh
```

No build step is required. The only runtime dependency is Bash ≥ 4.0.

### Recommended tools

| Tool | Purpose |
|---|---|
| [shellcheck](https://www.shellcheck.net/) | Lint the script before submitting |
| [bats-core](https://github.com/bats-core/bats-core) | Bash test framework (future tests) |

Run shellcheck before every commit:

```bash
shellcheck tartufaio.sh
```

---

## Submitting changes

1. Fork the repository and create a feature branch from `main`:
   ```bash
   git checkout -b feature/my-improvement
   ```
2. Make your changes, keeping each commit focused and atomic.
3. Ensure `shellcheck tartufaio.sh` reports no errors or warnings.
4. Update `CHANGELOG.md` under the `[Unreleased]` section.
5. Update `README.md` if your change affects usage, flags, or output format.
6. Open a pull request against `main` with a clear description of what changed
   and why.

---

## Code style

- Use 4-space indentation (no tabs).
- Follow the existing section-comment style (`# ── Section ──────`).
- All new flags must be documented in both the header comment block and `README.md`.
- Prefer `[[ ]]` over `[ ]` for conditionals.
- Always `local` variables inside functions.
- `set -euo pipefail` is active — ensure every code path handles errors explicitly.
- Never log passwords in plaintext; use a `<redacted>` placeholder if needed.

---

## Credential and target file hygiene

- **Never** commit `creds.txt`, `shares.txt`, `*.log`, or any file containing real
  hostnames or credentials. See `.gitignore`.
- Example files (`creds.example.txt`, `shares.example.txt`) are the only forms of
  input file that should ever appear in the repository.

---

## License

By contributing you agree that your changes will be licensed under the
[MIT License](LICENSE) that covers this project.
