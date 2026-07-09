# Security Policy

## Reporting a vulnerability

Please report security issues privately instead of opening a public issue.

Use GitHub's private vulnerability reporting if it is enabled for this
repository. If it is not enabled, contact the maintainer directly through the
GitHub profile associated with this repository.

## Scope

Portraiture launches external commands and scripts supplied by the caller. It is
not a sandbox and should not be used to execute untrusted code without a separate
sandboxing layer.

Security reports are especially welcome for:

- command or argument escaping bugs
- timeout cleanup that leaks child processes
- unsafe default interpreter behavior
- accidental exposure of captured secrets in logs or errors
- dependency or packaging vulnerabilities
