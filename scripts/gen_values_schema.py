"""Generates charts/kodbox/values.schema.json.

Run after changing values.yaml: python3 scripts/gen_values_schema.py
"""
import json
import pathlib

QUANTITY = r"^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|Pi|Ei|k|M|G|T|P|E)?$"


def obj(desc, props, strict=True, **extra):
    o = {"type": "object", "description": desc, "properties": props}
    if strict:
        o["additionalProperties"] = False
    o.update(extra)
    return o


def s(desc, **extra):
    return {"type": "string", "description": desc, **extra}


def b(desc):
    return {"type": "boolean", "description": desc}


def port(desc):
    return {"type": "integer", "minimum": 1, "maximum": 65535, "description": desc}


def free(desc, typ="object"):
    return {"type": typ, "description": desc}


def image(what):
    return obj(f"Container image for {what}.", {
        "registry": s("Image registry; global.imageRegistry overrides it."),
        "repository": s("Image repository, without the registry (one that starts with a registry host is used as-is)."),
        "tag": {"type": ["string", "number"], "description": "Image tag."},
        "digest": s("Image digest (sha256:...) to pin a build; used together with the tag.", pattern="^(sha256:[a-f0-9]{64})?$"),
        "pullPolicy": {"type": "string", "enum": ["Always", "IfNotPresent", "Never"], "description": "Image pull policy."},
    }, required=["repository"])


def resources(what):
    return free(f"Kubernetes resource requests and limits for {what}.")


ENV = {
    "type": "array",
    "items": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
}


def sched(what):
    return {
        "nodeSelector": free(f"Node labels for scheduling {what}."),
        "tolerations": free(f"Tolerations for {what} pods.", "array"),
        "affinity": free(f"Affinity rules for {what} pods."),
        "podAnnotations": free(f"Extra annotations for {what} pods."),
        "podLabels": free(f"Extra labels for {what} pods."),
        "priorityClassName": s(f"PriorityClass for {what} pods."),
        "topologySpreadConstraints": free(f"Topology spread constraints for {what} pods; a missing labelSelector is filled with the pod's labels.", "array"),
        "extraEnv": ENV | {"description": f"Extra environment variables for the {what} container."},
        "podSecurityContext": free(f"Pod security context for {what} pods."),
        "securityContext": free(f"Container security context for {what} containers."),
    }


ACCESS_MODES = {
    "type": "array",
    "minItems": 1,
    "items": {"type": "string", "enum": ["ReadWriteOnce", "ReadOnlyMany", "ReadWriteMany", "ReadWriteOncePod"]},
    "description": "PersistentVolumeClaim access modes.",
}


def persistence(what, mount, toggle=False, extra=None):
    props = {
        "storageClass": s("Storage class; empty uses the cluster default."),
        "accessModes": ACCESS_MODES,
        "size": s(f"Volume size for {what}.", pattern=QUANTITY),
    }
    if toggle:
        props = {"enabled": b(f"Persist {what} on a PersistentVolumeClaim; false uses an emptyDir.")} | props
    props |= extra or {}
    return obj(f"Storage for {what}, mounted at {mount}.", props)


def args(what):
    return {"type": "array", "items": {"type": "string"}, "description": f"Extra container arguments for {what}."}


SERVICE_TYPE = {"type": "string", "enum": ["ClusterIP", "NodePort", "LoadBalancer"], "description": "Service type."}

HOSTNAMES = {"type": "array", "items": {"type": "string", "format": "hostname"}}

