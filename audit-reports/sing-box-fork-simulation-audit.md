# sing-box Fork 模拟推演审计报告

## 1. Repository Snapshot

- toplevel: `/Volumes/JC-EXT-DATA-01/sing-box`
- branch: `main`
- head: `97c49afe89b0f7c14897f8d04b67473246f7f15e`
- working tree at audit start: clean
- post-audit working tree: contains generated audit artifacts under `.audit-tmp/`, `tests/audit/`, and `audit-reports/`

Latest 20 commits at audit start:

```text
97c49af (HEAD -> main, origin/main, origin/HEAD) feat: close safe write gaps for helpers and shell aliases
4f83adc docs: document backup rollback and version policy
835ed42 test: cover backup rollback install plan and version policy
3135706 feat: pin and validate stable sing-box version
0d7d43c feat: add backup rollback safe write and remove guards
31487eb Add install plan and dry-run confirmation flow
9e38c19 Stop auto-creating Reality after install
308b52f Run hardening checks before release packaging
05ae673 Harden release downloads
0ca1b0c Remove promotional branding
3cc4748 (tag: v1.16) Merge pull request #121 from fr0der1c/anytls
b1c634a feat: add AnyTLS protocol support
2b97091 Merge pull request #119 from rowanchen-com/main
2199ef6 fix: force install full wget on Alpine to replace BusyBox version
4b18389 fix: wait for background tasks before exit to prevent output overlap
7effde1 Merge pull request #118 from rowanchen-com/main
9d35760 fix: avoid apk lock conflict by running install_pkg synchronously on Alpine
c3512eb Merge pull request #117 from rowanchen-com/main
64528c4 fix: correct Alpine package install error message
735e738 fix: use supervise-daemon for OpenRC to prevent blocking
```

## 2. Executive Summary

- Overall Result: **FAIL, due to P1 backup transaction coverage gaps.**
- Confirmed Safe:
  - Default install control flow does not auto-create Reality or another inbound protocol.
  - Reality / AnyTLS / TUIC manual add support remains present in `src/core.sh`.
  - Default core version resolves to pinned stable `v1.13.8`; `--latest` is explicit and conflicts with `--core-version`.
  - Download helpers enforce HTTPS URL shape and SHA256 verification after download.
  - Backup manifest, rollback dry-run, rollback restore/delete, damaged manifest rejection, missing backup rejection, safe_remove allowlist/denylist, alias marker block, and legacy helper routing were confirmed in a mock root.
  - Release workflow runs hardening, backup rollback, version pin, and no-auto-reality tests before `tar`.
- Main Risks:
  - Multiple production writes/deletes still bypass `safe_*` or backup transaction: core tar extraction, Caddy directory creation, DNS/log config writes, log deletion, import source deletion, startup TLS key generation, `/usr/bin/jq` chmod.
  - `SING_BOX_INSECURE_DOWNLOAD` is a runtime environment opt-in but is not documented in README/runtime help.
  - Release packaging uses `tar zcvf code.tar.gz ./*`, so committed root-level audit artifacts would be included unless excluded.
- Not Proved By Simulation:
  - Real VPS install/update/uninstall behavior.
  - Real service state transitions through `systemctl` / `rc-service`.
  - GitHub Actions success status for the latest HEAD.
  - Availability of GitHub release asset `digest` metadata for every upstream release.
  - `tests/pinned-version-compat.sh` was not run because it performs real GitHub release downloads, which is outside this task boundary.

## 3. Scope and Method

- L1 Static Control Flow:
  - Ran bash parser checks over `install.sh`, `sing-box.sh`, `src/*.sh`, `tests/*.sh`, and `tests/audit/*.sh`.
  - Ran static `rg` / `awk` checks for protocol creation, manual protocol support, download hardening, version policy, workflow order, and dangerous commands.
  - Evidence: `.audit-tmp/static-control-flow.log`, `.audit-tmp/dangerous-commands.raw`, `.audit-tmp/direct-writes.raw`.
