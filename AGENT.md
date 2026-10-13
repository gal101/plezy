# Agent guidance for this personal Plezy fork

This checkout contains private, owner-specific GalTV work. Treat the repository as private-only unless the owner explicitly approves publishing a particular change.

## Data that must not be committed or published

- Personal email addresses, account identifiers, usernames, phone numbers, or private contact details.
- Private/LAN IP addresses, hostnames, ports, ADB endpoints, device serials, Wi-Fi details, or server paths.
- Tokens, passwords, cookies, signing keys, keystores, certificates, recovery codes, or local configuration files.
- Screenshots, logs, dumps, or sample payloads copied from the owner's real devices or services unless scrubbed first.
- Local machine paths containing a real username or home directory.

Use reserved documentation addresses/domains (for example, `192.0.2.0/24` and `example.invalid`) or clearly fake values in tests. Read secrets from ignored local files or environment variables; never add those files to Git.

## Before committing or pushing

1. Inspect the staged diff, not only the working tree: `git diff --cached`.
2. Run `python scripts/check_staged_privacy.py`; the pre-commit hook runs it automatically once installed with `scripts/setup_hooks.sh`.
3. Do not bypass the hook with `--no-verify` or `SKIP_HOOKS=1` unless the owner explicitly authorizes it.
4. Use the GitHub `noreply` email for new commits. Do not publish personal contact information in commit messages, issues, screenshots, or logs.
5. Never push owner-specific changes to the public Plezy upstream or the archived public fork. `origin` is the owner's private repository; `upstream` is `edde746/plezy`.
6. Never rewrite published history, force-push, delete repositories, or change repository visibility without the owner's explicit approval.

The staged-data check is a safety net, not proof that a change is safe. Review context and binary files manually; scanners cannot identify every credential or piece of personal information.
