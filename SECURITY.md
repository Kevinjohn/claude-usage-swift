# Security Policy

## Reporting a Vulnerability

This app accesses macOS Keychain credentials, so security matters.

If you discover a security vulnerability, please **do not** open a public issue. Instead, email **security [at] KevinjohnGallagher.com**.

You should receive a response within a few days. Please include:

- A description of the vulnerability
- Steps to reproduce
- Potential impact

## Scope

This policy covers:

- Credential handling (Keychain access, token usage)
- Network requests (API communication)
- Local data storage (UserDefaults, snapshots)

## Supported Versions

| Version | Supported |
|---------|-----------|
| Latest  | Yes       |
| Older   | No        |

Only the latest release receives security fixes.