- L2 Mock Filesystem:
  - Created isolated mock roots under `.audit-tmp/mock-backup-root.*`.
  - Sourced only `src/backup.sh` plus extracted legacy helper definitions from `src/init.sh`.
  - Verified backup transaction, rollback, safe_remove, alias block, and helper routing without writing real system paths.
  - Evidence: `.audit-tmp/mock-backup-rollback.log`.
- L3 Mock External Commands:
  - Used mock command directory under `.audit-tmp/mock-install-root.*`.
  - Ran `install.sh --dry-run` with fake `apt-get`, `systemctl`, `wget`, `tar`, `jq`, etc.; no mock command was executed.
  - Extracted `execute_install`, `update`, `download`, and `uninstall` blocks for path-level flow audit.
  - Evidence: `.audit-tmp/mock-install-paths.log`, `.audit-tmp/mock-update-uninstall.log`, `.audit-tmp/update-uninstall-risks.tsv`.

### Bash Syntax

- result: PASS
- failing files: none
- evidence: `.audit-tmp/static-control-flow.log`

## 4. Scenario Matrix

| ID | Scenario | Result | Evidence | Notes |
|---|---|---:|---|---|
| S01 | `install.sh --dry-run` | PASS | `.audit-tmp/mock-install-root.*/install-dry-run.out`; `.audit-tmp/mock-install-root.*/mock-commands.log` empty | Plan only; no mocked package/download/service command executed. |
| S02 | Default install control flow | PASS | `install.sh:827-830`; `.audit-tmp/mock-install-root.*/execute_install.block` | `execute_install` creates base `config.json` only; no `add` / `create server`. |
| S03 | Post-install interactive menu | PASS | `install.sh:685-690` | Menu only runs when both stdin and stdout are TTY. |
| S04 | Manual Reality support | PASS | `src/core.sh:21`, `src/core.sh:820`, `src/core.sh:1453-1466` | Manual Reality add path remains. |
| S05 | Manual AnyTLS support | PASS | `src/core.sh:23`, `src/core.sh:841`, `src/core.sh:1467-1478` | Manual AnyTLS add path remains. |
| S06 | Manual TUIC support | PASS | `src/core.sh:4`, `src/core.sh:832`, `src/core.sh:1446-1451` | Manual TUIC add path remains. |
| S07 | Default version pin | PASS | `src/version.sh:3`, `.audit-tmp/version-policy.*/default.err` | Function simulation returned `v1.13.8` and did not call latest resolver. |
| S08 | Explicit latest | PASS | `src/version.sh:46-54`, `.audit-tmp/version-policy.*/latest.err` | `--latest` calls resolver and emits breaking-change warning. |
| S09 | Explicit core version | PASS | `src/version.sh:39-43`, `.audit-tmp/version-policy.*/explicit.err` | `1.13.8` normalized to `v1.13.8`. |
| S10 | latest/version conflict | PASS | `src/version.sh:33-36`, `install.sh:654-656` | Conflict returns error. |
| S11 | HTTPS-only downloads | PASS | `install.sh:223-234`, `src/download.sh:5-32` | Non-HTTPS URLs rejected before `_wget`. |
| S12 | SHA256 verification | PASS | `install.sh:237-250`, `src/download.sh:12-25`, `src/download.sh:154` | Simulation confirms code path; cannot prove all releases provide digest. |
| S13 | Insecure download opt-in | PASS | `install.sh:629-632`, `src/init.sh:115-119` | Explicit flag/env opt-in only; env var documentation gap recorded as P2. |
| S14 | Backup manifest | PASS | `.audit-tmp/mock-backup-rollback.log` | Write/new/delete entries recorded with `existed=true/false`. |
| S15 | Rollback dry-run | PASS | `.audit-tmp/mock-backup-root.*/rollback-dry-run.out` | Dry-run did not change current file content. |
| S16 | Rollback yes | PASS | `.audit-tmp/mock-backup-root.*/rollback-run.out` | Restored old files and deleted `existed=false` file. |
| S17 | Rollback damaged manifest | PASS | `.audit-tmp/mock-backup-root.*/rollback-bad-manifest.out` | Damaged manifest rejected before apply. |
| S18 | Rollback missing backup | PASS | `.audit-tmp/mock-backup-root.*/rollback-missing.out` | Missing backup rejected before partial restore. |
| S19 | safe_remove denylist | PASS | `.audit-tmp/mock-backup-rollback.log` | Empty, relative, broad, backup, and unmanaged paths rejected. |
| S20 | safe_remove allowlist | PASS | `.audit-tmp/mock-backup-rollback.log` | Managed paths removed and manifest-recorded. |
| S21 | Alias block write | PASS | `.audit-tmp/mock-backup-rollback.log` | Marker block idempotent, external content preserved. |
| S22 | Alias block remove | PASS | `.audit-tmp/mock-backup-rollback.log` | Only marker block removed. |
| S23 | Alias rollback | PASS | `.audit-tmp/mock-backup-root.*/rollback-alias.out` | Rollback restored pre-alias state. |
| S24 | Legacy helpers | PASS | `.audit-tmp/mock-backup-root.*/legacy-rm.out`; `src/init.sh:34-94` | `_rm/_cp/_sed/_mkdir` route to safe wrappers and reject unsafe path. |
| S25 | Uninstall | UNCERTAIN | `src/core.sh:683-724`; `.audit-tmp/mock-update-root.*/uninstall.block` | Static path checks pass, but full interactive uninstall was not function-executed under mock. |
| S26 | Update core | FAIL | `src/download.sh:110-112`; `.audit-tmp/update-uninstall-risks.tsv` | Core tar extracts directly into production bin after backing up only expected binary. |
| S27 | Update sh | PASS | `src/download.sh:125-127` | Script dir is backed up before tar extraction. |
| S28 | Update caddy | PASS | `src/download.sh:136-142` | Extracts to tmp, then `safe_copy_file` and `safe_chmod_path`. |
| S29 | Release workflow | PASS | `.github/workflows/release.yml:25-34` | Required tests run before tar; broad tar range recorded separately as P2. |
| S30 | CI status | UNCERTAIN | `.github/workflows/release.yml` | Workflow is defined; this audit did not query GitHub Actions status for HEAD. |

