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

Or from the OCI registry (chart 0.7.0 and later):

```bash
helm install kodbox oci://ghcr.io/pinclr/charts/kodbox --version 0.7.0 -n kodbox --create-namespace
```

**Verify a release:** packages from the Helm repo carry a GPG provenance file,
OCI artifacts a cosign signature from this repository's release workflow:

```bash
curl -s https://raw.githubusercontent.com/pinclr/kodbox-charts/main/signing-key.asc | gpg --import
gpg --export > ~/.gnupg/pubring.gpg   # Helm reads the legacy keyring format
helm pull kodbox/kodbox --version 0.7.0 --verify

cosign verify ghcr.io/pinclr/charts/kodbox:0.7.0 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/pinclr/kodbox-charts/\.github/workflows/release\.yaml@refs/heads/main$'
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

## Document server

The `kodoffice` component runs one of two document servers
(`kodoffice.edition`); service, hostnames and routes are the same for both:

| | `kodoffice` (default) | `onlyoffice` |
|---|---|---|
| Image | kodcloud's ONLYOFFICE 7.4 build (`kodoffice.image`) | Upstream ONLYOFFICE Document Server Community Edition 9.4 (`kodoffice.onlyoffice.image`) |
| kodbox plugin | kodoffice | onlyoffice |
| JWT | Off (image default) | On, with a generated secret kept across upgrades |
| Security | Outdated (many fixable CVEs) | Maintained upstream |
| Fonts | Chinese fonts included | Basic fonts; add CJK fonts if documents need them |

With `onlyoffice` the chart reproduces kodoffice's settings that matter to
kodbox: downloads from private IPs are allowed (`onlyoffice.allowPrivateIpAddress`;
kodbox's file URLs usually resolve to private addresses), and files up to 500MB
with 10 minute download timeouts (`onlyoffice.config`, written to
`local-production-linux.json`).

To switch:

1. `--set kodoffice.edition=onlyoffice` and upgrade.
2. Read the JWT secret (printed by `helm status`, or
   `kubectl get secret <release>-kodoffice -o jsonpath='{.data.JWT_SECRET}' | base64 -d`).
3. In kodbox, enable the **onlyoffice** plugin with the document server's
   public URL and the JWT secret, and disable the kodoffice plugin.

`kodoffice.jwt.enabled` overrides the automatic choice; set it to `false` only
if your kodbox plugin has no secret setting (anyone who can reach the server
can then use it). `kodoffice.jwt.existingSecret` uses a pre-created secret.

**Scaling:** both editions run as a single replica: the image bundles its own
PostgreSQL, RabbitMQ and Redis, and open documents live in that pod. Give it
more CPU and memory to serve more users. For a horizontally scaled server use
ONLYOFFICE's own Kubernetes chart (Docs), set `kodoffice.enabled=false` and point
kodbox's onlyoffice plugin at it. The Community Edition limits concurrent
connections either way.

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
| kodoffice | `registry.cn-hangzhou.aliyuncs.com/kodcloud/kodoffice:7.4.1.1` (only published by kodcloud), or `docker.io/onlyoffice/documentserver:9.4.0.1` with `kodoffice.edition=onlyoffice` |

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
| `livenessProbe` / `readinessProbe` / `startupProbe` | Merged over the chart's probe, e.g. `{periodSeconds: 30, failureThreshold: 10}`; `enabled: false` removes it. A probe the chart doesn't define (e.g. etcd's `startupProbe`) needs its own handler |
| `podSecurityContext` / `securityContext` | Pod and container security contexts |
| `extraVolumes` / `extraVolumeMounts` | Extra volumes on the pod, mounted into the main container, e.g. a ConfigMap overriding nginx.conf or php-fpm's www.conf |
| `extraContainers` | Sidecar containers, e.g. Prometheus exporters (`mysqld_exporter`, `redis_exporter`) |

`backup` takes the same settings except the probes and the extras.

Chart-wide:

| Key | Purpose |
|---|---|
| `commonLabels` / `commonAnnotations` | Added to every resource (labels also to pods, never to selectors); a resource's own annotations win |
| `global.storageClass` | Storage class for every volume without its own; `"-"` sets an empty `storageClassName` |
| `revisionHistoryLimit` | Old ReplicaSets / StatefulSet revisions kept for rollbacks (default 10) |
| `<component>.service.annotations` | Service annotations, e.g. for a cloud load balancer; the app and kodoffice Services also take `nodePort` and `loadBalancerSourceRanges` (Milvus: `loadBalancerSourceRanges`) |

All resources are created in the release namespace (`helm -n`), written into
each manifest; `namespaceOverride` puts them in another namespace (for umbrella
charts).

On first start the image's entrypoint waits for the database (and redis) and
retries its installer. `app.waitForDependencies=true` adds an init container
that waits as well (off by default since 0.8.0).

Since 0.8.0 every component takes `extraVolumes`, `extraVolumeMounts` and
`extraContainers` (earlier only the app had volumes, and db/redis sidecars).

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
| backup (nightly job) | 50m | 1 | 128Mi | 512Mi | 20Gi RWO |
| **Total** | **1.15** | **7.5** | **~2.2Gi** | **9.5Gi** | **34Gi** |

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
| backup (nightly job) | – | 50m | 1 | 128Mi | 512Mi | 20Gi RWO |
| etcd | 1 | 100m | 1 | 256Mi | 2Gi | 10Gi RWO |
| minio (RustFS) | 1 | 100m | 1 | 256Mi | 2Gi | 80Gi RWO |
| milvus standalone | 1 | 500m | 4 | 2Gi | 8Gi | 40Gi RWO |
| **Total** | | **4.25** | **31** | **~9.1Gi** | **58Gi** | **250Gi RWX + 210Gi RWO** |

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

### Graceful shutdown

When an app pod stops (scale-down, rollout, node drain) it keeps serving for
`app.preStopSleepSeconds` (10s) while the Service and gateway stop routing to
it. Then supervisord stops nginx and php-fpm with SIGQUIT, so running requests
finish; the image's supervisord allows each about 10s before killing it.
`app.terminationGracePeriodSeconds` (60s) covers both. Requests that still
run after that, such as a slow large upload, are cut off. `app.lifecycle`
replaces the default hook.

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

## Backups

`backup.enabled` (off by default, on in `values-production.yaml`) runs
`mariadb-dump` of the kodbox database,
bundled or external, every night at 02:00 (`backup.schedule`, in `timezone`
when set). Each run writes a gzipped dump to its own 20Gi volume
(`<release>-backup`, `backup.persistence`) and keeps the newest 14
(`backup.keep`). The job runs as the image's non-root `mysql` user, and
`helm test` checks that a dump succeeds.

What it doesn't cover:

- **User files.** They live on the app volume; back that up with your storage
  (e.g. CephFS snapshots). Restore files and database from the same point in time.
- **Off-site copies.** The dumps sit in the same cluster and storage; copy them
  elsewhere regularly.

**Storage classes that bind on first use** (`volumeBindingMode:
WaitForFirstConsumer`, the default on EKS, GKE and AKS): the backup volume
stays `Pending` until the first backup runs, so `helm install --wait` or
`helm upgrade --wait` times out. Either use a class with `Immediate` binding
for `backup.persistence.storageClass`, install without `--wait` and trigger a
first backup (below), or point `backup.persistence.existingClaim` at a bound PVC.

A dump is roughly 10-20% of the database size, so 14 dumps of a 5GB database
need about 10-15GB. Check the job log: each run ends with `df -h /backup`.

External database: the user needs `SELECT`, `SHOW VIEW`, `TRIGGER` and
`LOCK TABLES`. MariaDB's client verifies TLS by default; for a server without
TLS add `--skip-ssl` to `backup.extraArgs`.

**Run a backup now:**

```bash
kubectl -n kodbox create job backup-manual-$(date +%s) --from=cronjob/kodbox-backup
```

**Restore** (release `kodbox` in namespace `kodbox`; stop the app first so
nothing writes during the restore; with `app.autoscaling.enabled`, turn it off
first or the autoscaler starts the app again):

```bash
kubectl -n kodbox scale deployment/kodbox-app --replicas=0

