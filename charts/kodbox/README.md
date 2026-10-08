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
| `etcd`, `minio`, `milvus` | StatefulSets | Milvus vector database for AI search (off by default); `minio` runs RustFS (S3) | 4Gi / 8Gi / 8Gi RWO |

The defaults are a minimal single-replica, non-HA install on the cluster's
default storage class. [`values-production.yaml`](values-production.yaml) is an
example production setup: 2–8 autoscaled app replicas on a shared ReadWriteMany volume,
larger resources, pre-created secrets, Milvus and Gateway API routing.

Each component except `app` can be turned off with `<component>.enabled=false`
(`milvus.enabled` covers etcd, RustFS (the `minio` component) and milvus).

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
  -f values-production.yaml --set app.replicaCount=1 --set app.autoscaling.enabled=false
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
| db | `docker.io/library/mariadb:12.3.3` (official, LTS line) |
| redis | `docker.io/library/redis:8.10.2-alpine` (official) |
| imaginary | `docker.io/nextcloud/aio-imaginary:<build date>` (maintained by Nextcloud) |
| etcd | `quay.io/coreos/etcd:v3.5.34` (official) |
| minio | `docker.io/rustfs/rustfs:1.0.1` (S3/MinIO-compatible; MinIO's community images were removed) |
| milvus | `docker.io/milvusdb/milvus:v2.6.25` (official) |
| kodoffice | `registry.cn-hangzhou.aliyuncs.com/kodcloud/kodoffice:7.4.1.1` (only published by kodcloud) |

Images are pinned to versions so upgrades are deliberate. Every pull request
scans them with Trivy (see the "Image scan" job summary).

- `global.imageRegistry` replaces the registry of every image, e.g. a mirror or
  pull-through cache holding the same repository paths (`library/mariadb`,
  `kodcloud/...`): `--set global.imageRegistry=harbor.example.com/dockerhub-proxy`.
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
redis) accept connections; the image's entrypoint also waits and retries its
installer. Disable the init container with `app.waitForDependencies=false`.

**External Redis:** set `redis.enabled=false`, `externalRedis.host` and, for a
password, `externalRedis.password` or `externalRedis.existingSecret`. Like the
database settings, kodbox writes them into `config/setting_user.php` on the
first start only; to change them later, edit that file in the app volume. The
image's installer doesn't pass a port, so the Redis must listen on 6379.

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
| etcd | 100m | 1 | 256Mi | 2Gi | 4Gi RWO |
| minio (RustFS) | 100m | 1 | 256Mi | 2Gi | 8Gi RWO |
| milvus standalone | 500m | 4 | 2Gi | 8Gi | 8Gi RWO |
| **Milvus subtotal** | **0.7** | **6** | **2.5Gi** | **12Gi** | **20Gi** |

### Production (`values-production.yaml`)

2–8 app replicas on a shared ReadWriteMany volume, autoscaled on CPU, Milvus
on. Totals are at the minimum of 2 app replicas; each extra replica adds
1 CPU / 2Gi of requests (up to +6 CPU / +12Gi at 8 replicas).

| Service | Replicas | CPU request | CPU limit | Memory request | Memory limit | Storage |
|---|---|---|---|---|---|---|
| app (kodbox) | 2–8 | 1 each | 4 each | 2Gi each | 8Gi each | 250Gi RWX (shared) |
| db (MariaDB) | 1 | 500m | 4 | 1Gi | 4Gi | 50Gi RWO |
| redis | 1 | 50m | 1 | 64Mi | 2Gi | 10Gi RWO |
| kodoffice | 1 | 500m | 8 | 1Gi | 16Gi | – |
| imaginary | 1 | 500m | 4 | 512Mi | 8Gi | – |
| etcd | 1 | 100m | 1 | 256Mi | 2Gi | 10Gi RWO |
| minio (RustFS) | 1 | 100m | 1 | 256Mi | 2Gi | 80Gi RWO |
| milvus standalone | 1 | 500m | 4 | 2Gi | 8Gi | 40Gi RWO |
| **Total** | | **4.25** | **31** | **~9.1Gi** | **58Gi** | **250Gi RWX + 190Gi RWO** |

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
| minio (RustFS) | Milvus segment, index and WAL files | PVC filling up | `milvus.minio.persistence.size` |
| etcd | Milvus metadata (small) | Alarms about the backend quota (`ETCD_QUOTA_BACKEND_BYTES`: 2 GiB default, 4 GiB in production) | Keep the quota well below the volume size |

## Scaling