## 5. Findings

### P0 Findings

None found.

### P1 Findings

#### P1-1: Core tar extraction can write unmanifested production files

- File/path: `src/download.sh:110-112`, `install.sh:793-795`
- Trigger condition: `sb update core` or default install downloads a core tarball.
- Impact: Only `$is_core_bin` is backed up before `tar zxf ... -C "$is_core_dir/bin"`. If a future archive contains extra files, those files can be written into production without manifest entries and rollback cannot reliably remove or restore them.
- Risk: P1
- Suggested fix: Extract into a temp directory, validate expected single binary, then `safe_copy_file "$tmpdir/sing-box" "$is_core_bin"` and `safe_chmod_path +x "$is_core_bin"`.

#### P1-2: Caddy production directories bypass safe_ensure_dir

- File/path: `src/core.sh:376`, `src/caddy.sh:5`
- Trigger condition: Creating Caddy config for TLS-backed protocols or `caddy_config new`.
- Impact: `$is_caddy_conf`, `$is_caddy_dir`, and `$is_caddy_dir/sites` can be created without manifest entries. Rollback cannot prove or reverse those directory creations.
- Risk: P1
- Suggested fix: Replace raw `mkdir -p` with `safe_ensure_dir` for each managed directory inside the active transaction.

#### P1-3: DNS and log settings overwrite config.json outside backup transaction

- File/path: `src/dns.sh:54`, `src/dns.sh:58`, `src/dns.sh:60`, `src/log.sh:27`, `src/log.sh:30`
- Trigger condition: `sb dns ...`, `sb log none`, or `sb log <level>`.
- Impact: `$is_config_json` is overwritten with shell redirection instead of `safe_write_file`; `src/core.sh` dispatches `dns` and `log` without `run_with_backup_transaction`.
- Risk: P1
- Suggested fix: Wrap `dns_set` and mutating `log_set` paths in backup transactions and write config via `safe_write_file` or a temp file plus `safe_move_file`.

#### P1-4: Log deletion bypasses safe_remove_path

