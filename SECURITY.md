# Security policy

## Supported versions

Only the newest image is supported: `latest` and the newest release tag.
Older release tags are not updated. The image is rebuilt every 3 days
with the current Alpine packages.

## Reporting a vulnerability

Please don't open a public issue. Report it privately via
**Security → Report a vulnerability** in this repository.

## Scope

In scope: the Dockerfile, run.sh, the default configuration and the
GitHub workflows of this repository.

Vulnerabilities in Postfix or Alpine itself should be reported upstream
(https://www.postfix.org/, https://security.alpinelinux.org/). Their fixes
reach this image with the next rebuild.
