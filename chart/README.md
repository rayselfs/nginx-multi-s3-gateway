# nginx-multi-s3-gateway Helm Chart

Helm chart for deploying [nginx-multi-s3-gateway](https://github.com/rayselfs/nginx-multi-s3-gateway) — a production-ready NGINX reverse proxy with dynamic multi-bucket S3 routing.

## TL;DR

```bash
helm install my-gateway \
  oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway \
  --version 0.1.1 \
  --namespace my-namespace \
  --create-namespace \
  --set s3.bucketName=my-default-bucket \
  --set s3.region=ap-northeast-1
```

## Introduction

This chart deploys a multi-bucket NGINX S3 gateway on a Kubernetes cluster. Key features:

- **Dynamic routing** via `X-S3-Bucket` request header — no redeployment required to route between buckets
- **Bucket whitelist** — clients cannot access arbitrary buckets; unlisted values fall back to the default bucket
- **Zero-downtime bucket updates** — `helm upgrade` re-renders the ConfigMap and triggers a rolling restart via `checksum/config` annotation
- **EKS Pod Identity / IRSA native** — no static AWS credentials needed on EKS
- **Optional metrics** — nginx-prometheus-exporter sidecar + ServiceMonitor

## Prerequisites

- Kubernetes 1.25+
- Helm 3.10+

> **Private registry only**: if the GHCR package is private, authenticate first:
> ```bash
> echo $GITHUB_TOKEN | helm registry login ghcr.io --username <username> --password-stdin
> ```

## Installing the Chart

### Minimum (EKS Pod Identity)

```bash
cat > values.yaml <<'EOF'
s3:
  bucketName: my-default-bucket
  region: ap-northeast-1
EOF

helm install my-gateway \
  oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway \
  --version 0.1.1 \
  --namespace my-namespace \
  --create-namespace \
  -f values.yaml
```

> AWS permissions are provided via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) association — no ServiceAccount annotation required.

### Minimum (IRSA on EKS)

```bash
cat > values.yaml <<'EOF'
s3:
  bucketName: my-default-bucket
  region: ap-northeast-1

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/nginx-s3-gateway-role
EOF

helm install my-gateway \
  oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway \
  --version 0.1.1 \
  --namespace my-namespace \
  --create-namespace \
  -f values.yaml
```

### With Multi-bucket Routing

```yaml
# values.yaml
s3:
  bucketName: my-default-bucket
  region: ap-northeast-1

buckets:
  - name: bucket-prod
  - name: bucket-staging
  - name: bucket-assets
```

Clients route to a specific bucket via header:

```bash
curl -H "X-S3-Bucket: bucket-prod" https://my-gateway.example.com/path/to/object
```

### With Static Credentials (non-EKS)

```bash
kubectl create secret generic aws-creds \
  --namespace my-namespace \
  --from-literal=AWS_ACCESS_KEY_ID=AKIA... \
  --from-literal=AWS_SECRET_ACCESS_KEY=...
```

```yaml
# values.yaml
s3:
  bucketName: my-default-bucket
  region: us-east-1
  existingSecret: aws-creds
```

## Upgrading

### Adding or removing buckets

Edit the `buckets` list in your `values.yaml`, then:

```bash
helm upgrade my-gateway \
  oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway \
  --version 0.1.1 \
  --namespace my-namespace \
  -f values.yaml
```

The `checksum/config` annotation on the Deployment detects the ConfigMap change and triggers a rolling restart automatically.

### Upgrading the chart version

```bash
helm upgrade my-gateway \
  oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway \
  --version <new-version> \
  --namespace my-namespace \
  -f values.yaml
```

## Configuration

### Required

| Parameter | Description |
|---|---|
| `s3.bucketName` | Default S3 bucket (fallback when no `X-S3-Bucket` header). **Must be set.** |

### S3 / AWS

| Parameter | Default | Description |
|---|---|---|
| `s3.bucketName` | `""` | **Required.** Default/fallback bucket name |
| `s3.server` | `s3.amazonaws.com` | S3 endpoint hostname |
| `s3.serverPort` | `443` | S3 endpoint port |
| `s3.serverProto` | `https` | `https` or `http` |
| `s3.region` | `us-east-1` | AWS region |
| `s3.style` | `virtual` | URL style: `virtual` / `virtual-v2` / `path` |
| `s3.existingSecret` | `""` | Secret name with `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` |
| `aws.sigVersion` | `"4"` | AWS Signature version (`"4"` or `"2"`) |

#### S3 Style Guide

| Style | Host header | When to use |
|---|---|---|
| `virtual` | `<bucket>.s3.amazonaws.com` | Standard AWS S3 (recommended) |
| `virtual-v2` | `<bucket>.s3.amazonaws.com:443` | Non-standard S3-compatible APIs requiring explicit port |
| `path` | `s3.amazonaws.com:443` | Path-style access, legacy, or VPC gateway endpoints |

