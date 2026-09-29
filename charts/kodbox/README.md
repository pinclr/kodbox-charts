# kodbox Helm chart

Deploys [kodbox](https://github.com/kalcaddle/kodbox), a self-hosted web file
manager and online office, with the services from the reference docker-compose
install:

| Component | Kind | Purpose | Default storage |
|---|---|---|---|
| `app` | Deployment | kodbox (nginx + php-fpm) | 8Gi RWO at `/var/www/html` |
| `db` | StatefulSet | MariaDB | 4Gi RWO |
| `redis` | StatefulSet | sessions and cache (append-only persistence) | 2Gi RWO |
| `kodoffice` | Deployment | Office document server (browser-facing) | none |
| `imaginary` | Deployment | thumbnails / image processing | none |
| `etcd`, `minio`, `milvus` | StatefulSets | Milvus vector database for AI search (off by default) | 5Gi / 50Gi / 20Gi RWO |

The defaults are a minimal single-replica, non-HA install on the cluster's
default storage class. [`values-production.yaml`](values-production.yaml) is an
example production setup: two app replicas on a shared ReadWriteMany volume,
larger resources, pre-created secrets, Milvus and Gateway API routing.

Each component except `app` can be turned off with `<component>.enabled=false`
(`milvus.enabled` covers etcd, minio and milvus).

## Install

```bash
helm repo add kodbox https://pinclr.github.io/kodbox-charts
helm repo update
helm install kodbox kodbox/kodbox -n kodbox --create-namespace
```

For production, start from the example values:

```bash
helm show values kodbox/kodbox > values.yaml          # all options
curl -LO https://raw.githubusercontent.com/pinclr/kodbox-charts/main/charts/kodbox/values-production.yaml
# edit storage classes, hostnames, gateway and secrets, then:
helm install kodbox kodbox/kodbox -n kodbox --create-namespace \
  -f values-production.yaml --set app.replicaCount=1
```

On first start the kodbox image copies the site into the volume, installs
itself against the bundled database and redis, and creates the admin account
from the `<release>-admin` Secret:

```bash
kubectl -n kodbox get secret kodbox-admin -o jsonpath='{.data.KODBOX_ADMIN_PASSWORD}' | base64 -d
```

- The password is generated if `admin.password` is empty, or taken from
  `admin.existingSecret` (keys `KODBOX_ADMIN_USER`, `KODBOX_ADMIN_PASSWORD`).
- It must pass kodbox's default rule: 8+ characters using 3 of digits,
  uppercase, lowercase and `~!@#$%^&*`. Avoid `"`, `$`, `` ` `` and `\`, which
  break the image's install command.
- It only applies to a **fresh install**. On an existing install, or after the
  admin changes the password in the UI, the Secret is not updated and no longer
  matches.
- With `admin.bootstrap=false`, the first person to open the site creates the
  admin account.

Then, in the kodbox admin panel, point the plugins at:

- kodoffice: its public URL, e.g. `https://kodoffice.example.com` (must be reachable from users' browsers)
- imaginary: `http://<release>-imaginary:9000`
- milvus: `<release>-milvus:19530`

`helm status kodbox -n kodbox` prints these for your release.

## Exposure

Without routing, use `kubectl port-forward` as printed by the install notes.
KodOffice is loaded directly by browsers, so it needs its own hostname.

**Gateway API** (`gateway.enabled=true`): creates HTTPRoutes for
`gateway.app.hostnames` and `gateway.kodoffice.hostnames`, plus HTTP→HTTPS
redirects. By default they attach to the existing Gateway in
`gateway.parentRefs`; with `gateway.create=true` the chart deploys its own
Gateway (`gateway.className`, `gateway.tlsSecretName`).

**Ingress** (`ingress.enabled=true`): one Ingress for `ingress.app.host` and,
if set, `ingress.kodoffice.host`. Raise the body size limit for large uploads,
e.g. `nginx.ingress.kubernetes.io/proxy-body-size: "0"`.

**Idle timeouts:** proxies may cut a request that sends no bytes for a while
(Cilium's gateway: 5 minutes, `envoy.streamIdleTimeoutDurationSeconds`).
Uploads and downloads are fine while data flows. `gateway.timeouts` sets the
HTTPRoute request timeouts but doesn't change a proxy's idle timeout.

## Images and registries

Each image has `registry`, `repository`, `tag` and `digest`:

| Component | Default image |
|---|---|
| app | `docker.io/kodcloud/kodbox:<appVersion>` |
| db, redis, kodoffice, imaginary, etcd, minio, milvus | `registry.cn-hangzhou.aliyuncs.com/kodcloud/<name>:<tag>` |

- `global.imageRegistry` replaces the registry of every image, e.g. a mirror or
  pull-through cache holding the same `kodcloud/...` paths:
  `--set global.imageRegistry=harbor.example.com/kodcloud-mirror`.
- `<component>.image.registry` changes a single image. A `repository` that
  already starts with a registry host (`quay.io/org/image`) is used as-is.
- `<component>.image.digest` (`sha256:...`) pins an exact build.
- `imagePullSecrets` applies to every pod.

## Pod options

Every component (`app`, `db`, `redis`, `kodoffice`, `imaginary`,
`milvus.etcd`, `milvus.minio`, `milvus.standalone`) takes the same settings:

| Key | Purpose |
|---|---|
| `resources` | Requests and limits |
| `extraEnv` | Extra environment variables, e.g. KodOffice's JWT settings |
| `podAnnotations` / `podLabels` | Extra pod metadata |
| `nodeSelector` / `tolerations` / `affinity` | Scheduling |
| `topologySpreadConstraints` | Spread pods; a constraint without a `labelSelector` gets the component's pod labels |
| `priorityClassName` | Pod priority |

On first start the app waits in an init container until the database (and
redis) accept connections, so the kodbox installer doesn't run against a
database that is still starting. Disable with `app.waitForDependencies=false`.

## Resource sizing

Every container has requests and limits (`<component>.resources`). The two
profiles below are what `values.yaml` (dev / small team) and
`values-production.yaml` set. They are starting points: watch actual usage
(`kubectl top pods`) and adjust.

### Dev / small team (`values.yaml`)

One replica of everything, Milvus off. Fits on a single node with
**4 vCPU / 8 GiB** free; set aside ~10 GiB more if bursts should reach the limits.

| Service | CPU request | CPU limit | Memory request | Memory limit | Storage |
|---|---|---|---|---|---|
| app (kodbox) | 250m | 2 | 512Mi | 2Gi | 8Gi RWO |
| db (MariaDB) | 250m | 2 | 512Mi | 2Gi | 4Gi RWO |
| redis | 50m | 500m | 64Mi | 512Mi | 2Gi RWO |
| kodoffice | 500m | 2 | 1Gi | 4Gi | – |
| imaginary | 100m | 1 | 128Mi | 1Gi | – |
| **Total** | **1.15** | **7.5** | **~2.2Gi** | **9.5Gi** | **14Gi** |

Enabling Milvus (`milvus.enabled=true`) with the default sizes adds:

| Service | CPU request | CPU limit | Memory request | Memory limit | Storage |
|---|---|---|---|---|---|
| etcd | 100m | 1 | 256Mi | 2Gi | 5Gi RWO |
| minio | 100m | 1 | 256Mi | 2Gi | 50Gi RWO |
| milvus standalone | 500m | 4 | 2Gi | 8Gi | 20Gi RWO |
| **Milvus subtotal** | **0.7** | **6** | **2.5Gi** | **12Gi** | **75Gi** |

### Production (`values-production.yaml`)

Two app replicas on a shared ReadWriteMany volume, Milvus on.

| Service | Replicas | CPU request | CPU limit | Memory request | Memory limit | Storage |
|---|---|---|---|---|---|---|
| app (kodbox) | 2 | 1 each | 4 each | 2Gi each | 8Gi each | 250Gi RWX (shared) |
| db (MariaDB) | 1 | 500m | 4 | 1Gi | 4Gi | 50Gi RWO |
| redis | 1 | 50m | 1 | 64Mi | 2Gi | 5Gi RWO |
| kodoffice | 1 | 500m | 8 | 1Gi | 16Gi | – |
| imaginary | 1 | 500m | 4 | 512Mi | 8Gi | – |
| etcd | 1 | 100m | 1 | 256Mi | 2Gi | 5Gi RWO |
| minio | 1 | 100m | 1 | 256Mi | 2Gi | 50Gi RWO |
| milvus standalone | 1 | 500m | 4 | 2Gi | 8Gi | 20Gi RWO |
| **Total** | | **4.25** | **31** | **~9.1Gi** | **58Gi** | **250Gi RWX + 130Gi RWO** |

The requests are small against the limits, so the scheduler places pods on
their requests and the limits can burst. Plan for **at least 2 worker nodes**
(so the app replicas land on different nodes) with **8 vCPU / 32 GiB** each:
kodoffice alone may burst to 16Gi and needs a node with that much free.

### What drives each service

| Service | Grows with | Signs it's undersized | What to change |
|---|---|---|---|
| app | Concurrent users, uploads, zip/unzip, search | High CPU, slow pages, readiness failures | Add replicas (needs RWX); raise CPU |
| app volume | Stored user files (all data lives here) | PVC filling up | `app.persistence.size`; use a storage class that can expand |
| db | Number of files, shares and users (metadata only) | Slow listings and search | Memory first; storage grows slowly |
| redis | Active sessions and cache | Evictions, logouts | Memory limit; it stays small |
| kodoffice | Concurrent editing sessions, document size | OOMKilled, editor fails to open or save | Memory limit (plan ~1Gi per few concurrent editors); CPU for conversion |
| imaginary | Image size and concurrency (`-concurrency 10`, `-max-allowed-resolution 500` MP) | OOMKilled on large photos, slow thumbnails | Memory limit, or lower `-concurrency` / max resolution in `imaginary.args` |
| milvus | Number of indexed documents (vectors held in memory) | OOMKilled, slow AI search | Memory limit; storage for segments |
| minio | Milvus segment and index files | PVC filling up | `milvus.minio.persistence.size` |
| etcd | Milvus metadata (small) | Alarms about the backend quota (`ETCD_QUOTA_BACKEND_BYTES`, 4 GiB) | Rarely needs changing |

## Scaling

More than one app replica needs a **ReadWriteMany** volume
(`app.persistence.storageClass` / `accessModes`, e.g. CephFS, NFS, EFS) and
`app.strategy.type=RollingUpdate`; see `values-production.yaml`. The default
ReadWriteOnce volume only supports a single replica with the `Recreate` strategy.

Install with 1 replica, wait for the first start to finish, then scale:

```bash
helm upgrade kodbox kodbox/kodbox -n kodbox --reset-then-reuse-values \
  --set app.replicaCount=2
```

Replicas share the volume and keep sessions in redis. The chart refuses to
render combinations that deploy but can't work: more than one replica without
persistence, without a ReadWriteMany volume (unless `existingClaim` is set) or
without redis, or a PodDisruptionBudget whose `minAvailable` blocks node drains. With more than one
replica the chart adds a PodDisruptionBudget (`app.pdb`, minAvailable 1), and
replicas prefer different nodes (`app.podAntiAffinity`: `soft`, `hard` or `none`).

## Upgrades

Always upgrade with `--reset-then-reuse-values`. Plain `--reuse-values` reuses
only the values stored at install time, so defaults added to the chart later
are missing and templates can fail to render.

Generated passwords (database, minio, admin) are read back from the existing
Secrets on upgrade and don't change.

## Network policies

`networkPolicy.enabled` (default `true`) limits who can reach the backing services:

| Service | Allowed from |
|---|---|
| db, redis, imaginary | app |
| etcd, minio | milvus |
| milvus | app, plus `networkPolicy.milvusExtraFrom` |

The app and kodoffice are not restricted, because the gateway proxies to them.
To let another in-cluster service use Milvus, add it to `milvusExtraFrom`.

## Health checks

| Component | Check |
|---|---|
| app | `GET /healthz.php` (mounted by the chart; nginx + php-fpm, no database) |
| db | `healthcheck.sh --connect --innodb_initialized` |
| redis | `redis-cli ping` |
| kodoffice | `GET /healthcheck` |
| imaginary | `GET /health` |
| etcd / minio / milvus | `etcdctl endpoint health` / `/minio/health/*` / `/healthz` |

Milvus waits for etcd and minio in an init container before starting.

`helm test <release>` checks that the app answers (including a page that uses
the database) and that KodOffice is up. CI installs the chart on a kind cluster
and runs these tests for every pull request.

## Data and uninstall

Uninstalling the release does **not** delete data:

- The app volume is annotated `helm.sh/resource-policy: keep`.
- The db, redis, etcd, minio and milvus StatefulSets use
  `persistentVolumeClaimRetentionPolicy: Retain`.

A reinstall with the same release name and namespace picks the volumes up again.
To delete the data for good:

```bash
helm uninstall kodbox -n kodbox
kubectl -n kodbox delete pvc --all
```

**Deleting the namespace deletes every volume in it**, and with a storage class
using `reclaimPolicy: Delete` the data is gone. Back up first.

The Secrets holding generated passwords are deleted on uninstall. If you
reinstall onto the kept volumes, set `database.password`,
`database.rootPassword` and `milvus.minio.rootPassword` to the old values
(or use `database.existingSecret`), or the services won't be able to log in to
their existing data.

## Main values

| Key | Default | Notes |
|---|---|---|
| `app.replicaCount` | `1` | Scale up after first start; >1 needs ReadWriteMany |
| `app.persistence.storageClass` | `""` (cluster default) | |
| `app.persistence.accessModes` | `[ReadWriteOnce]` | `ReadWriteMany` for multiple replicas |
| `app.persistence.size` | `8Gi` | Holds all user files |
| `app.strategy.type` | `Recreate` | `RollingUpdate` with ReadWriteMany |
| `admin.bootstrap` / `admin.password` | `true` / generated | Initial admin, fresh installs only |
| `database.existingSecret` | `""` | Keys `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD` |
| `db.enabled` / `externalDatabase.host` | `true` / `""` | Use an external MySQL/MariaDB |
| `redis.persistence.enabled` / `size` | `true` / `2Gi` | `false` for in-memory only |
| `kodoffice.enabled` / `imaginary.enabled` | `true` | |
| `milvus.enabled` | `false` | etcd + minio + milvus for AI search |
| `gateway.enabled` | `false` | Gateway API HTTPRoutes |
| `ingress.enabled` | `false` | |
| `networkPolicy.enabled` | `true` | |
| `global.imageRegistry` | `""` | Registry for every image (mirror / pull-through cache) |
| `app.waitForDependencies` | `true` | Wait for database and redis on start |
| `<component>.resources` | set for every component | All containers have requests and limits |

See `values.yaml` for everything else.