More than one app replica needs a **ReadWriteMany** volume
(`app.persistence.storageClass` / `accessModes`, e.g. CephFS, NFS, EFS) and
`app.strategy.type=RollingUpdate`; see `values-production.yaml`. The default
ReadWriteOnce volume only supports a single replica with the `Recreate` strategy.

Install with 1 replica (and autoscaling off), wait for the first start to
finish, then scale:

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

### Autoscaling

`app.autoscaling.enabled=true` adds a HorizontalPodAutoscaler (requires
metrics-server) that replaces `replicaCount`; `values-production.yaml` runs
2–8 replicas at a 70% CPU target. The same checks apply, using `maxReplicas`.

How the target works:

- Utilization is **relative to the CPU request**, not the limit: with the
  production request of 1 CPU, 70% means an average of 700m per pod. Pods can
  burst to their 4-CPU limit, so utilization can read above 100%.
- It is a **near-current average across all app pods**, not a long-term one.
  metrics-server samples usage about every 15s (averaged over that window), and
  the HPA re-evaluates every 15s: `desired = ceil(replicas × current / target)`,
  skipping changes within ±10% of the target.
- **Scale-up is immediate** (up to double the pods, or +4, per 15s). **Scale-down
  waits 5 minutes** and uses the highest recommendation seen in that window, so
  short dips don't remove pods. Tune both with `app.autoscaling.behavior`.
- Newly started pods' CPU is ignored until they are ready, so the first start
  of a replica doesn't trigger further scaling.

## Upgrades

Always upgrade with `--reset-then-reuse-values`. Plain `--reuse-values` reuses
only the values stored at install time, so defaults added to the chart later
are missing and templates can fail to render.

Generated passwords (database, RustFS, admin) are read back from the existing
Secrets on upgrade and don't change.

### Milvus: MinIO to RustFS (0.5.0)

From 0.5.0 Milvus' object storage (the `minio` component) runs RustFS instead of
MinIO, whose community edition is archived and whose images were removed from
Docker Hub and quay.io. RustFS can't read MinIO's data, and Milvus keeps its
segments and write-ahead log there, so the Milvus stack starts over. kodbox's
files are not affected; only the AI search index has to be rebuilt.

If `milvus.enabled=true`, before upgrading (release `kodbox` in namespace
`kodbox`; the upgrade refuses to run while the old MinIO StatefulSet exists):

```bash
kubectl -n kodbox delete statefulset kodbox-etcd kodbox-minio kodbox-milvus
kubectl -n kodbox delete pvc data-kodbox-etcd-0 data-kodbox-minio-0 data-kodbox-milvus-0
helm upgrade kodbox kodbox/kodbox -n kodbox --reset-then-reuse-values  # plus your -f / --set
```

Then rebuild the index from kodbox's AI search settings (re-index the files).
With Milvus disabled there is nothing to do.

**StatefulSet volume sizes can't be changed by an upgrade** (Kubernetes rejects
changes to `volumeClaimTemplates`). 0.4.0 lowered the Milvus defaults (etcd
5Gi→4Gi, minio 50Gi→8Gi, milvus 20Gi→8Gi): if Milvus runs on the old defaults,
pin them before upgrading:

```bash
--set milvus.etcd.persistence.size=5Gi \
--set milvus.minio.persistence.size=50Gi \
--set milvus.standalone.persistence.size=20Gi
```

To grow a volume, the storage class needs `allowVolumeExpansion: true`.
Volumes can grow but never shrink.

- **App volume:** a plain PVC, so raise `app.persistence.size` and upgrade.
- **StatefulSet volumes** (db, redis, etcd, minio/RustFS, milvus): expand the PVC
  itself (`kubectl edit pvc data-<release>-db-0`) and set the same size in values.