- File/path: `src/log.sh:22`, `src/log.sh:26`
- Trigger condition: `sb log del` or `sb log none`.
- Impact: `$is_log_dir/*.log` is removed via raw `rm -rf`; no manifest entries are created.
- Risk: P1
- Suggested fix: Enumerate matched log files and call `safe_remove_path` on each allowed managed log path, or explicitly define log deletion as non-rollbackable and document it.

#### P1-5: Import deletes source configs outside managed allowlist

- File/path: `src/import.sh:50`
- Trigger condition: Importing compatible `/etc/xray/conf/*.json` or `/etc/v2ray/conf/*.json`.
- Impact: Source config is deleted with raw `rm $1`; this is cross-service production data and not covered by sing-box backup manifest.
- Risk: P1
- Suggested fix: Do not delete source configs by default. If deletion remains a feature, require explicit confirmation and implement a separate backup/manifest path for imported source files.

#### P1-6: Startup TLS key generation writes production files outside transaction

- File/path: `src/init.sh:174-177`
- Trigger condition: Any runtime invocation when `$is_tls_cer` or `$is_tls_key` is missing.
- Impact: `$is_core_dir/bin/tls.tmp`, `tls.key`, and `tls.cer` are written or removed without backup transaction.
- Risk: P1
- Suggested fix: Move key generation behind a managed function that runs inside `run_with_backup_transaction`, writes temp files under a temp dir, and commits with `safe_write_file` / `safe_move_file`.

#### P1-7: `/usr/bin/jq` chmod is raw and not TEST_ROOT mappable

- File/path: `install.sh:805`, `install.sh:809`
- Trigger condition: Install path where jq is missing and script downloads jq.
- Impact: `safe_copy_file "$is_jq_ok" /usr/bin/jq` backs up the target, but `chmod +x /usr/bin/jq` bypasses `safe_chmod_path` and hard-codes a real system path that the mock root cannot map.
- Risk: P1
- Suggested fix: Introduce an `is_jq_bin` variable, map it in tests, use `safe_copy_file "$is_jq_ok" "$is_jq_bin"` and `safe_chmod_path +x "$is_jq_bin"`.

### P2 Findings

#### P2-1: `SING_BOX_INSECURE_DOWNLOAD` is not documented

- File/path: `src/init.sh:118`, `README.md`, `src/help.sh`
- Trigger condition: User runs runtime update with `SING_BOX_INSECURE_DOWNLOAD=1`.
- Impact: TLS verification can be disabled without a CLI warning path; SHA256 still runs, but operator-facing docs do not describe the env var.
- Risk: P2
- Suggested fix: Add runtime help/README text describing the env var, intended emergency-only use, and SHA256 behavior.

#### P2-2: Release tar command packages every root path

- File/path: `.github/workflows/release.yml:33-34`
- Trigger condition: Release workflow after audit scripts/reports are committed or other root-level artifacts exist.
- Impact: `tar zcvf code.tar.gz ./*` includes root-level directories such as `audit-reports/` and any other committed artifacts unless explicitly excluded.
- Risk: P2
- Suggested fix: Package an explicit allowlist of release files or add tar exclusions for audit/dev artifacts.

#### P2-3: CI status for HEAD was not verified

- File/path: `.github/workflows/release.yml`
- Trigger condition: Need to assert latest HEAD has a successful Actions run.
- Impact: This local simulation confirms workflow definition and ordering, not remote CI success.
- Risk: P2
- Suggested fix: Query GitHub Actions checks for `97c49afe89b0f7c14897f8d04b67473246f7f15e` in a separate network-enabled review.

#### P2-4: Full uninstall was not executed under mock

- File/path: `src/core.sh:683-724`
- Trigger condition: `sb uninstall` interactive path.
- Impact: Static block confirms `backup_standard_managed_paths`, `safe_remove_path`, and `safe_remove_shell_aliases`, but the full function was not executed because sourcing runtime init has side effects and service/process probes.
- Risk: P2
- Suggested fix: Add a source-safe test harness or split uninstall planning/removal functions so they can be executed against `TEST_ROOT`.

#### P2-5: BBR edits `/etc/sysctl.conf` outside backup transaction

