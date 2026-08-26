# Security Policy

## Supported versions

Cortex is currently developed from its latest public `main` branch. Security
fixes are applied there; older snapshots are not maintained as supported
release lines.

## Reporting a vulnerability

Please do not disclose vulnerabilities, credential exposure, or private-data
leaks in a public issue. Use GitHub's private vulnerability-reporting form for
this repository when it is available. If private reporting is unavailable,
open a minimal issue asking the maintainer for a private contact channel and
do not include sensitive details.

Include the affected commit, operating system, configuration, reproduction
steps, impact, and any suggested mitigation when it is safe to do so. Do not
include live credentials, private messages, host details, or user/project data
in the report.

## Security model

Cortex coordinates provider CLIs and may be configured to access local files,
remote hosts, messaging systems, credentials, and write-capable agent roles.
It is an operator-controlled framework, not a hostile multi-tenant isolation
boundary. A role's instructions and sandbox reduce accidental scope, but they
do not make elevated provider or worker access harmless.

Before enabling unattended or elevated operation:

- use the narrowest role and permission level that can perform the work
- keep credentials in the private secrets locations documented by Cortex
- keep user, environment, project, inbox, log, and runtime state out of public
  Git history
- configure backups and version control for important work
- publish only through `scripts/sync_public.sh`, never by pushing the live
  operational branch
- review third-party provider, messaging, and remote-host permissions

If you discover that private data or a credential has entered public Git
history, treat the value as compromised, rotate or revoke it immediately, and
report the exposure privately.
