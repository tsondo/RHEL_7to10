# CLAUDE.md

Repo purpose: migrate RHEL 7 VMs to RHEL 10 replacements (deployed from an
OVA template) that reuse the same hostname/IP. Two-script model:
`scripts/collect_migration.sh` runs on the old RHEL 7 host,
`scripts/restore_migration.sh` runs on the new RHEL 10 host. See README.md
for the operator workflow.

## Environment context

- DoD environment: STIG-hardened, FIPS-enabled RHEL 10 targets.
  vSphere/vCenter virtualization.
- First use case: UC suite SFTP/syslog servers — CUCM DRS backup targets
  and router syslog receivers (syslog must be TLS over TCP, typically 6514).
- CUCM DRS caches the SFTP server's SSH host key fingerprint. Preserving
  `/etc/ssh/ssh_host_*` across the migration is intentional and critical —
  never "clean up" or regenerate host keys in these scripts.

## Hard rules

- `collect_migration.sh` must remain **RHEL 7 / bash 4.2 compatible**:
  no `${var@Q}`, no `readarray -d`, no associative-array niceties beyond
  bash 4.2, no GNU coreutils flags newer than RHEL 7 ships. `rsync` may be
  absent — keep the `cp -a --parents` fallback.
- `restore_migration.sh` targets RHEL 10 only.
- Restore must **never install** the old `sshd_config`, `rsyslog.conf`,
  or `rsyslog.d` — always stage them in the review dir. The RHEL 10
  template's hardened configs and crypto policy are authoritative.
- Never suggest or script `update-crypto-policies --set LEGACY`
  (STIG finding). Scoped subpolicies only, and only as an operator
  decision, not automated.
- Every mutating command in restore goes through the `run` wrapper so
  `-n` (dry-run) stays truthful. If you add a step, wire it through
  `run` and add it to the `-s` skip list, the usage header, and README.
- The archive contains private keys and password hashes: keep archive
  perms 600, never print key material or shadow hashes to stdout, never
  add steps that copy them anywhere unencrypted.
- Preserve SELinux correctness: `restorecon` after placing files;
  `install -D` with explicit modes for anything sensitive.

## Conventions

- `set -euo pipefail` in every script; `getopts` (no GNU long options).
- 4-space indent; functions lowercase_with_underscores.
- Idempotence: restore steps must be safe to re-run (`cp -an` where
  clobbering would be wrong, `id`/`getent` checks before create).
- Keep the two scripts self-contained single files — no sourcing shared
  libs, so they can be scp'd around individually.

## Validation

- `bash -n scripts/*.sh` must pass.
- Run `shellcheck` on both scripts; justify any suppressions inline with
  `# shellcheck disable=SCxxxx` and a reason.
- Test restore changes with `-n` against a sample archive before claiming
  they work. A sample archive can be faked: build a `files/` + `info/`
  tree matching collect's layout and tar it.

## Roadmap / known gaps

- Per-role collection profiles (e.g. `-p syslog`, `-p web`) if non-UC
  hosts need different path sets; today extras are handled via `-a`.
- Optional data sync helper (rsync of DRS/backup trees) — deliberately
  out of scope for restore itself.
- Drop-in templates for the manual config step now live in `templates/`
  (sshd sftp, rsyslog ossl TLS input, scoped legacy-KEX subpolicy),
  generated from the first reviewed UC host. Keep them in sync as more
  host configs are reviewed; they are reference-only and never installed
  by restore.