schema = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "title": "kodbox",
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "global": obj("Global values, shared with parent charts.", {
            "imageRegistry": s("Registry for every image (a mirror or pull-through cache); overrides each image's registry."),
        }, strict=False),
        "timezone": s("IANA time zone for every component (e.g. Asia/Shanghai); sets TZ and PHP's date.timezone. Empty keeps UTC.", pattern="^([A-Za-z_]+(/[A-Za-z0-9_+-]+)*)?$"),
        "nameOverride": s("Override the chart name used in resource names."),
        "fullnameOverride": s("Override the full resource name prefix."),
        "imagePullSecrets": {
            "type": "array",
            "description": "Image pull secrets for all pods.",
            "items": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
        },
        "serviceAccount": obj("ServiceAccount shared by all pods.", {
            "create": b("Create the ServiceAccount."),
            "name": s("ServiceAccount name; defaults to the release's full name, or \"default\" when create=false."),
            "annotations": free("ServiceAccount annotations."),
            "automountServiceAccountToken": b("Mount the API token into pods; no component needs it."),
        }),
        "app": obj("Kodbox application (nginx + php-fpm, port 80).", {
            "image": image("kodbox"),
            "replicaCount": {"type": "integer", "minimum": 0, "description": "App replicas. Install with 1; more than 1 needs a ReadWriteMany volume."},
            "podAntiAffinity": {"type": "string", "enum": ["soft", "hard", "none"], "description": "Spread replicas across nodes. Ignored when app.affinity is set."},
            "autoscaling": obj("HorizontalPodAutoscaler for the app (needs metrics-server); replaces replicaCount.", {
                "enabled": b("Create the HorizontalPodAutoscaler."),
                "minReplicas": {"type": "integer", "minimum": 1, "description": "Minimum replicas."},
                "maxReplicas": {"type": "integer", "minimum": 1, "description": "Maximum replicas."},
                "targetCPUUtilizationPercentage": {"type": ["integer", "string"], "pattern": "^$", "minimum": 1, "description": "Average CPU utilization target (% of requests); empty disables."},
                "targetMemoryUtilizationPercentage": {"type": ["integer", "string"], "pattern": "^$", "minimum": 1, "description": "Average memory utilization target (% of requests); empty disables."},
                "behavior": free("HPA scaling behavior (scaleUp / scaleDown policies)."),
            }),
            "pdb": obj("PodDisruptionBudget, created only when more than one replica must run.", {
                "enabled": b("Create the PodDisruptionBudget."),
                "minAvailable": {"type": ["integer", "string"], "description": "Minimum available pods (number or percentage)."},
            }),
            "strategy": obj("Deployment update strategy.", {
                "type": {"type": "string", "enum": ["Recreate", "RollingUpdate"], "description": "Recreate for ReadWriteOnce volumes, RollingUpdate for ReadWriteMany."},
                "rollingUpdate": free("RollingUpdate parameters (maxSurge, maxUnavailable)."),
            }),
            "service": obj("App Service.", {"type": SERVICE_TYPE, "port": port("Service port.")}),
            "persistence": persistence("the kodbox site and user files", "/var/www/html", toggle=True, extra={
                "existingClaim": s("Use an existing PersistentVolumeClaim instead of creating one."),
                "annotations": free("Extra PVC annotations, e.g. for pvc-autoresizer."),
            }),
            "waitForDependencies": b("Wait for the database and redis to accept connections before starting kodbox."),
            "resources": resources("the app"),
            **sched("the app"),
        }),
        "admin": obj("Initial kodbox admin account, applied only on the very first start.", {
            "bootstrap": b("Create the admin account on first start; false lets the first visitor create it."),
            "username": s("Admin username."),
            "password": {
                "type": "string",
                "description": "Admin password; empty generates one. 8+ characters using 3 of digits, upper, lower and ~!@#$%^&*; no \" $ ` or \\.",
                "anyOf": [{"maxLength": 0}, {"minLength": 8, "pattern": "^[^\"$`\\\\]*$"}],
            },
            "existingSecret": s("Existing secret with KODBOX_ADMIN_USER and KODBOX_ADMIN_PASSWORD."),
        }),
        "database": obj("Database credentials shared by the db and app containers.", {
            "name": s("Database name.", minLength=1),
            "user": s("Database user.", minLength=1),
            "password": s("Database password; empty generates one."),
            "rootPassword": s("Database root password; empty generates one."),
            "existingSecret": s("Existing secret with MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD and MYSQL_ROOT_PASSWORD."),
        }),
        "db": obj("Bundled MariaDB. Set enabled=false and fill externalDatabase to use your own.", {
            "enabled": b("Deploy the bundled MariaDB."),
            "image": image("MariaDB"),
            "args": args("MariaDB"),
            "service": obj("MariaDB Service.", {"port": port("Service port.")}),
            "persistence": persistence("MariaDB data", "/var/lib/mysql"),
            "resources": resources("MariaDB"),
            **sched("MariaDB"),
        }),
        "externalDatabase": obj("External MySQL/MariaDB, used when db.enabled=false.", {
            "host": s("Database host."),
            "port": port("Database port."),
        }),
        "redis": obj("Bundled Redis for kodbox sessions and cache.", {
            "enabled": b("Deploy the bundled Redis."),
            "image": image("Redis"),
            "args": args("redis-server"),
            "service": obj("Redis Service.", {"port": port("Service port.")}),
            "persistence": persistence("Redis append-only data", "/data", toggle=True),
            "resources": resources("Redis"),
            **sched("Redis"),
        }),
        "externalRedis": obj("External Redis, used when redis.enabled=false. Empty host disables Redis. Applied on kodbox's first start only; must listen on 6379.", {
            "host": s("Redis host."),
            "password": s("Redis password."),
            "existingSecret": s("Existing secret holding the Redis password."),
            "existingSecretKey": s("Key of the password in existingSecret.", minLength=1),
        }),
        "kodoffice": obj("KodOffice document server. Browsers load it directly, so it needs a user-reachable URL.", {
            "enabled": b("Deploy KodOffice."),
            "image": image("KodOffice"),
            "service": obj("KodOffice Service.", {"type": SERVICE_TYPE, "port": port("Service port.")}),
            "resources": resources("KodOffice"),
            **sched("KodOffice"),
        }),
        "imaginary": obj("Imaginary thumbnail / image processing service.", {
            "enabled": b("Deploy Imaginary."),
            "image": image("Imaginary"),
            "port": port("Container port."),
            "args": args("Imaginary"),
            "service": obj("Imaginary Service.", {"port": port("Service port.")}),
            "resources": resources("Imaginary"),
            **sched("Imaginary"),
        }),
        "milvus": obj("Milvus vector database stack (etcd + minio + milvus standalone) for AI search.", {
            "enabled": b("Deploy etcd, minio and milvus."),
            "etcd": obj("etcd for Milvus metadata.", {
                "image": image("etcd"),
                "env": {
                    "type": "object",
                    "description": "Environment variables for etcd, as NAME: value.",
                    "additionalProperties": {"type": ["string", "number", "boolean"]},
                },
                "persistence": persistence("etcd data", "/etcd"),
                "resources": resources("etcd"),
                **sched("etcd"),
            }),
            "minio": obj("MinIO object storage for Milvus segments.", {
                "image": image("MinIO"),
                "rootUser": s("MinIO root user.", minLength=3),
                "rootPassword": s("MinIO root password; empty generates one. At least 8 characters.", anyOf=[{"maxLength": 0}, {"minLength": 8}]),
                "persistence": persistence("MinIO data", "/minio_data"),
                "resources": resources("MinIO"),
                **sched("MinIO"),
            }),
            "standalone": obj("Milvus standalone server.", {
                "image": image("Milvus"),
                "mqType": {"type": "string", "enum": ["woodpecker", "rocksmq", "pulsar", "kafka"], "description": "Milvus message queue."},
                "service": obj("Milvus Service.", {
                    "type": SERVICE_TYPE,
                    "port": port("gRPC port."),
                    "metricsPort": port("Metrics / health port."),
                }),
                "persistence": persistence("Milvus data", "/var/lib/milvus"),
                "resources": resources("Milvus"),
                **sched("Milvus"),
            }),
        }),
        "networkPolicy": obj("NetworkPolicies restricting access to the backing services.", {
            "enabled": b("Create the NetworkPolicies."),
            "milvusExtraFrom": free("Extra NetworkPolicy 'from' peers allowed to reach Milvus.", "array"),
        }),
        "gateway": obj("Gateway API routing (HTTPRoutes, optionally a dedicated Gateway).", {
            "enabled": b("Create HTTPRoutes."),
            "parentRefs": {
                "type": "array",
                "description": "Existing Gateway listeners to attach to (when create=false).",
                "items": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
            },
            "httpsRedirect": obj("HTTP to HTTPS redirect routes.", {
                "enabled": b("Attach a redirect route to the Gateway's HTTP listener."),
                "sectionName": s("HTTP listener name on the existing Gateway."),
            }),
            "create": b("Deploy a dedicated Gateway instead of attaching to an existing one."),
            "className": s("GatewayClass for the dedicated Gateway."),
            "gatewayAnnotations": free("Annotations for the dedicated Gateway."),
            "tlsSecretName": s("TLS secret for the dedicated Gateway's HTTPS listeners."),
            "routeAnnotations": free("Annotations for the HTTPRoutes."),
            "app": obj("Kodbox route.", {"hostnames": HOSTNAMES | {"minItems": 1, "description": "Hostnames for kodbox."}}),
            "kodoffice": obj("KodOffice route.", {"hostnames": HOSTNAMES | {"description": "Hostnames for KodOffice; [] skips the route."}}),
            "timeouts": obj("HTTPRoute rule timeouts.", {
                "request": s("Gateway API request timeout, e.g. 3600s."),
                "backendRequest": s("Gateway API backendRequest timeout."),
            }),
        }),
        "ingress": obj("Ingress routing, for clusters with an Ingress controller.", {
            "enabled": b("Create the Ingress."),
            "className": s("IngressClass name."),
            "annotations": free("Ingress annotations."),
            "app": obj("Kodbox host.", {"host": s("Hostname for kodbox.")}),
            "kodoffice": obj("KodOffice host.", {"host": s("Hostname for KodOffice; empty skips it.")}),
            "tls": {
                "type": "array",
                "description": "Ingress TLS entries.",
                "items": {"type": "object", "properties": {
                    "secretName": {"type": "string"},
                    "hosts": {"type": "array", "items": {"type": "string"}},
                }},
            },
        }),
    },
    "allOf": [
        {
            "if": {"properties": {"db": {"properties": {"enabled": {"const": False}}}}},
            "then": {"properties": {"externalDatabase": {"properties": {"host": {"minLength": 1}}}}},
        },
    ],
}

out = pathlib.Path(__file__).resolve().parent.parent / "charts" / "kodbox" / "values.schema.json"
out.write_text(json.dumps(schema, indent=2) + "\n")
print(f"wrote {out}")
