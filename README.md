# kodbox-charts

Helm charts for [kodbox](https://github.com/kalcaddle/kodbox).

```bash
helm repo add kodbox https://pinclr.github.io/kodbox-charts
helm install kodbox kodbox/kodbox -n kodbox --create-namespace
```

| Chart | Description |
|---|---|
| [kodbox](charts/kodbox) | kodbox with MariaDB, Redis, KodOffice, Imaginary and optional Milvus |

## Releasing

1. Change the chart and bump `version` in its `Chart.yaml` (and
   `artifacthub.io/changes`). The PR check fails without a version bump.
2. Merge to `main`. The release workflow packages every chart version that
   has no release yet, creates a GitHub Release `<chart>-<version>` and updates
   the Helm repo index on the `gh-pages` branch.