- File/path: `src/bbr.sh:2-5`
- Trigger condition: `sb bbr`.
- Impact: System-level config is modified directly with `sed -i` and append redirection. This is outside the sing-box managed-file scope, but it is still a production system file.
- Risk: P2
- Suggested fix: Either document BBR as intentionally out-of-scope for rollback, or add a dedicated backup path for `/etc/sysctl.conf`.

### P3 Findings

None.

## 6. Boundary Coverage

- Default install:
  - Confirmed by static control flow and dry-run mock. Default path creates only base `config.json`; no protocol inbound is created.
- Manual protocol add:
  - Reality, AnyTLS, and TUIC are present in protocol enum, command aliases, and protocol-specific config handling.
- Version policy:
  - Confirmed by function-level simulation. Default is `DEFAULT_SING_BOX_STABLE_VERSION` (`v1.13.8`), latest resolver only runs with `--latest`, and explicit versions normalize with `v` prefix.
- Download hardening:
  - HTTPS-only and SHA256 checks are present. Simulation cannot prove every release has a digest field.
- Backup / rollback:
  - Confirmed in mock root for write, create, delete, dry-run, apply, pre-rollback, missing backup, and damaged manifest.
- Alias management:
  - Confirmed marker block write/update/remove/rollback. No broad `/root/.bashrc` sed/delete found.
- Uninstall:
  - Static block passes key safe wrapper checks. Full interactive function execution remains unproved by L3.
- Update:
  - Core update has P1 tar extraction risk. Script and Caddy update paths are better bounded.
- Release workflow:
  - Required tests run before tar. Remote CI status is unverified.

## 7. Dangerous Command Classification

| File | Line | Command | Classification | Reason |
|---|---:|---|---|---|
| `install.sh` | 82 | `trap 'rm -rf "$tmpdir"'` | TEMP_ONLY | Removes installer temp dir. |
| `install.sh` | 162 | `mkdir -p "$support_dir"` | TEMP_ONLY | Extract support script into temp install support dir. |
| `install.sh` | 664 | `rm -rf "$tmpdir"` | TEMP_ONLY | Installer temp cleanup. |
| `install.sh` | 699 | `mkdir -p "$tmpdir"` | TEMP_ONLY | Planned temp dir creation. |
| `install.sh` | 702 | `cp -f "$is_core_file" "$is_core_ok"` | TEMP_ONLY | Copies local archive into temp staging. |
| `install.sh` | 756 | `mkdir -p "$tmpdir/testzip"` | TEMP_ONLY | Local core archive validation extraction dir. |
| `install.sh` | 793-795 | `backup_path_before_write "$is_core_bin"; tar ... -C "$is_core_dir/bin"` | PRODUCTION_RISK | Only expected binary is manifest-backed; archive can write extra files. |
| `install.sh` | 809 | `chmod +x /usr/bin/jq` | PRODUCTION_RISK | Raw chmod on hard-coded production path. |
| `src/download.sh` | 110-112 | `backup_path_before_write "$is_core_bin"; tar ... -C "$is_core_dir/bin"` | PRODUCTION_RISK | Same core update extraction risk. |
| `src/download.sh` | 113,138,145,151 | `rm -rf "$tmpdir"` | TEMP_ONLY | Download temp cleanup. |
| `src/download.sh` | 125-127 | `backup_path_before_write "$is_sh_dir"; tar ...; safe_chmod_path` | PRODUCTION_SAFE | Script dir is backed up as a directory before extraction. |
| `src/download.sh` | 136-142 | `tar ... -C "$tmpdir"; safe_copy_file; safe_chmod_path` | PRODUCTION_SAFE | Caddy extracts to temp, then safe copy/chmod to production. |
| `src/core.sh` | 376 | `mkdir -p $is_caddy_conf` | PRODUCTION_RISK | Production Caddy dir creation bypasses manifest. |
| `src/core.sh` | 593-606 | `cp -f`, `sed -i`, `rm -f` on `$is_tmp_json` | TEMP_ONLY | Reality key validation temp file. |
| `src/core.sh` | 683-724 | uninstall safe removal plus `rmdir` | PRODUCTION_SAFE | Uses `safe_remove_path`/`safe_remove_shell_aliases`; `rmdir` only removes empty dirs. Full runtime unproved. |
| `src/core.sh` | 1076-1085 | temp JSON write/check/remove | TEMP_ONLY | Shadowsocks 2022 validation temp file. |
| `src/caddy.sh` | 5 | `mkdir -p $is_caddy_dir $is_caddy_dir/sites $is_caddy_conf` | PRODUCTION_RISK | Production directories bypass safe wrapper. |
| `src/dns.sh` | 54,58,60 | `cat <<<$(jq ...) >$is_config_json` | PRODUCTION_RISK | Direct overwrite of managed config without transaction. |
| `src/log.sh` | 22,26 | `rm -rf $is_log_dir/*.log` | PRODUCTION_RISK | Managed log deletion bypasses safe remove/manifest. |
| `src/log.sh` | 27,30 | `cat <<<$(jq ...) >$is_config_json` | PRODUCTION_RISK | Direct config overwrite outside transaction. |
| `src/import.sh` | 50 | `rm $1` | PRODUCTION_RISK | Deletes xray/v2ray source config outside sing-box allowlist. |
| `src/init.sh` | 174-177 | TLS tmp/key/cert redirection and `rm` | PRODUCTION_RISK | Writes/removes files under core bin outside transaction. |
| `src/bbr.sh` | 2-5 | `sed -i` and append to `/etc/sysctl.conf` | PRODUCTION_RISK | System config modification outside rollback scope. |
| `src/backup.sh` | 164-620 | `mkdir`, `cp`, `mv`, `rm`, `ln`, `chmod` inside safe wrappers | SAFE_WRAPPER | Implements transaction primitives. |
| `src/backup.sh` | 731-799 | rollback apply `rm/cp/mkdir` | SAFE_WRAPPER | Rollback engine after manifest validation and preflight. |
| `tests/*.sh` | multiple | `mktemp`, `rm`, `mkdir`, temp writes | TEMP_ONLY | Test harnesses operate on temp/mock roots. |
| `tests/audit/*.sh` | multiple | `mkdir`, `rm`, temp writes | TEMP_ONLY | Audit harnesses operate under `.audit-tmp/`. |
| `.github/workflows/release.yml` | 34 | `tar zcvf code.tar.gz ./*` | PRODUCTION_RISK | Packaging range is broad; can include committed audit/dev artifacts. |