### Bucket Routing

| Parameter | Default | Description |
|---|---|---|
| `buckets` | `[]` | Bucket whitelist. Each entry: `{name: "bucket-name"}` |

### Workload

| Parameter | Default | Description |
|---|---|---|
| `replicaCount` | `2` | Pod replicas (ignored when HPA is enabled) |
| `image.repository` | `ghcr.io/rayselfs/nginx-multi-s3-gateway` | Container image |
| `image.tag` | `""` | Tag override (defaults to `Chart.appVersion`) |
| `image.pullPolicy` | `IfNotPresent` | `Always` / `IfNotPresent` / `Never` |
| `resources.limits.cpu` | `500m` | CPU limit |
| `resources.limits.memory` | `256Mi` | Memory limit |
| `resources.requests.cpu` | `100m` | CPU request |
| `resources.requests.memory` | `128Mi` | Memory request |

### ServiceAccount

| Parameter | Default | Description |
|---|---|---|
| `serviceAccount.create` | `true` | Create a dedicated ServiceAccount |
| `serviceAccount.annotations` | `{}` | Optional annotations — set `eks.amazonaws.com/role-arn` here for IRSA; not required for EKS Pod Identity |
| `serviceAccount.name` | `""` | Override SA name (auto-generated if empty) |

### Service & Ingress

| Parameter | Default | Description |
|---|---|---|
| `service.type` | `ClusterIP` | `ClusterIP` / `NodePort` / `LoadBalancer` |
| `service.port` | `80` | Service port |
| `ingress.enabled` | `false` | Create an Ingress resource |
| `ingress.className` | `""` | IngressClass name |
| `ingress.annotations` | `{}` | Ingress annotations |
| `ingress.hosts` | `[{host: chart-example.local, ...}]` | Ingress host rules |
| `ingress.tls` | `[]` | TLS configuration |

### Autoscaling & Availability

| Parameter | Default | Description |
|---|---|---|
| `autoscaling.enabled` | `false` | Enable HorizontalPodAutoscaler |
| `autoscaling.minReplicas` | `2` | HPA minimum replicas |
| `autoscaling.maxReplicas` | `10` | HPA maximum replicas |
| `autoscaling.targetCPUUtilizationPercentage` | `80` | HPA CPU target |
| `pdb.enabled` | `true` | Enable PodDisruptionBudget |
| `pdb.minAvailable` | `1` | Minimum available pods during disruption |

### NGINX Tuning

| Parameter | Default | Description |
|---|---|---|
| `nginx.proxyCacheValidOk` | `1h` | Cache TTL for 2xx/3xx responses |
| `nginx.proxyCacheValidNotfound` | `1m` | Cache TTL for 404 |
| `nginx.proxyCacheValidForbidden` | `30s` | Cache TTL for 403 |
| `nginx.corsEnabled` | `false` | Enable CORS (adds `OPTIONS` to allowed methods) |
| `nginx.allowDirectoryList` | `false` | Enable S3 directory listing |
| `nginx.dnsResolvers` | `""` | Override NGINX DNS resolver (auto-detected if empty) |

### Metrics

| Parameter | Default | Description |
|---|---|---|
| `metrics.enabled` | `false` | Enable nginx-prometheus-exporter sidecar |
| `metrics.image.tag` | `1.1.0` | Exporter image tag |
| `metrics.port` | `9113` | Exporter port |
| `metrics.serviceMonitor.enabled` | `false` | Create Prometheus `ServiceMonitor` |
| `metrics.serviceMonitor.namespace` | `""` | Namespace for the ServiceMonitor (defaults to release namespace) |
| `metrics.serviceMonitor.interval` | `30s` | Prometheus scrape interval |
| `metrics.serviceMonitor.labels` | `{}` | Extra labels (e.g. `release: prometheus`) |

## Example: Full Production Setup

```yaml
# values-prod.yaml
replicaCount: 3

image:
  repository: ghcr.io/rayselfs/nginx-multi-s3-gateway
  tag: "0.1.1"

s3:
  bucketName: my-default-bucket
  region: ap-northeast-1
  style: virtual

buckets:
  - name: bucket-prod
  - name: bucket-staging

ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: s3-gateway.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: s3-gateway-tls
      hosts:
        - s3-gateway.example.com

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

pdb:
  enabled: true
  minAvailable: 2

resources:
  limits:
    cpu: 1000m
    memory: 512Mi
  requests:
    cpu: 200m
    memory: 256Mi

metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    labels:
      release: prometheus

affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: nginx-multi-s3-gateway
        topologyKey: kubernetes.io/hostname
```

## Uninstalling

```bash
helm uninstall my-gateway --namespace my-namespace
```

> The `<release>-bucket-map` ConfigMap is deleted automatically with the release.
