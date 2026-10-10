# Contributing

Thanks for helping improve the kodbox chart. Issues and pull requests are
welcome; for security issues see [SECURITY.md](SECURITY.md).

## Making a change

1. Edit the chart under `charts/kodbox`.
2. **Bump `version` in `Chart.yaml`** (SemVer) and replace
   `artifacthub.io/changes` with this release's changes:

   | Change | Bump |
   |---|---|
   | Fixes, docs, image updates, new optional values | patch |
   | New features that don't break existing installs | minor |
   | Renamed/removed values, changed resource names, data migrations | major (minor while < 1.0) |

3. If you added or changed values, update `scripts/gen_values_schema.py` and
   regenerate the schema and the README's values reference:

   ```bash
   python3 scripts/gen_values_schema.py
   python3 scripts/gen_values_doc.py   # needs PyYAML
   ```

4. Check locally (unit tests need the
   [helm-unittest](https://github.com/helm-unittest/helm-unittest) plugin; add
   a case to `charts/kodbox/tests/` for new template logic):

   ```bash
   helm unittest charts/kodbox
   helm lint charts/kodbox
   helm lint charts/kodbox -f charts/kodbox/values-production.yaml
   helm template test charts/kodbox > /dev/null
   ```

5. Open a pull request. CI lints the chart, runs the unit tests, checks the
   version bump, the changelog annotation and the generated files, installs it on a kind cluster for each
   `charts/kodbox/ci/*-values.yaml`, tests upgrades from the newest published
   release (patch bumps through chart-testing, minor bumps through
   `scripts/ci-upgrade-test.sh`; major bumps are skipped), runs `helm test`, tests backup and restore, and scans the images
   with Trivy.

## Releases

Merging to `main` releases every chart version that has no release yet: a
GitHub Release with the GPG-signed package, the Helm repo index on GitHub
Pages and a cosign-signed OCI artifact on GHCR. There's nothing to run by hand.

Image updates arrive as Renovate pull requests, which bump the chart's patch
version themselves.

## Conventions

- Values are camelCase and documented in both `values.yaml` and the schema.
- Every component takes the same pod options (see README "Pod options");
  new components should use the shared helpers in `templates/_helpers.tpl`.
- Keep defaults generic; site-specific settings belong in your own values or
  as commented examples in `values-production.yaml`.
