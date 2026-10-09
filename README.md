# kodbox-charts

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/kodbox)](https://artifacthub.io/packages/search?repo=kodbox)

Helm charts for [kodbox](https://github.com/kalcaddle/kodbox).

```bash
helm repo add kodbox https://pinclr.github.io/kodbox-charts
helm install kodbox kodbox/kodbox -n kodbox --create-namespace

# or from the OCI registry
helm install kodbox oci://ghcr.io/pinclr/charts/kodbox -n kodbox --create-namespace
```

| Chart | Description |
|---|---|
| [kodbox](charts/kodbox) | kodbox with MariaDB, Redis, a document server (kodoffice or ONLYOFFICE), Imaginary, nightly database backups and optional Milvus |

Releases are signed: GPG provenance files for the Helm repo, cosign signatures
for the OCI artifacts. See the [chart README](charts/kodbox/README.md#install)
to verify them.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately, as
described in [SECURITY.md](SECURITY.md).

## Releasing

Merging to `main` releases every chart version that has no release yet: a
GitHub Release `<chart>-<version>` with the GPG-signed package, the Helm repo
index on the `gh-pages` branch, and a cosign-signed OCI artifact on
`ghcr.io/pinclr/charts`. Renovate opens pull requests for image updates.
