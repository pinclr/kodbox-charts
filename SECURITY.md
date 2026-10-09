# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub:
**Security → Report a vulnerability** on
[pinclr/kodbox-charts](https://github.com/pinclr/kodbox-charts/security/advisories/new).
Don't open a public issue. We aim to reply within a week.

Include the chart version, the values you used (without secrets) and what an
attacker could do.

## Scope

- **In scope:** the chart's templates and defaults: RBAC, network policies,
  security contexts, secret handling, exposed services.
- **Upstream images:** vulnerabilities inside kodbox, kodoffice, MariaDB,
  Redis, ONLYOFFICE, Milvus, etcd, RustFS or Imaginary belong to those
  projects. Tell us anyway if a newer image fixes them and the chart should
  move to it; every pull request scans the chart's images with Trivy.

## Supported versions

Fixes go into the latest chart release. Upgrade to it rather than expecting
backports.

## Verifying releases

Chart packages are signed with GPG (`signing-key.asc`, fingerprint
`A0789F533FF3502789281476AA27ACFF8DC3E405`) and, on GHCR, with cosign. See the
README for the verification commands.