# A pod with the backup volume mounted
kubectl -n kodbox apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: kodbox-restore
spec:
  securityContext: {runAsUser: 999, runAsGroup: 999, fsGroup: 999}
  containers:
    - name: restore
      image: docker.io/library/mariadb:12.3.3
      command: ["sleep", "infinity"]
      volumeMounts: [{name: backup, mountPath: /backup}]
  volumes:
    - name: backup
      persistentVolumeClaim: {claimName: kodbox-backup}
YAML
kubectl -n kodbox wait --for=condition=Ready pod/kodbox-restore
kubectl -n kodbox exec kodbox-restore -- ls -lt /backup

# Load a dump into the database (replaces the kodbox database's tables)
kubectl -n kodbox exec kodbox-restore -- cat /backup/kodbox-20261010-020000.sql.gz \
  | gunzip \
  | kubectl -n kodbox exec -i kodbox-db-0 -- sh -c 'mariadb -uroot -p"$MYSQL_ROOT_PASSWORD"'

kubectl -n kodbox delete pod kodbox-restore
kubectl -n kodbox scale deployment/kodbox-app --replicas=1
```

CI runs these steps on every chart change: three backups, pruning to `keep`,
and a restore of the newest dump.

## Data and uninstall

Uninstalling the release does **not** delete data:

- The app volume is annotated `helm.sh/resource-policy: keep`.
- The backup volume is annotated `helm.sh/resource-policy: keep`.
- The db, redis, etcd, minio (RustFS) and milvus StatefulSets use
  `persistentVolumeClaimRetentionPolicy: Retain`.

A reinstall with the same release name and namespace picks the volumes up again.
For a new install on volumes from elsewhere (e.g. restored from a snapshot),
`db.persistence.existingClaim` and `redis.persistence.existingClaim` use an
existing PVC instead of the StatefulSet's own; this can't be switched on an
existing release.
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
  External Secrets or Sealed Secrets),
- `milvus.minio.existingSecret` (keys `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD`)
  when Milvus is enabled, and
- `kodoffice.jwt.existingSecret` with `kodoffice.edition=onlyoffice`.

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
| `kodoffice.edition` | `kodoffice` | `onlyoffice` for upstream ONLYOFFICE 9.4 with JWT |
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

## All values

Every key with its type, default and description, generated from
`values.schema.json` and `values.yaml`. The same reference is on Artifact Hub
under "Values schema".

<!-- values:start (generated by scripts/gen_values_doc.py, do not edit) -->

### global

Global values, shared with parent charts.

| Key | Type | Default | Description |
|---|---|---|---|
| `global.imageRegistry` | string | `""` | Registry for every image (a mirror or pull-through cache); overrides each image's registry. |
| `global.storageClass` | string | `""` | Storage class for every volume without its own; "-" disables dynamic provisioning. |

### timezone

IANA time zone for every component (e.g. Asia/Shanghai); sets TZ and PHP's date.timezone. Empty keeps UTC.

| Key | Type | Default | Description |
|---|---|---|---|
| `timezone` | string | `""` | IANA time zone for every component (e.g. Asia/Shanghai); sets TZ and PHP's date.timezone. Empty keeps UTC. |

### commonLabels

Labels added to every resource and pod.

| Key | Type | Default | Description |
|---|---|---|---|
| `commonLabels` | object | `{}` | Labels added to every resource and pod. |

### commonAnnotations

Annotations added to every resource.

| Key | Type | Default | Description |
|---|---|---|---|
| `commonAnnotations` | object | `{}` | Annotations added to every resource. |

### revisionHistoryLimit

Old ReplicaSets / StatefulSet revisions kept for rollbacks.

| Key | Type | Default | Description |
|---|---|---|---|
| `revisionHistoryLimit` | integer | `10` | Old ReplicaSets / StatefulSet revisions kept for rollbacks. |

### namespaceOverride

Namespace for all resources; empty uses the release namespace.

| Key | Type | Default | Description |
|---|---|---|---|
| `namespaceOverride` | string | `""` | Namespace for all resources; empty uses the release namespace. |

### nameOverride

Override the chart name used in resource names.

| Key | Type | Default | Description |
|---|---|---|---|
| `nameOverride` | string | `""` | Override the chart name used in resource names. |

### fullnameOverride

Override the full resource name prefix.

| Key | Type | Default | Description |
|---|---|---|---|
| `fullnameOverride` | string | `""` | Override the full resource name prefix. |

### imagePullSecrets

Image pull secrets for all pods.

| Key | Type | Default | Description |
|---|---|---|---|
| `imagePullSecrets` | array | `[]` | Image pull secrets for all pods. |

### serviceAccount

ServiceAccount shared by all pods.

| Key | Type | Default | Description |
|---|---|---|---|
| `serviceAccount.create` | boolean | `true` | Create the ServiceAccount. |
| `serviceAccount.name` | string | `""` | ServiceAccount name; defaults to the release's full name, or "default" when create=false. |
| `serviceAccount.annotations` | object | `{}` | ServiceAccount annotations. |
| `serviceAccount.automountServiceAccountToken` | boolean | `false` | Mount the API token into pods; no component needs it. |

### app

Kodbox application (nginx + php-fpm, port 80).

| Key | Type | Default | Description |
|---|---|---|---|
| `app.image.registry` | string | `"docker.io"` | Image registry; global.imageRegistry overrides it. |
| `app.image.repository` | string | `"kodcloud/kodbox"` | Image repository, without the registry (one that starts with a registry host is used as-is). |
| `app.image.tag` | string / number | `""` | Image tag. |
| `app.image.digest` | string | `""` | Image digest (sha256:...) to pin a build; used together with the tag. |
| `app.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `app.replicaCount` | integer | `1` | App replicas. Install with 1; more than 1 needs a ReadWriteMany volume. |
| `app.podAntiAffinity` | "soft" \| "hard" \| "none" | `"soft"` | Spread replicas across nodes. Ignored when app.affinity is set. |
| `app.autoscaling.enabled` | boolean | `false` | Create the HorizontalPodAutoscaler. |
| `app.autoscaling.minReplicas` | integer | `2` | Minimum replicas. |
| `app.autoscaling.maxReplicas` | integer | `8` | Maximum replicas. |
| `app.autoscaling.targetCPUUtilizationPercentage` | integer / string | `70` | Average CPU utilization target (% of requests); empty disables. |
| `app.autoscaling.targetMemoryUtilizationPercentage` | integer / string | `""` | Average memory utilization target (% of requests); empty disables. |
| `app.autoscaling.behavior` | object | `{}` | HPA scaling behavior (scaleUp / scaleDown policies). |
| `app.pdb.enabled` | boolean | `true` | Create the PodDisruptionBudget. |
| `app.pdb.minAvailable` | integer / string | `1` | Minimum available pods (number or percentage). |
| `app.strategy.type` | "Recreate" \| "RollingUpdate" | `"Recreate"` | Recreate for ReadWriteOnce volumes, RollingUpdate for ReadWriteMany. |
| `app.strategy.rollingUpdate` | object |  | RollingUpdate parameters (maxSurge, maxUnavailable). |
| `app.service.type` | "ClusterIP" \| "NodePort" \| "LoadBalancer" | `"ClusterIP"` | Service type. |
| `app.service.port` | integer | `80` | Service port. |
| `app.service.annotations` | object | `{}` | Service annotations, e.g. for a cloud load balancer. |
| `app.service.nodePort` | integer / string | `""` | Fixed node port for type NodePort/LoadBalancer; empty lets Kubernetes assign one. |
| `app.service.loadBalancerSourceRanges` | array | `[]` | Client CIDRs allowed to reach a LoadBalancer Service. |
| `app.persistence.enabled` | boolean | `true` | Persist the kodbox site and user files on a PersistentVolumeClaim; false uses an emptyDir. |
| `app.persistence.storageClass` | string | `""` | Storage class; empty uses the cluster default. |
| `app.persistence.accessModes` | array | `["ReadWriteOnce"]` | PersistentVolumeClaim access modes. |
| `app.persistence.size` | string | `"8Gi"` | Volume size for the kodbox site and user files. |
| `app.persistence.existingClaim` | string | `""` | Use an existing PersistentVolumeClaim instead of creating one. |
| `app.persistence.annotations` | object | `{}` | Extra PVC annotations, e.g. for pvc-autoresizer. |
| `app.waitForDependencies` | boolean | `false` | Wait in an init container for the database and redis before starting kodbox; off by default since the image waits itself. |
| `app.preStopSleepSeconds` | integer | `10` | Seconds the pod keeps serving after termination starts, while it's removed from routing; 0 disables. |
| `app.terminationGracePeriodSeconds` | integer | `60` | Time for the preStop sleep plus nginx/php-fpm to stop gracefully. |
| `app.lifecycle` | object | `{}` | Container lifecycle hooks; replaces the default preStop sleep when set. |
| `app.resources` | object | `{"requests": {"cpu": "250m", "memory": "512Mi"}, "limits"...` | Kubernetes resource requests and limits for the app. |
| `app.nodeSelector` | object | `{}` | Node labels for scheduling app. |
| `app.tolerations` | array | `[]` | Tolerations for app pods. |
| `app.affinity` | object | `{}` | Affinity rules for app pods. |
| `app.podAnnotations` | object | `{}` | Extra annotations for app pods. |
| `app.podLabels` | object | `{}` | Extra labels for app pods. |
| `app.priorityClassName` | string | `""` | PriorityClass for app pods. |
| `app.topologySpreadConstraints` | array | `[]` | Topology spread constraints for app pods; a missing labelSelector is filled with the pod's labels. |
| `app.extraEnv` | array | `[]` | Extra environment variables for the app container. |
| `app.livenessProbe` | object | `{}` | Liveness probe override for app, merged over the chart default; enabled: false removes it. |
| `app.readinessProbe` | object | `{}` | Readiness probe override for app, merged over the chart default; enabled: false removes it. |
| `app.startupProbe` | object | `{}` | Startup probe override for app, merged over the chart default; enabled: false removes it. |
| `app.podSecurityContext` | object | `{"seccompProfile": {"type": "RuntimeDefault"}}` | Pod security context for app pods. |
| `app.securityContext` | object | `{}` | Container security context for app containers. |
| `app.extraVolumes` | array | `[]` | Extra volumes on the app pod. |
| `app.extraVolumeMounts` | array | `[]` | Extra volume mounts on the app container, pairing with extraVolumes. |
| `app.extraContainers` | array | `[]` | Extra sidecar containers in the app pod, e.g. a Prometheus exporter. |

