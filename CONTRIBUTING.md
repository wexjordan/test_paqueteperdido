# Contributing to netmon-suite

Thank you for your interest in contributing! This is a small open-source tool and all contributions are welcome.

---

## Ways to Contribute

- **Bug reports** — open an issue describing what happened, what you expected, your OS, Python version, and relevant log output.
- **Feature requests** — open an issue with a clear description of the use case.
- **Pull requests** — see the workflow below.
- **Documentation** — improvements to README, LEEME (Spanish), or `docs/` are very welcome.
- **Testing on new distros** — if you test on a new Linux distribution, please report your findings.

---

## Development Setup

No build steps are needed. The tools are plain Python 3 scripts and Bash, with zero external dependencies.

```bash
git clone https://github.com/wexjordan/netmon-suite.git
cd netmon-suite
```

To test locally without a real second server, use `install.sh both` on a single host and set `REMOTE_HOST=127.0.0.1`.

---

## Pull Request Workflow

1. **Fork** the repository and create a branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. Make your changes. Keep commits focused (one logical change per commit).

3. **Test** your changes:
   - `install.sh` works without errors on a clean system.
   - `netmon-ctl test` passes when a server is running.
   - New Python code runs under Python 3.7+ (no f-strings above 3.6, no walrus operator, etc.).

4. Update `README.md` or `LEEME.md` if your change affects usage or configuration.

5. Open a pull request with a clear description of **what** and **why**.

---

## Code Style

- **Python**: follow PEP 8. Keep functions small and focused. No external libraries — stdlib only.
- **Bash**: use `set -e`, quote all variables, prefer `[[ ]]` over `[ ]`.
- **Systemd units**: follow the existing hardening patterns (`NoNewPrivileges`, `ProtectSystem`, etc.).

---

## Reporting Security Issues

Please **do not** open a public issue for security vulnerabilities. Email the maintainer directly (see the GitHub profile) or use GitHub's private security advisory feature.

---

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
