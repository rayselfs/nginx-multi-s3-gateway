# nginx-multi-s3-gateway

Production-ready NGINX S3 gateway with **dynamic multi-bucket routing**.  
A thin Docker overlay on [`nginxinc/nginx-s3-gateway`](https://github.com/nginxinc/nginx-s3-gateway), packaged as a Helm chart with GitHub Actions CI/CD.

## How It Works

```
Client  ──────────────────────────────────────────────────────►  nginx pod
  GET /path/to/object
  X-S3-Bucket: bucket-prod
                                 ┌──────────────────────────────────────────┐
                                 │  bucket-map ConfigMap (Helm-rendered)    │
                                 │                                          │
                                 │  $http_x_s3_bucket                       │
                                 │    "bucket-prod" → $s3_bucket_name_var   │
                                 │                                          │
                                 │  $s3_bucket_name_var                     │
                                 │    "bucket-prod" → $s3_host              │
                                 │    "bucket-prod" → $s3_upstream          │
                                 └──────────────────────────────────────────┘
                                           │
                                           ▼  NJS signs with correct bucket + host
                                 proxy_pass → S3  (Host: bucket-prod.s3.amazonaws.com)
```

- **No X-S3-Bucket header** → falls back to `s3.bucketName` (default bucket)
- **Unlisted bucket** → silently falls back to default (clients cannot access arbitrary buckets)
- **Bucket list change** → `helm upgrade` re-renders the ConfigMap; `checksum/config` annotation triggers a rolling restart automatically

## Prerequisites

| Requirement | Version |
|---|---|
| Kubernetes | 1.25+ |
| Helm | 3.10+ |
| AWS | S3 access via IRSA (recommended) or static credentials |

## Installation

### 1. Authenticate to GHCR (one-time)

```bash
echo $GITHUB_TOKEN | helm registry login ghcr.io --username <github-username> --password-stdin
```

> If the package is public, skip this step.

### 2. Create a `values.yaml`

Minimum viable values for EKS with IRSA:

```yaml
s3:
  bucketName: my-default-bucket   # required: fallback when no X-S3-Bucket header
  region: ap-northeast-1

serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/nginx-s3-gateway-role
```

### 3. Install

```bash
helm install my-gateway \
  oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway \
  --version 0.1.0 \
  --namespace my-namespace \
  --create-namespace \
  -f values.yaml
```

### Upgrade (add/remove buckets, config changes)

```bash
helm upgrade my-gateway \
  oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway \
  --version 0.1.0 \
  --namespace my-namespace \
  -f values.yaml
```

A rolling restart is triggered automatically when the bucket list changes.

### Uninstall

```bash
helm uninstall my-gateway --namespace my-namespace
```

---

## Configuration

### IRSA (recommended for EKS)

Create an IAM role with the following trust policy and attach `s3:GetObject` (+ `s3:ListBucket` if directory listing is enabled) on the target buckets.

```yaml
# values.yaml
serviceAccount:
  create: true
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/nginx-s3-gateway-role

s3:
  bucketName: my-default-bucket
  region: ap-northeast-1
```

No `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` needed.

### Static Credentials (non-EKS fallback)

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

### Multi-bucket Routing

```yaml
# values.yaml
s3:
  bucketName: my-default-bucket   # fallback
  region: ap-northeast-1
  style: virtual                  # virtual | virtual-v2 | path

buckets:
  - name: bucket-prod
  - name: bucket-staging
  - name: bucket-assets
```

Clients route to a specific bucket via the `X-S3-Bucket` header:

```bash
curl -H "X-S3-Bucket: bucket-prod" https://my-gateway.example.com/path/to/object
```

Buckets **not** in the list silently fall back to `s3.bucketName`.

#### S3 Style

| Style | Host header | Use case |
|---|---|---|
| `virtual` (default) | `<bucket>.s3.amazonaws.com` | AWS S3, standard |
| `virtual-v2` | `<bucket>.s3.amazonaws.com:443` | Some MinIO / non-AWS setups |
| `path` | `s3.amazonaws.com:443` | Path-style access (legacy / VPC endpoints) |

### Scaling

```yaml
# values.yaml
replicaCount: 3

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

pdb:
  enabled: true
  minAvailable: 1
```

### Ingress

```yaml
# values.yaml
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
```

### Metrics (nginx-prometheus-exporter)

```yaml
# values.yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    labels:
      release: prometheus   # match your Prometheus operator selector
```

Exposes `/stub_status` on port 9113 via a sidecar container.  
`/stub_status` is restricted to `127.0.0.1` in nginx config; the exporter runs in the same pod.

---

## Full values reference

| Key | Default | Description |
|---|---|---|
| `replicaCount` | `2` | Pod replicas (ignored when autoscaling enabled) |
| `image.repository` | `ghcr.io/rayselfs/nginx-multi-s3-gateway` | Container image |
| `image.tag` | `""` (→ appVersion) | Image tag override |
| `s3.bucketName` | `""` (**required**) | Default/fallback S3 bucket |
| `s3.server` | `s3.amazonaws.com` | S3 endpoint hostname |
| `s3.serverPort` | `443` | S3 endpoint port |
| `s3.serverProto` | `https` | `https` or `http` |
| `s3.region` | `us-east-1` | AWS region |
| `s3.style` | `virtual` | URL style: `virtual` / `virtual-v2` / `path` |
| `s3.existingSecret` | `""` | Secret name with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |
| `aws.sigVersion` | `"4"` | AWS Signature version (`4` or `2`) |
| `buckets` | `[]` | Bucket whitelist (see Multi-bucket Routing) |
| `serviceAccount.annotations` | `{}` | Use for IRSA role ARN |
| `nginx.corsEnabled` | `false` | Enable CORS (adds OPTIONS to allowed methods) |
| `nginx.allowDirectoryList` | `false` | Enable S3 directory listing |
| `nginx.dnsResolvers` | `""` | Override NGINX DNS resolver (auto-detected if empty) |
| `metrics.enabled` | `false` | Enable nginx-prometheus-exporter sidecar |
| `metrics.serviceMonitor.enabled` | `false` | Create Prometheus ServiceMonitor |
| `autoscaling.enabled` | `false` | Enable HPA |
| `pdb.enabled` | `true` | Enable PodDisruptionBudget |
| `ingress.enabled` | `false` | Create Ingress resource |

---

## CI/CD

### Continuous Integration

Every push to `main` (non-tag) triggers `.github/workflows/ci.yml`:

- Multi-platform build: `linux/amd64`, `linux/arm64`
- Pushes to GHCR with tags: `latest`, `sha-<short-sha>`

### Release

Push a semver tag to trigger `.github/workflows/release.yml`:

```bash
git tag v0.1.0
git push origin v0.1.0
```

This will:
1. Build and push the Docker image with tags: `0.1.0`, `0.1`, `0`, `latest`
2. Stamp `chart/Chart.yaml` with the version
3. `helm package chart/` and push to `oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway`

### Updating the Base Image

1. Check [nginxinc/nginx-s3-gateway tags](https://hub.docker.com/r/nginxinc/nginx-s3-gateway/tags)
2. Update `ARG BASE_IMAGE=nginxinc/nginx-s3-gateway:<new-tag>` in `Dockerfile`
3. Commit, tag, push

---

## Local Development

```bash
cp .env.example .env
# Edit .env with your S3 credentials

docker build -t nginx-multi-s3-gateway:dev .
docker run --rm -p 8080:80 --env-file .env nginx-multi-s3-gateway:dev
```

Test single-bucket access:
```bash
curl http://localhost:8080/path/to/object
```

Test multi-bucket routing:
```bash
curl -H "X-S3-Bucket: bucket-prod" http://localhost:8080/path/to/object
```

---

## Security Notes

- The `X-S3-Bucket` header is validated against a **whitelist**. Unlisted values silently fall back to the default bucket — clients cannot access arbitrary buckets.
- `/stub_status` is restricted to `allow 127.0.0.1; deny all` — only the in-pod metrics sidecar can reach it.
- AWS `x-amz-*` headers are stripped from responses before returning to clients.
- Use IRSA on EKS — avoid static credentials whenever possible.

## License

Apache 2.0 — see upstream [nginxinc/nginx-s3-gateway](https://github.com/nginxinc/nginx-s3-gateway) for base image license.
