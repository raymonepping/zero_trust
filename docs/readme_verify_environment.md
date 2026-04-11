# verify_environment.sh

Wrapper script that orchestrates all verification scripts for the Zero Trust Workshop environment. Executes verification scripts in logical order and provides a comprehensive summary of the environment health.

---

## Table of Contents

- [Overview](#overview)
- [Usage](#usage)
- [Options](#options)
- [Verification Order](#verification-order)
- [Output Formats](#output-formats)
- [Exit Codes](#exit-codes)
- [Examples](#examples)
- [Integration](#integration)

---

## Overview

The `verify_environment.sh` script is a comprehensive wrapper that:

- Executes all verification scripts in the correct dependency order
- Resolves `--runtime auto` before invoking child verifiers
- Provides progress tracking with timing information
- Aggregates results into a unified summary
- Supports human-readable, JSON, and compact table report output formats
- Allows selective skipping of specific verifications
- Handles errors gracefully with configurable stop-on-error behavior

This script is designed to be the single entry point for validating the entire workshop environment before starting labs or after making configuration changes.

---

## Usage

```bash
./scripts/verify_environment.sh [OPTIONS]
```

### Basic Usage

Run all verifications with default settings:

```bash
./scripts/verify_environment.sh
```

### With Runtime Specification

Explicitly specify the container runtime:

```bash
./scripts/verify_environment.sh --runtime docker
./scripts/verify_environment.sh --runtime podman
```

### Verbose Mode

Show detailed output from each verification script:

```bash
./scripts/verify_environment.sh --verbose
```

### JSON Output

Generate machine-readable JSON summary:

```bash
./scripts/verify_environment.sh --json
./scripts/verify_environment.sh --json > environment_status.json
```

### Report Output

Generate a compact terminal report with one row per verifier:

```bash
./scripts/verify_environment.sh --report
./scripts/verify_environment.sh --report --runtime podman
```

---

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--runtime <docker\|podman\|auto>` | Specify container runtime to verify | `auto` |
| `--skip <service>` | Skip specific verification(s), comma-separated | None |
| `--stop-on-error` | Stop at first failure instead of continuing | `false` |
| `--verbose` | Show detailed output from each script | `false` |
| `--quiet` | Only show summary (no progress indicators) | `false` |
| `--json` | Output machine-readable JSON summary (implies --quiet) | `false` |
| `--report` | Output compact table report (implies --quiet) | `false` |
| `--help` | Display usage information | N/A |

### Valid Service Names for --skip

- `runtime` - Alias for `container_runtime`
- `container_runtime` - Container runtime verification
- `postgresql` - PostgreSQL database verification
- `ldap` - OpenLDAP directory verification
- `keycloak` - Keycloak identity provider verification
- `vault` - HashiCorp Vault verification

### Runtime Resolution

When `--runtime auto` is used, the wrapper resolves the runtime before calling child scripts:

1. If `CONTAINER_RUNTIME` is set to `docker` or `podman`, that value is used
2. Otherwise it prefers a reachable Podman daemon
3. Then it falls back to a reachable Docker daemon
4. If neither daemon is reachable, it falls back to whichever CLI is installed

If auto-detection is not what you want, pass `--runtime docker` or `--runtime podman` explicitly.

---

## Verification Order

The script executes verifications in this logical order:

1. **Container Runtime** (`verify_container_runtime.sh`)
   - Must pass first as it validates the foundation
   - Checks Docker/Podman installation, daemon, compose, networking

2. **PostgreSQL** (`verify_postgresql.sh`)
   - Database layer verification
   - Checks volume, container, connectivity, tables, RLS policies

3. **LDAP** (`verify_ldap.sh`)
   - Identity directory verification
   - Checks container, directory structure, users, groups

4. **Keycloak** (`verify_keycloak.sh`)
   - Identity provider verification
   - Depends on LDAP for user federation
   - Checks container, reachability, admin access

5. **Vault** (`verify_vault.sh`)
   - Secrets management verification
   - Checks container, seal status, mounts, auth methods

This order ensures that dependencies are validated before dependent services.

If `--stop-on-error` is set, execution stops after the first failed verification and the summary reflects only the checks that ran.

---

## Output Formats

### Human-Readable Output (Default)

```
╔══════════════════════════════════════════════════════════════╗
║  Zero Trust Workshop - Environment Verification              ║
╚══════════════════════════════════════════════════════════════╝

[1/5] Verifying Container Runtime...                      ✔ PASS (2.3s)
[2/5] Verifying PostgreSQL...                             ✔ PASS (1.8s)
[3/5] Verifying LDAP...                                   ✔ PASS (1.2s)
[4/5] Verifying Keycloak...                               ⚠ WARN (3.1s)
[5/5] Verifying Vault...                                  ✔ PASS (2.5s)

╔══════════════════════════════════════════════════════════════╗
║  VERIFICATION SUMMARY                                        ║
╠══════════════════════════════════════════════════════════════╣
║  Container Runtime    ✔ PASS                                 ║
║  PostgreSQL          ✔ PASS                                 ║
║  LDAP                ✔ PASS                                 ║
║  Keycloak            ⚠ WARN  (warnings detected)            ║
║  Vault               ✔ PASS                                 ║
╠══════════════════════════════════════════════════════════════╣
║  Overall Status: READY WITH WARNINGS                         ║
║  Health Score: 90% (4/5 passed, 1 warning(s), 0 failed)     ║
║  Total Time: 11.0s                                           ║
╚══════════════════════════════════════════════════════════════╝

⚠ Warnings detected. Review output above for details.
```

Warnings are derived from child-script lines containing `WARN`, while failures are based on non-zero exit codes.

### JSON Output

```json
{
  "timestamp": "2026-04-11T12:00:00Z",
  "runtime": "docker",
  "total_time_seconds": 11,
  "overall_status": "ready_with_warnings",
  "health_score": 90,
  "verifications": [
    {
      "name": "container_runtime",
      "status": "pass",
      "duration_seconds": 2,
      "exit_code": 0,
      "warnings": []
    },
    {
      "name": "postgresql",
      "status": "pass",
      "duration_seconds": 1,
      "exit_code": 0,
      "warnings": []
    },
    {
      "name": "ldap",
      "status": "pass",
      "duration_seconds": 1,
      "exit_code": 0,
      "warnings": []
    },
    {
      "name": "keycloak",
      "status": "warn",
      "duration_seconds": 3,
      "exit_code": 0,
      "warnings": ["setup may be incomplete"]
    },
    {
      "name": "vault",
      "status": "pass",
      "duration_seconds": 2,
      "exit_code": 0,
      "warnings": []
    }
  ],
  "summary": {
    "total_checks": 5,
    "passed": 4,
    "warnings": 1,
    "failed": 0
  }
}
```

`runtime` in JSON is the resolved runtime actually passed to child scripts, not the literal CLI argument.

### Report Output

`--report` prints only the final table report and suppresses the progress and child-script output.

```text
Environment Verification Report
Runtime: podman
Overall: READY
Health : 100%
Time   : 23.0s

Service              Status   Duration   Exit   Warnings
-------------------- -------- ---------- ------ --------
Container Runtime    PASS     19.0s      0      0
PostgreSQL           PASS     1.0s       0      0
LDAP                 PASS     0.0s       0      0
Keycloak             PASS     1.0s       0      0
Vault                PASS     1.0s       0      0

Checks: 5 total, 5 passed, 0 warnings, 0 failed
```

### Status Values

- **pass** - Verification completed successfully with no warnings
- **warn** - Verification completed but warnings were detected
- **fail** - Verification failed (non-zero exit code)
- **skip** - Verification was skipped via `--skip` option

### Overall Status Values

- **ready** - All verifications passed
- **ready_with_warnings** - All verifications passed but some have warnings
- **failed** - One or more verifications failed

### Health Score Calculation

```
health_score = (passed * 100 + warnings * 50) / total_checks
```

- Passed verifications contribute 100% to the score
- Warnings contribute 50% to the score
- Failed verifications contribute 0% to the score

---

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | No verification failed |
| `1` | One or more verifications failed |
| `2` | Invalid arguments or missing dependencies |

---

## Examples

### Basic Verification

Run all verifications with default settings:

```bash
./scripts/verify_environment.sh
```

### Specify Runtime

Explicitly use Docker:

```bash
./scripts/verify_environment.sh --runtime docker
```

### Skip Services

Skip Vault and Keycloak verifications:

```bash
./scripts/verify_environment.sh --skip vault,keycloak
```

Skip container runtime verification:

```bash
./scripts/verify_environment.sh --skip runtime
./scripts/verify_environment.sh --skip container_runtime
```

### Verbose Output

Show detailed output from each verification script:

```bash
./scripts/verify_environment.sh --verbose
```

### Stop on First Error

Stop execution at the first failed verification:

```bash
./scripts/verify_environment.sh --stop-on-error
```

### JSON Output to File

Generate JSON report and save to file (--json automatically enables quiet mode):

```bash
./scripts/verify_environment.sh --json > environment_status.json
```

### Compact Terminal Report

Show only the final table report:

```bash
./scripts/verify_environment.sh --report
```

### Combined Options

Verbose mode with Podman runtime, skipping Vault:

```bash
./scripts/verify_environment.sh --runtime podman --verbose --skip vault
```

Stop on first error with Docker runtime:

```bash
./scripts/verify_environment.sh --runtime docker --stop-on-error
```

Auto-detect runtime and skip the container runtime verifier itself:

```bash
./scripts/verify_environment.sh --skip runtime
```

---

## Integration

### CI/CD Pipeline Integration

Use the JSON output for automated testing:

```bash
#!/bin/bash
./scripts/verify_environment.sh --json > status.json

# Check if any verifications failed
if jq -e '.summary.failed > 0' status.json > /dev/null; then
  echo "Environment verification failed"
  exit 1
fi

# Check health score
health_score=$(jq -r '.health_score' status.json)
if [ "$health_score" -lt 80 ]; then
  echo "Health score too low: $health_score%"
  exit 1
fi

echo "Environment verification passed"
```

### Pre-Lab Checklist

Add to workshop startup documentation:

```bash
# Verify environment before starting labs
./scripts/verify_environment.sh

# If all checks pass, proceed with labs
# If warnings appear, review and decide if acceptable
# If failures occur, fix issues before proceeding
```

### Monitoring Integration

Periodic health checks:

```bash
# Run every 5 minutes
*/5 * * * * cd /path/to/zero_trust && ./scripts/verify_environment.sh --json > /var/log/workshop/health.json
```

### Troubleshooting Workflow

```bash
# 1. Run full verification
./scripts/verify_environment.sh --verbose

# 2. If specific service fails, run individual verification
./scripts/verify_vault.sh --runtime docker

# 3. Fix issues and re-verify
./scripts/verify_environment.sh
```

---

## Relationship to Other Scripts

The `verify_environment.sh` script orchestrates these individual verification scripts:

- [`verify_container_runtime.sh`](./readme_verify_container_runtime.md) - Container runtime health
- [`verify_postgresql.sh`](./readme_verify_postgresql.md) - Database verification
- [`verify_ldap.sh`](./readme_verify_ldap.md) - LDAP directory verification
- [`verify_keycloak.sh`](./readme_verify_keycloak.md) - Keycloak verification
- [`verify_vault.sh`](./readme_verify_vault.md) - Vault verification

Each individual script can still be run independently for focused troubleshooting.

---

## Best Practices

### When to Use

- **Before starting workshop labs** - Ensure environment is ready
- **After configuration changes** - Verify changes didn't break anything
- **During troubleshooting** - Identify which components have issues
- **In CI/CD pipelines** - Automated environment validation
- **After system updates** - Confirm compatibility

### Recommended Workflow

1. Start with basic verification:
   ```bash
   ./scripts/verify_environment.sh
   ```

2. If issues found, use verbose mode:
   ```bash
   ./scripts/verify_environment.sh --verbose
   ```

3. For specific issues, run individual verification scripts:
   ```bash
   ./scripts/verify_vault.sh
   ```

4. After fixes, re-verify:
   ```bash
   ./scripts/verify_environment.sh
   ```

### Performance Considerations

- **Parallel execution not supported** - Scripts run sequentially for dependency management
- **Average runtime** - 10-15 seconds for all verifications
- **Network-dependent** - Some checks require network connectivity
- **Container-dependent** - All containers must be running

---

## Troubleshooting

### Script Not Found Errors

If individual verification scripts are not found:

```bash
# Ensure you're in the repository root
cd /path/to/zero_trust

# Verify scripts exist
ls -la scripts/verify_*.sh

# Make scripts executable
chmod +x scripts/verify_*.sh
```

### Permission Denied

```bash
# Make the wrapper script executable
chmod +x scripts/verify_environment.sh
```

### Runtime Selection Issues

If auto-detection chooses the wrong runtime or neither daemon is reachable, explicitly specify the runtime:

```bash
./scripts/verify_environment.sh --runtime docker
./scripts/verify_environment.sh --runtime podman
```

### Incomplete Output

If output is truncated, ensure terminal supports ANSI colors or use `--json`:

```bash
./scripts/verify_environment.sh --json
```

---

## Future Enhancements

Potential improvements for future versions:

- Parallel execution of independent verifications
- Configurable timeout per verification
- Email/Slack notifications for failures
- Historical trend tracking
- Automatic remediation suggestions
- Integration with monitoring systems (Prometheus, Grafana)
- Support for custom verification scripts

---

## See Also

- [Main README](../README.md) - Workshop overview
- [Verification Stack Guide](./readme_verify_stack.md) - Verification workflow
- [Environment Settings](./readme_environment_settings.md) - Configuration reference
- [Docker Guide](./readme_docker.md) - Docker setup and operations
- [Podman Guide](./readme_podman.md) - Podman setup and operations