Full raw hits: `.audit-tmp/dangerous-commands.raw` and `.audit-tmp/direct-writes.raw`.

## 8. Simulation Limitations

- What this audit can prove:
  - Bash parser accepts all checked shell scripts.
  - The inspected default install control flow does not call protocol add/create server paths.
  - Function-level version policy behaves as intended.
  - `src/backup.sh` primitives behave correctly in an isolated mock root for the tested write/remove/rollback/alias/helper scenarios.
  - `install.sh --dry-run` does not execute mocked external commands in the simulated Debian/systemd environment.
- What this audit cannot prove:
  - Real VPS install/update/uninstall success.
  - Service manager behavior on real systemd/OpenRC hosts.
  - Real GitHub release digest availability and asset contents.
  - Real upstream compatibility for pinned core because `tests/pinned-version-compat.sh` was intentionally not run.
  - Remote GitHub Actions pass/fail state for current HEAD.

## 9. Recommended Next Actions

1. Fix P1 backup transaction gaps before treating rollback coverage as production-complete.
2. Change core install/update to extract archives into temp and safe-copy only the validated `sing-box` binary.
3. Replace Caddy raw `mkdir -p` calls with `safe_ensure_dir`.
4. Route `dns_set` and mutating `log_set` paths through `run_with_backup_transaction` and `safe_write_file`.
5. Decide whether import source deletion and BBR sysctl edits are intentionally outside rollback; document or back them up.
6. Replace `/usr/bin/jq` hard-code with a variable and safe chmod.
7. Add release tar allowlist/exclusions before committing audit artifacts.
8. In a separate network-enabled review, verify GitHub Actions status and, if desired, run `tests/pinned-version-compat.sh`.