**Automatic growth:** Kubernetes can't grow volumes by itself; an add-on such as
[pvc-autoresizer](https://github.com/topolvm/pvc-autoresizer) can, based on
Prometheus volume metrics. It needs `resize.topolvm.io/enabled: "true"` on the
storage class and annotations on each PVC. For the app volume set them in
`app.persistence.annotations` (commented out in `values-production.yaml`); for
StatefulSet volumes use `kubectl annotate pvc`. After it grows a volume, raise
the size in values to match: an upgrade to a smaller size than the live one fails.

## Network policies

`networkPolicy.enabled` (default `true`) limits who can reach the backing services:

| Service | Allowed from |
|---|---|
| db, redis, imaginary | app |
| etcd, minio (RustFS) | milvus |
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
| etcd / minio (RustFS) / milvus | `etcdctl endpoint health` / `/health`, `/health/ready` / `/healthz` |

Milvus waits for etcd and RustFS in an init container before starting.

`helm test <release>` checks that the app answers (including a page that uses
the database) and that KodOffice is up. CI installs the chart on a kind cluster
and runs these tests for every pull request.

## Data and uninstall

Uninstalling the release does **not** delete data:

- The app volume is annotated `helm.sh/resource-policy: keep`.
- The db, redis, etcd, minio (RustFS) and milvus StatefulSets use
  `persistentVolumeClaimRetentionPolicy: Retain`.

A reinstall with the same release name and namespace picks the volumes up again.
To delete the data for good:

```bash
helm uninstall kodbox -n kodbox
kubectl -n kodbox delete pvc --all
```

**Deleting the namespace deletes every volume in it**, and with a storage class
using `reclaimPolicy: Delete` the data is gone. Back up first.

The Secrets holding generated passwords (`<release>-db`, `<release>-admin`,
`<release>-milvus`) are kept too, so a reinstall under the same release name and
namespace reads them back and can still log in to the kept data. Delete them
along with the PVCs to start over:

```bash
kubectl -n kodbox delete secret kodbox-db kodbox-admin kodbox-milvus
```

## Security

- Every pod runs with the `RuntimeDefault` seccomp profile and no host access,
  so the chart runs in namespaces enforcing the Pod Security **baseline**
  standard (CI installs it into one). `<component>.podSecurityContext` and
  `<component>.securityContext` add more; the kodcloud images start as root and
  drop privileges themselves, so test before adding `runAsNonRoot` or dropping
  capabilities.
- Pods use a dedicated ServiceAccount (`serviceAccount.*`) without a mounted API
  token; none of the components talk to the Kubernetes API.
- The `helm test` pod meets the **restricted** standard.

### GitOps (Argo CD)

Generated passwords are read back from the existing Secrets with Helm's
`lookup`, which returns nothing when a tool renders the chart with
`helm template`, as Argo CD does. Every sync would then produce new random
passwords and lock kodbox out of its database. With Argo CD, supply the
credentials instead of generating them:

- `database.existingSecret` and `admin.existingSecret`, pre-created (e.g. with
  External Secrets or Sealed Secrets), and
- `milvus.minio.rootPassword` (the RustFS secret key) when Milvus is enabled.

Flux runs real Helm installs and upgrades, where `lookup` works.

## Main values

| Key | Default | Notes |
|---|---|---|
| `app.replicaCount` | `1` | Scale up after first start; >1 needs ReadWriteMany |
| `app.autoscaling.enabled` | `false` | HPA, `minReplicas` 2 / `maxReplicas` 8 / 70% CPU |
| `app.persistence.storageClass` | `""` (cluster default) | |
| `app.persistence.accessModes` | `[ReadWriteOnce]` | `ReadWriteMany` for multiple replicas |
| `app.persistence.size` | `8Gi` | Holds all user files |
| `app.strategy.type` | `Recreate` | `RollingUpdate` with ReadWriteMany |
| `admin.bootstrap` / `admin.password` | `true` / generated | Initial admin, fresh installs only |
| `database.existingSecret` | `""` | Keys `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_ROOT_PASSWORD` |
| `db.enabled` / `externalDatabase.host` | `true` / `""` | Use an external MySQL/MariaDB |
| `redis.enabled` / `externalRedis.host` | `true` / `""` | Use an external Redis; `externalRedis.password` or `existingSecret` for auth. Port must be 6379, applied on first start only |
| `redis.persistence.enabled` / `size` | `true` / `2Gi` | `false` for in-memory only |
| `kodoffice.enabled` / `imaginary.enabled` | `true` | |
| `milvus.enabled` | `false` | etcd + RustFS (`minio`) + milvus for AI search |
| `gateway.enabled` | `false` | Gateway API HTTPRoutes |
| `ingress.enabled` | `false` | |
| `networkPolicy.enabled` | `true` | |
| `timezone` | `""` (UTC) | IANA zone for all components, e.g. `Asia/Shanghai`: sets `TZ` and PHP's `date.timezone` |
| `global.imageRegistry` | `""` | Registry for every image (mirror / pull-through cache) |
| `app.waitForDependencies` | `true` | Wait for database and redis on start |
| `serviceAccount.create` | `true` | Dedicated ServiceAccount, API token not mounted |
| `<component>.podSecurityContext` | `RuntimeDefault` seccomp | Plus `<component>.securityContext` for containers |
| `<component>.resources` | set for every component | All containers have requests and limits |

See `values.yaml` for everything else.