### admin

Initial kodbox admin account, applied only on the very first start.

| Key | Type | Default | Description |
|---|---|---|---|
| `admin.bootstrap` | boolean | `true` | Create the admin account on first start; false lets the first visitor create it. |
| `admin.username` | string | `"admin"` | Admin username. |
| `admin.password` | string | `""` | Admin password; empty generates one. 8+ characters using 3 of digits, upper, lower and ~!@#$%^&*; no " $ ` or \. |
| `admin.existingSecret` | string | `""` | Existing secret with KODBOX_ADMIN_USER and KODBOX_ADMIN_PASSWORD. |

### database

Database credentials shared by the db and app containers.

| Key | Type | Default | Description |
|---|---|---|---|
| `database.name` | string | `"kodbox"` | Database name. |
| `database.user` | string | `"kodbox"` | Database user. |
| `database.password` | string | `""` | Database password; empty generates one. |
| `database.rootPassword` | string | `""` | Database root password; empty generates one. |
| `database.existingSecret` | string | `""` | Existing secret with MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD and MYSQL_ROOT_PASSWORD. |

### db

Bundled MariaDB. Set enabled=false and fill externalDatabase to use your own.

| Key | Type | Default | Description |
|---|---|---|---|
| `db.enabled` | boolean | `true` | Deploy the bundled MariaDB. |
| `db.image.registry` | string | `"docker.io"` | Image registry; global.imageRegistry overrides it. |
| `db.image.repository` | string | `"library/mariadb"` | Image repository, without the registry (one that starts with a registry host is used as-is). |
| `db.image.tag` | string / number | `"12.3.3"` | Image tag. |
| `db.image.digest` | string | `""` | Image digest (sha256:...) to pin a build; used together with the tag. |
| `db.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `db.args` | array | `["--transaction-isolation=READ-COMMITTED"]` | Extra container arguments for MariaDB. |
| `db.service.port` | integer | `3306` | Service port. |
| `db.service.annotations` | object | `{}` | Service annotations, e.g. for a cloud load balancer. |
| `db.persistence.storageClass` | string | `""` | Storage class; empty uses the cluster default. |
| `db.persistence.accessModes` | array | `["ReadWriteOnce"]` | PersistentVolumeClaim access modes. |
| `db.persistence.size` | string | `"4Gi"` | Volume size for MariaDB data. |
| `db.persistence.existingClaim` | string | `""` | Existing PVC instead of the StatefulSet's volume; new installs only. |
| `db.resources` | object | `{"requests": {"cpu": "250m", "memory": "512Mi"}, "limits"...` | Kubernetes resource requests and limits for MariaDB. |
| `db.nodeSelector` | object | `{}` | Node labels for scheduling MariaDB. |
| `db.tolerations` | array | `[]` | Tolerations for MariaDB pods. |
| `db.affinity` | object | `{}` | Affinity rules for MariaDB pods. |
| `db.podAnnotations` | object | `{}` | Extra annotations for MariaDB pods. |
| `db.podLabels` | object | `{}` | Extra labels for MariaDB pods. |
| `db.priorityClassName` | string | `""` | PriorityClass for MariaDB pods. |
| `db.topologySpreadConstraints` | array | `[]` | Topology spread constraints for MariaDB pods; a missing labelSelector is filled with the pod's labels. |
| `db.extraEnv` | array | `[]` | Extra environment variables for the MariaDB container. |
| `db.livenessProbe` | object | `{}` | Liveness probe override for MariaDB, merged over the chart default; enabled: false removes it. |
| `db.readinessProbe` | object | `{}` | Readiness probe override for MariaDB, merged over the chart default; enabled: false removes it. |
| `db.startupProbe` | object | `{}` | Startup probe override for MariaDB, merged over the chart default; enabled: false removes it. |
| `db.podSecurityContext` | object | `{"seccompProfile": {"type": "RuntimeDefault"}}` | Pod security context for MariaDB pods. |
| `db.securityContext` | object | `{}` | Container security context for MariaDB containers. |
| `db.extraVolumes` | array | `[]` | Extra volumes on the MariaDB pod. |
| `db.extraVolumeMounts` | array | `[]` | Extra volume mounts on the MariaDB container, pairing with extraVolumes. |
| `db.extraContainers` | array | `[]` | Extra sidecar containers in the MariaDB pod, e.g. a Prometheus exporter. |

### externalDatabase

External MySQL/MariaDB, used when db.enabled=false.

| Key | Type | Default | Description |
|---|---|---|---|
| `externalDatabase.host` | string | `""` | Database host. |
| `externalDatabase.port` | integer | `3306` | Database port. |

### backup

Scheduled mariadb-dump of the kodbox database onto a dedicated volume.

| Key | Type | Default | Description |
|---|---|---|---|
| `backup.enabled` | boolean | `false` | Create the backup CronJob and volume. Off by default; see README for WaitForFirstConsumer storage. |
| `backup.schedule` | string | `"0 2 * * *"` | Cron schedule, in timezone when set (else UTC). |
| `backup.keep` | integer | `14` | Number of dumps to keep. |
| `backup.extraArgs` | array | `[]` | Extra mariadb-dump options, e.g. --skip-ssl for an external server without TLS. |
| `backup.image.registry` | string | `""` | Image registry. |
| `backup.image.repository` | string | `""` | Image repository. |
| `backup.image.tag` | string / number | `""` | Image tag. |
| `backup.image.digest` | string | `""` | Image digest. |
| `backup.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `backup.persistence.storageClass` | string | `""` | Storage class; empty uses the cluster default. |
| `backup.persistence.accessModes` | array | `["ReadWriteOnce"]` | PersistentVolumeClaim access modes. |
| `backup.persistence.size` | string | `"20Gi"` | Volume size for database dumps. |
| `backup.persistence.existingClaim` | string | `""` | Use an existing PersistentVolumeClaim instead of creating one. |
| `backup.persistence.annotations` | object | `{}` | Extra PVC annotations. |
| `backup.successfulJobsHistoryLimit` | integer | `3` | Finished successful Jobs to keep. |
| `backup.failedJobsHistoryLimit` | integer | `3` | Failed Jobs to keep. |
| `backup.startingDeadlineSeconds` | integer | `3600` | How late a run may start. |
| `backup.resources` | object | `{"requests": {"cpu": "50m", "memory": "128Mi"}, "limits":...` | Kubernetes resource requests and limits for backups. |
| `backup.nodeSelector` | object | `{}` | Node labels for scheduling backup. |
| `backup.tolerations` | array | `[]` | Tolerations for backup pods. |
| `backup.affinity` | object | `{}` | Affinity rules for backup pods. |
| `backup.podAnnotations` | object | `{}` | Extra annotations for backup pods. |
| `backup.podLabels` | object | `{}` | Extra labels for backup pods. |
| `backup.priorityClassName` | string | `""` | PriorityClass for backup pods. |
| `backup.topologySpreadConstraints` | array | `[]` | Topology spread constraints for backup pods; a missing labelSelector is filled with the pod's labels. |
| `backup.extraEnv` | array | `[]` | Extra environment variables for the backup container. |
| `backup.livenessProbe` | object |  | Liveness probe override for backup, merged over the chart default; enabled: false removes it. |
| `backup.readinessProbe` | object |  | Readiness probe override for backup, merged over the chart default; enabled: false removes it. |
| `backup.startupProbe` | object |  | Startup probe override for backup, merged over the chart default; enabled: false removes it. |
| `backup.podSecurityContext` | object | `{"runAsNonRoot": true, "runAsUser": 999, "runAsGroup": 99...` | Pod security context for backup pods. |
| `backup.securityContext` | object | `{"allowPrivilegeEscalation": false, "capabilities": {"dro...` | Container security context for backup containers. |

### redis

Bundled Redis for kodbox sessions and cache.

| Key | Type | Default | Description |
|---|---|---|---|
| `redis.enabled` | boolean | `true` | Deploy the bundled Redis. |
| `redis.image.registry` | string | `"docker.io"` | Image registry; global.imageRegistry overrides it. |
| `redis.image.repository` | string | `"library/redis"` | Image repository, without the registry (one that starts with a registry host is used as-is). |
| `redis.image.tag` | string / number | `"8.10.2-alpine"` | Image tag. |
| `redis.image.digest` | string | `""` | Image digest (sha256:...) to pin a build; used together with the tag. |
| `redis.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `redis.args` | array | `["--appendonly", "yes", "--appendfsync", "everysec"]` | Extra container arguments for redis-server. |
| `redis.service.port` | integer | `6379` | Service port. |
| `redis.service.annotations` | object | `{}` | Service annotations, e.g. for a cloud load balancer. |
| `redis.persistence.enabled` | boolean | `true` | Persist Redis append-only data on a PersistentVolumeClaim; false uses an emptyDir. |
| `redis.persistence.storageClass` | string | `""` | Storage class; empty uses the cluster default. |
| `redis.persistence.accessModes` | array | `["ReadWriteOnce"]` | PersistentVolumeClaim access modes. |
| `redis.persistence.size` | string | `"2Gi"` | Volume size for Redis append-only data. |
| `redis.persistence.existingClaim` | string | `""` | Existing PVC instead of the StatefulSet's volume; new installs only. |
| `redis.resources` | object | `{"requests": {"cpu": "50m", "memory": "64Mi"}, "limits": ...` | Kubernetes resource requests and limits for Redis. |
| `redis.nodeSelector` | object | `{}` | Node labels for scheduling Redis. |
| `redis.tolerations` | array | `[]` | Tolerations for Redis pods. |
| `redis.affinity` | object | `{}` | Affinity rules for Redis pods. |
| `redis.podAnnotations` | object | `{}` | Extra annotations for Redis pods. |
| `redis.podLabels` | object | `{}` | Extra labels for Redis pods. |
| `redis.priorityClassName` | string | `""` | PriorityClass for Redis pods. |
| `redis.topologySpreadConstraints` | array | `[]` | Topology spread constraints for Redis pods; a missing labelSelector is filled with the pod's labels. |
| `redis.extraEnv` | array | `[]` | Extra environment variables for the Redis container. |
| `redis.livenessProbe` | object | `{}` | Liveness probe override for Redis, merged over the chart default; enabled: false removes it. |
| `redis.readinessProbe` | object | `{}` | Readiness probe override for Redis, merged over the chart default; enabled: false removes it. |
| `redis.startupProbe` | object | `{}` | Startup probe override for Redis, merged over the chart default; enabled: false removes it. |
| `redis.podSecurityContext` | object | `{"seccompProfile": {"type": "RuntimeDefault"}, "fsGroup":...` | Pod security context for Redis pods. |
| `redis.securityContext` | object | `{}` | Container security context for Redis containers. |
| `redis.extraVolumes` | array | `[]` | Extra volumes on the Redis pod. |
| `redis.extraVolumeMounts` | array | `[]` | Extra volume mounts on the Redis container, pairing with extraVolumes. |
| `redis.extraContainers` | array | `[]` | Extra sidecar containers in the Redis pod, e.g. a Prometheus exporter. |

### externalRedis

External Redis, used when redis.enabled=false. Empty host disables Redis. Applied on kodbox's first start only; must listen on 6379.

| Key | Type | Default | Description |
|---|---|---|---|
| `externalRedis.host` | string | `""` | Redis host. |
| `externalRedis.password` | string | `""` | Redis password. |
| `externalRedis.existingSecret` | string | `""` | Existing secret holding the Redis password. |
| `externalRedis.existingSecretKey` | string | `"REDIS_PASSWORD"` | Key of the password in existingSecret. |

### kodoffice

Document server (kodoffice or upstream ONLYOFFICE). Browsers load it directly, so it needs a user-reachable URL.

| Key | Type | Default | Description |
|---|---|---|---|
| `kodoffice.enabled` | boolean | `true` | Deploy the document server. |
| `kodoffice.edition` | "kodoffice" \| "onlyoffice" | `"kodoffice"` | kodoffice: kodcloud's ONLYOFFICE 7.4 build. onlyoffice: upstream ONLYOFFICE Document Server (onlyoffice.image). |
| `kodoffice.image.registry` | string | `"registry.cn-hangzhou.aliyuncs.com"` | Image registry; global.imageRegistry overrides it. |
| `kodoffice.image.repository` | string | `"kodcloud/kodoffice"` | Image repository, without the registry (one that starts with a registry host is used as-is). |
| `kodoffice.image.tag` | string / number | `"7.4.1.1"` | Image tag. |
| `kodoffice.image.digest` | string | `""` | Image digest (sha256:...) to pin a build; used together with the tag. |
| `kodoffice.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `kodoffice.onlyoffice.image.registry` | string | `"docker.io"` | Image registry; global.imageRegistry overrides it. |
| `kodoffice.onlyoffice.image.repository` | string | `"onlyoffice/documentserver"` | Image repository, without the registry (one that starts with a registry host is used as-is). |
| `kodoffice.onlyoffice.image.tag` | string / number | `"9.4.0.1"` | Image tag. |
| `kodoffice.onlyoffice.image.digest` | string | `""` | Image digest (sha256:...) to pin a build; used together with the tag. |
| `kodoffice.onlyoffice.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `kodoffice.onlyoffice.allowPrivateIpAddress` | boolean | `true` | Let the server download documents from private IPs (kodbox URLs usually resolve to them). |
| `kodoffice.onlyoffice.config` | object | `{"services": {"CoAuthoring": {"server": {"limits_tempfile...` | Overrides written to ONLYOFFICE's local-production-linux.json (highest precedence). |
| `kodoffice.jwt.enabled` | true \| false \| "" | `""` | true/false, or "" for automatic: on for onlyoffice, off for kodoffice. |
| `kodoffice.jwt.secret` | string | `""` | JWT secret; empty generates one, kept across upgrades. |
| `kodoffice.jwt.existingSecret` | string | `""` | Existing secret holding the JWT secret. |
| `kodoffice.jwt.existingSecretKey` | string | `"JWT_SECRET"` | Key of the JWT secret in existingSecret. |
| `kodoffice.service.type` | "ClusterIP" \| "NodePort" \| "LoadBalancer" | `"ClusterIP"` | Service type. |
| `kodoffice.service.port` | integer | `80` | Service port. |
| `kodoffice.service.annotations` | object | `{}` | Service annotations, e.g. for a cloud load balancer. |
| `kodoffice.service.nodePort` | integer / string | `""` | Fixed node port for type NodePort/LoadBalancer; empty lets Kubernetes assign one. |
| `kodoffice.service.loadBalancerSourceRanges` | array | `[]` | Client CIDRs allowed to reach a LoadBalancer Service. |
| `kodoffice.resources` | object | `{"requests": {"cpu": "500m", "memory": "1Gi"}, "limits": ...` | Kubernetes resource requests and limits for KodOffice. |
| `kodoffice.nodeSelector` | object | `{}` | Node labels for scheduling KodOffice. |
| `kodoffice.tolerations` | array | `[]` | Tolerations for KodOffice pods. |
| `kodoffice.affinity` | object | `{}` | Affinity rules for KodOffice pods. |
| `kodoffice.podAnnotations` | object | `{}` | Extra annotations for KodOffice pods. |
| `kodoffice.podLabels` | object | `{}` | Extra labels for KodOffice pods. |
| `kodoffice.priorityClassName` | string | `""` | PriorityClass for KodOffice pods. |
| `kodoffice.topologySpreadConstraints` | array | `[]` | Topology spread constraints for KodOffice pods; a missing labelSelector is filled with the pod's labels. |
| `kodoffice.extraEnv` | array | `[]` | Extra environment variables for the KodOffice container. |
| `kodoffice.livenessProbe` | object | `{}` | Liveness probe override for KodOffice, merged over the chart default; enabled: false removes it. |
| `kodoffice.readinessProbe` | object | `{}` | Readiness probe override for KodOffice, merged over the chart default; enabled: false removes it. |
| `kodoffice.startupProbe` | object | `{}` | Startup probe override for KodOffice, merged over the chart default; enabled: false removes it. |
| `kodoffice.podSecurityContext` | object | `{"seccompProfile": {"type": "RuntimeDefault"}}` | Pod security context for KodOffice pods. |
| `kodoffice.securityContext` | object | `{}` | Container security context for KodOffice containers. |
| `kodoffice.extraVolumes` | array | `[]` | Extra volumes on the KodOffice pod. |
| `kodoffice.extraVolumeMounts` | array | `[]` | Extra volume mounts on the KodOffice container, pairing with extraVolumes. |
| `kodoffice.extraContainers` | array | `[]` | Extra sidecar containers in the KodOffice pod, e.g. a Prometheus exporter. |

### imaginary

Imaginary thumbnail / image processing service.

| Key | Type | Default | Description |
|---|---|---|---|
| `imaginary.enabled` | boolean | `true` | Deploy Imaginary. |
| `imaginary.image.registry` | string | `"docker.io"` | Image registry; global.imageRegistry overrides it. |
| `imaginary.image.repository` | string | `"nextcloud/aio-imaginary"` | Image repository, without the registry (one that starts with a registry host is used as-is). |
| `imaginary.image.tag` | string / number | `"20260929_105435"` | Image tag. |
| `imaginary.image.digest` | string | `""` | Image digest (sha256:...) to pin a build; used together with the tag. |
| `imaginary.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `imaginary.port` | integer | `9000` | Container port. |
| `imaginary.args` | array | `["-enable-url-source", "-concurrency", "10", "-max-allowe...` | Extra container arguments for Imaginary. |
| `imaginary.service.port` | integer | `9000` | Service port. |
| `imaginary.service.annotations` | object | `{}` | Service annotations, e.g. for a cloud load balancer. |
| `imaginary.resources` | object | `{"requests": {"cpu": "100m", "memory": "128Mi"}, "limits"...` | Kubernetes resource requests and limits for Imaginary. |
| `imaginary.nodeSelector` | object | `{}` | Node labels for scheduling Imaginary. |
| `imaginary.tolerations` | array | `[]` | Tolerations for Imaginary pods. |
| `imaginary.affinity` | object | `{}` | Affinity rules for Imaginary pods. |
| `imaginary.podAnnotations` | object | `{}` | Extra annotations for Imaginary pods. |
| `imaginary.podLabels` | object | `{}` | Extra labels for Imaginary pods. |
| `imaginary.priorityClassName` | string | `""` | PriorityClass for Imaginary pods. |
| `imaginary.topologySpreadConstraints` | array | `[]` | Topology spread constraints for Imaginary pods; a missing labelSelector is filled with the pod's labels. |
| `imaginary.extraEnv` | array | `[]` | Extra environment variables for the Imaginary container. |
| `imaginary.livenessProbe` | object | `{}` | Liveness probe override for Imaginary, merged over the chart default; enabled: false removes it. |
| `imaginary.readinessProbe` | object | `{}` | Readiness probe override for Imaginary, merged over the chart default; enabled: false removes it. |
| `imaginary.startupProbe` | object | `{}` | Startup probe override for Imaginary, merged over the chart default; enabled: false removes it. |
| `imaginary.podSecurityContext` | object | `{"runAsNonRoot": true, "runAsUser": 65534, "runAsGroup": ...` | Pod security context for Imaginary pods. |
| `imaginary.securityContext` | object | `{"allowPrivilegeEscalation": false, "capabilities": {"dro...` | Container security context for Imaginary containers. |
| `imaginary.extraVolumes` | array | `[]` | Extra volumes on the Imaginary pod. |
| `imaginary.extraVolumeMounts` | array | `[]` | Extra volume mounts on the Imaginary container, pairing with extraVolumes. |
| `imaginary.extraContainers` | array | `[]` | Extra sidecar containers in the Imaginary pod, e.g. a Prometheus exporter. |

### milvus

Milvus vector database stack (etcd + RustFS object storage + milvus standalone) for AI search.

| Key | Type | Default | Description |
|---|---|---|---|
| `milvus.enabled` | boolean | `false` | Deploy etcd, RustFS (the minio component) and milvus. |
| `milvus.etcd.image.registry` | string | `"quay.io"` | Image registry; global.imageRegistry overrides it. |
| `milvus.etcd.image.repository` | string | `"coreos/etcd"` | Image repository, without the registry (one that starts with a registry host is used as-is). |
| `milvus.etcd.image.tag` | string / number | `"v3.5.34"` | Image tag. |
| `milvus.etcd.image.digest` | string | `""` | Image digest (sha256:...) to pin a build; used together with the tag. |
| `milvus.etcd.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `milvus.etcd.env` | object | `{"ETCD_AUTO_COMPACTION_MODE": "revision", "ETCD_AUTO_COMP...` | Environment variables for etcd, as NAME: value. |
| `milvus.etcd.persistence.storageClass` | string | `""` | Storage class; empty uses the cluster default. |
| `milvus.etcd.persistence.accessModes` | array | `["ReadWriteOnce"]` | PersistentVolumeClaim access modes. |
| `milvus.etcd.persistence.size` | string | `"4Gi"` | Volume size for etcd data. |
| `milvus.etcd.resources` | object | `{"requests": {"cpu": "100m", "memory": "256Mi"}, "limits"...` | Kubernetes resource requests and limits for etcd. |
| `milvus.etcd.nodeSelector` | object | `{}` | Node labels for scheduling etcd. |
| `milvus.etcd.tolerations` | array | `[]` | Tolerations for etcd pods. |
| `milvus.etcd.affinity` | object | `{}` | Affinity rules for etcd pods. |
| `milvus.etcd.podAnnotations` | object | `{}` | Extra annotations for etcd pods. |
| `milvus.etcd.podLabels` | object | `{}` | Extra labels for etcd pods. |
| `milvus.etcd.priorityClassName` | string | `""` | PriorityClass for etcd pods. |
| `milvus.etcd.topologySpreadConstraints` | array | `[]` | Topology spread constraints for etcd pods; a missing labelSelector is filled with the pod's labels. |
| `milvus.etcd.extraEnv` | array | `[]` | Extra environment variables for the etcd container. |
| `milvus.etcd.livenessProbe` | object | `{}` | Liveness probe override for etcd, merged over the chart default; enabled: false removes it. |
| `milvus.etcd.readinessProbe` | object | `{}` | Readiness probe override for etcd, merged over the chart default; enabled: false removes it. |
| `milvus.etcd.startupProbe` | object | `{}` | Startup probe override for etcd, merged over the chart default; enabled: false removes it. |
| `milvus.etcd.podSecurityContext` | object | `{"seccompProfile": {"type": "RuntimeDefault"}}` | Pod security context for etcd pods. |
| `milvus.etcd.securityContext` | object | `{}` | Container security context for etcd containers. |
| `milvus.etcd.extraVolumes` | array | `[]` | Extra volumes on the etcd pod. |
| `milvus.etcd.extraVolumeMounts` | array | `[]` | Extra volume mounts on the etcd container, pairing with extraVolumes. |
| `milvus.etcd.extraContainers` | array | `[]` | Extra sidecar containers in the etcd pod, e.g. a Prometheus exporter. |
| `milvus.minio.image.registry` | string | `"docker.io"` | Image registry; global.imageRegistry overrides it. |
| `milvus.minio.image.repository` | string | `"rustfs/rustfs"` | Image repository, without the registry (one that starts with a registry host is used as-is). |
| `milvus.minio.image.tag` | string / number | `"1.0.1"` | Image tag. |
| `milvus.minio.image.digest` | string | `""` | Image digest (sha256:...) to pin a build; used together with the tag. |
| `milvus.minio.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `milvus.minio.rootUser` | string | `"minioadmin"` | RustFS access key (RUSTFS_ACCESS_KEY), also used by Milvus. |
| `milvus.minio.rootPassword` | string | `""` | RustFS secret key (RUSTFS_SECRET_KEY); empty generates one. At least 8 characters. |
| `milvus.minio.existingSecret` | string | `""` | Existing secret with MINIO_ROOT_USER and MINIO_ROOT_PASSWORD, used instead of rootUser/rootPassword. |
| `milvus.minio.persistence.storageClass` | string | `""` | Storage class; empty uses the cluster default. |
| `milvus.minio.persistence.accessModes` | array | `["ReadWriteOnce"]` | PersistentVolumeClaim access modes. |
| `milvus.minio.persistence.size` | string | `"8Gi"` | Volume size for RustFS data. |
| `milvus.minio.resources` | object | `{"requests": {"cpu": "100m", "memory": "256Mi"}, "limits"...` | Kubernetes resource requests and limits for RustFS. |
| `milvus.minio.nodeSelector` | object | `{}` | Node labels for scheduling RustFS. |
| `milvus.minio.tolerations` | array | `[]` | Tolerations for RustFS pods. |
| `milvus.minio.affinity` | object | `{}` | Affinity rules for RustFS pods. |
| `milvus.minio.podAnnotations` | object | `{}` | Extra annotations for RustFS pods. |
| `milvus.minio.podLabels` | object | `{}` | Extra labels for RustFS pods. |
| `milvus.minio.priorityClassName` | string | `""` | PriorityClass for RustFS pods. |
| `milvus.minio.topologySpreadConstraints` | array | `[]` | Topology spread constraints for RustFS pods; a missing labelSelector is filled with the pod's labels. |
| `milvus.minio.extraEnv` | array | `[]` | Extra environment variables for the RustFS container. |
| `milvus.minio.livenessProbe` | object | `{}` | Liveness probe override for RustFS, merged over the chart default; enabled: false removes it. |
| `milvus.minio.readinessProbe` | object | `{}` | Readiness probe override for RustFS, merged over the chart default; enabled: false removes it. |
| `milvus.minio.startupProbe` | object | `{}` | Startup probe override for RustFS, merged over the chart default; enabled: false removes it. |
| `milvus.minio.podSecurityContext` | object | `{"runAsNonRoot": true, "runAsUser": 10001, "runAsGroup": ...` | Pod security context for RustFS pods. |
| `milvus.minio.securityContext` | object | `{"allowPrivilegeEscalation": false, "capabilities": {"dro...` | Container security context for RustFS containers. |
| `milvus.minio.extraVolumes` | array | `[]` | Extra volumes on the RustFS pod. |
| `milvus.minio.extraVolumeMounts` | array | `[]` | Extra volume mounts on the RustFS container, pairing with extraVolumes. |
| `milvus.minio.extraContainers` | array | `[]` | Extra sidecar containers in the RustFS pod, e.g. a Prometheus exporter. |
| `milvus.standalone.image.registry` | string | `"docker.io"` | Image registry; global.imageRegistry overrides it. |
| `milvus.standalone.image.repository` | string | `"milvusdb/milvus"` | Image repository, without the registry (one that starts with a registry host is used as-is). |
| `milvus.standalone.image.tag` | string / number | `"v2.6.25"` | Image tag. |
| `milvus.standalone.image.digest` | string | `""` | Image digest (sha256:...) to pin a build; used together with the tag. |
| `milvus.standalone.image.pullPolicy` | "Always" \| "IfNotPresent" \| "Never" | `"IfNotPresent"` | Image pull policy. |
| `milvus.standalone.mqType` | "woodpecker" \| "rocksmq" \| "pulsar" \| "kafka" | `"woodpecker"` | Milvus message queue. |
| `milvus.standalone.service.type` | "ClusterIP" \| "NodePort" \| "LoadBalancer" | `"ClusterIP"` | Service type. |
| `milvus.standalone.service.port` | integer | `19530` | gRPC port. |
| `milvus.standalone.service.metricsPort` | integer | `9091` | Metrics / health port. |
| `milvus.standalone.service.annotations` | object | `{}` | Service annotations, e.g. for a cloud load balancer. |
| `milvus.standalone.service.loadBalancerSourceRanges` | array | `[]` | Client CIDRs allowed to reach a LoadBalancer Service. |
| `milvus.standalone.persistence.storageClass` | string | `""` | Storage class; empty uses the cluster default. |
| `milvus.standalone.persistence.accessModes` | array | `["ReadWriteOnce"]` | PersistentVolumeClaim access modes. |
| `milvus.standalone.persistence.size` | string | `"8Gi"` | Volume size for Milvus data. |
| `milvus.standalone.resources` | object | `{"requests": {"cpu": "500m", "memory": "2Gi"}, "limits": ...` | Kubernetes resource requests and limits for Milvus. |
| `milvus.standalone.nodeSelector` | object | `{}` | Node labels for scheduling Milvus. |
| `milvus.standalone.tolerations` | array | `[]` | Tolerations for Milvus pods. |
| `milvus.standalone.affinity` | object | `{}` | Affinity rules for Milvus pods. |
| `milvus.standalone.podAnnotations` | object | `{}` | Extra annotations for Milvus pods. |
| `milvus.standalone.podLabels` | object | `{}` | Extra labels for Milvus pods. |
| `milvus.standalone.priorityClassName` | string | `""` | PriorityClass for Milvus pods. |
| `milvus.standalone.topologySpreadConstraints` | array | `[]` | Topology spread constraints for Milvus pods; a missing labelSelector is filled with the pod's labels. |
| `milvus.standalone.extraEnv` | array | `[]` | Extra environment variables for the Milvus container. |
| `milvus.standalone.livenessProbe` | object | `{}` | Liveness probe override for Milvus, merged over the chart default; enabled: false removes it. |
| `milvus.standalone.readinessProbe` | object | `{}` | Readiness probe override for Milvus, merged over the chart default; enabled: false removes it. |
| `milvus.standalone.startupProbe` | object | `{}` | Startup probe override for Milvus, merged over the chart default; enabled: false removes it. |
| `milvus.standalone.podSecurityContext` | object | `{"seccompProfile": {"type": "RuntimeDefault"}}` | Pod security context for Milvus pods. |
| `milvus.standalone.securityContext` | object | `{}` | Container security context for Milvus containers. |
| `milvus.standalone.extraVolumes` | array | `[]` | Extra volumes on the Milvus pod. |
| `milvus.standalone.extraVolumeMounts` | array | `[]` | Extra volume mounts on the Milvus container, pairing with extraVolumes. |
| `milvus.standalone.extraContainers` | array | `[]` | Extra sidecar containers in the Milvus pod, e.g. a Prometheus exporter. |

### networkPolicy

NetworkPolicies restricting access to the backing services.

| Key | Type | Default | Description |
|---|---|---|---|
| `networkPolicy.enabled` | boolean | `true` | Create the NetworkPolicies. |
| `networkPolicy.milvusExtraFrom` | array | `[]` | Extra NetworkPolicy 'from' peers allowed to reach Milvus. |

### gateway

Gateway API routing (HTTPRoutes, optionally a dedicated Gateway).

| Key | Type | Default | Description |
|---|---|---|---|
| `gateway.enabled` | boolean | `false` | Create HTTPRoutes. |
| `gateway.parentRefs` | array | `[{"name": "gateway", "namespace": "gateway", "sectionName...` | Existing Gateway listeners to attach to (when create=false). |
| `gateway.httpsRedirect.enabled` | boolean | `true` | Attach a redirect route to the Gateway's HTTP listener. |
| `gateway.httpsRedirect.sectionName` | string | `"http"` | HTTP listener name on the existing Gateway. |
| `gateway.create` | boolean | `false` | Deploy a dedicated Gateway instead of attaching to an existing one. |
| `gateway.className` | string | `"cilium"` | GatewayClass for the dedicated Gateway. |
| `gateway.gatewayAnnotations` | object | `{}` | Annotations for the dedicated Gateway. |
| `gateway.tlsSecretName` | string | `""` | TLS secret for the dedicated Gateway's HTTPS listeners. |
| `gateway.routeAnnotations` | object | `{}` | Annotations for the HTTPRoutes. |
| `gateway.app.hostnames` | array | `["kodbox.example.com"]` | Hostnames for kodbox. |
| `gateway.kodoffice.hostnames` | array | `["kodoffice.example.com"]` | Hostnames for KodOffice; [] skips the route. |
| `gateway.timeouts.request` | string |  | Gateway API request timeout, e.g. 3600s. |
| `gateway.timeouts.backendRequest` | string |  | Gateway API backendRequest timeout. |

### ingress

Ingress routing, for clusters with an Ingress controller.

| Key | Type | Default | Description |
|---|---|---|---|
| `ingress.enabled` | boolean | `false` | Create the Ingress. |
| `ingress.className` | string | `""` | IngressClass name. |
| `ingress.annotations` | object | `{}` | Ingress annotations. |
| `ingress.app.host` | string | `"kodbox.example.com"` | Hostname for kodbox. |
| `ingress.kodoffice.host` | string | `""` | Hostname for KodOffice; empty skips it. |
| `ingress.tls` | array | `[]` | Ingress TLS entries. |

<!-- values:end -->
