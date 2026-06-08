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
| AWS | S3 access via EKS Pod Identity (recommended), IRSA, or static credentials |

## Installation

```bash
helm install my-gateway \
  oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway \
  --version 0.3.0 \
  --namespace my-namespace \
  --create-namespace \
  --set s3.bucketName=my-default-bucket \
  --set s3.region=ap-northeast-1
```

> **Private registry only**: if the GHCR package is private, authenticate first:
> ```bash
> echo $GITHUB_TOKEN | helm registry login ghcr.io --username <username> --password-stdin
> ```

See [Configuration](#configuration) for credentials and all available options.

### Upgrade (add/remove buckets, config changes)

```bash
helm upgrade my-gateway \
  oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway \
  --version 0.3.0 \
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

### EKS Pod Identity (recommended)

Newer than IRSA, simpler to operate — no OIDC trust policy required on the IAM role.

**1. Enable the Pod Identity Agent add-on** (one-time per cluster):

```bash
aws eks create-addon \
  --cluster-name my-cluster \
  --addon-name eks-pod-identity-agent
```

**2. IAM role trust policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
```

Attach `s3:GetObject` (+ `s3:ListBucket` if directory listing is enabled) to the role.

**3. Create the Pod Identity association** (default SA name is `<release>-nginx-multi-s3-gateway`):

```bash
aws eks create-pod-identity-association \
  --cluster-name my-cluster \
  --namespace my-namespace \
  --service-account my-gateway-nginx-multi-s3-gateway \
  --role-arn arn:aws:iam::123456789012:role/nginx-s3-gateway-role
```

**4. Install** — no annotations needed:

```yaml
# values.yaml
s3:
  bucketName: my-default-bucket
  region: ap-northeast-1
```

### IRSA

Requires an OIDC provider associated with the cluster. Use when the Pod Identity Agent cannot be installed.

**IAM role trust policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.ap-northeast-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE:sub":
          "system:serviceaccount:my-namespace:my-gateway-nginx-multi-s3-gateway"
      }
    }
  }]
}
```

```yaml
# values.yaml
serviceAccount:
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

### S3 Express One Zone

Use `s3.service: s3express` for [S3 Express One Zone](https://docs.aws.amazon.com/AmazonS3/latest/userguide/s3-express-one-zone.html) (Directory Buckets). The bucket name must include the full AZ suffix and `S3_SERVER` must point to the zonal endpoint.

```yaml
# values.yaml
s3:
  bucketName: my-bucket--usw2-az1--x-s3
  server: my-bucket--usw2-az1--x-s3.s3express-usw2-az1.us-west-2.amazonaws.com
  region: us-west-2
  style: virtual-v2
  service: s3express
```

### Static Site Hosting

Set `nginx.provideIndexPage: true` to serve `index.html` when a directory path is requested. Combine with `nginx.appendSlashForPossibleDirectory` to redirect `/some/path` → `/some/path/` automatically.

```yaml
# values.yaml
nginx:
  provideIndexPage: true
  appendSlashForPossibleDirectory: true
```

### CORS

```yaml
# values.yaml
nginx:
  corsEnabled: true
  corsAllowedOrigin: "https://app.example.com"   # default: * (all origins)
  # corsAllowPrivateNetworkAccess: "true"         # respond to private network preflights
```

### Directory Listing

```yaml
# values.yaml
nginx:
  allowDirectoryList: true
  directoryListingPathPrefix: "/files/"   # optional: prefix links in listing output
```

### Path Rewriting

Strip or replace a leading path segment — useful when the gateway is behind an ALB/ingress under a subpath.

```yaml
# values.yaml
nginx:
  stripLeadingDirectoryPath: /assets          # remove /assets prefix before forwarding to S3
  prefixLeadingDirectoryPath: /static         # prepend /static to all S3 object paths
```

### Header Filtering

Strip custom vendor headers from S3 responses, or selectively allow specific prefixes through.

```yaml
# values.yaml
nginx:
  headerPrefixesToStrip: "x-goog-;x-custom-"   # semicolon-separated, lowercase
  headerPrefixesAllowed: ""                     # override allow-list (use with caution)
```

### Cache Bypass (per-path)

Skip the proxy cache for specific URI patterns. Useful for file types that should never be served stale (e.g. manifests, scripts).

```yaml
# values.yaml
nginx:
  proxyCacheBypassPaths:
    - '\.json$'
    - '\.sh$'
```

Patterns are PCRE and OR-combined at render time. An empty list (default) disables per-path bypass.

### Static Credentials with Session Token

For temporary credentials (e.g. assumed role), include `AWS_SESSION_TOKEN` in the secret. The chart mounts it as an optional key — the pod will still start if the key is absent.

```bash
kubectl create secret generic aws-temp-creds \
  --namespace my-namespace \
  --from-literal=AWS_ACCESS_KEY_ID=ASIA... \
  --from-literal=AWS_SECRET_ACCESS_KEY=... \
  --from-literal=AWS_SESSION_TOKEN=...
```

```yaml
# values.yaml
s3:
  bucketName: my-default-bucket
  region: us-east-1
  existingSecret: aws-temp-creds
```

### Custom STS Endpoint (non-EKS IRSA)

For self-managed Kubernetes using projected service account tokens (IRSA-compatible), set `nginx.jsTrustedCertPath` to the CA cert path used for STS calls. Optionally override the STS endpoint for VPC or regional setups.

```yaml
# values.yaml
nginx:
  jsTrustedCertPath: /etc/ssl/certs/ca-certificates.crt

aws:
  stsRegionalEndpoints: regional   # or set stsEndpoint for a fully custom URL
  # stsEndpoint: "https://sts.ap-northeast-1.amazonaws.com"
```

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
| `s3.service` | `s3` | S3 service type: `s3` / `s3express` (S3 Express One Zone) |
| `s3.existingSecret` | `""` | Secret name with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN` (optional key) |
| `aws.sigVersion` | `"4"` | AWS Signature version (`4` or `2`) |
| `aws.debug` | `false` | Enable AWS signature debug output |
| `aws.roleSessionName` | `""` | Override role session name (default: `nginx-s3-gateway`) |
| `aws.stsEndpoint` | `""` | Override STS endpoint URL |
| `aws.stsRegionalEndpoints` | `""` | STS endpoint mode: `global` / `regional` (ignored if `stsEndpoint` is set) |
| `buckets` | `[]` | Bucket whitelist (see Multi-bucket Routing) |
| `serviceAccount.annotations` | `{}` | Use for IRSA role ARN |
| `nginx.corsEnabled` | `false` | Enable CORS (adds OPTIONS to allowed methods) |
| `nginx.corsAllowedOrigin` | `""` | `Access-Control-Allow-Origin` value (only when corsEnabled, default: `*`) |
| `nginx.corsAllowPrivateNetworkAccess` | `""` | Respond to `Access-Control-Request-Private-Network` with this value (`true`/`false`/`""`) |
| `nginx.allowDirectoryList` | `false` | Enable S3 directory listing |
| `nginx.provideIndexPage` | `false` | Serve `index.html` when a directory path is requested |
| `nginx.appendSlashForPossibleDirectory` | `false` | Return 302 with trailing `/` for paths that look like directories |
| `nginx.proxyCacheMaxSize` | `10g` | Maximum total proxy cache size on disk |
| `nginx.proxyCacheInactive` | `60m` | Evict cached data not accessed within this time |
| `nginx.dnsResolvers` | `""` | Override NGINX DNS resolver (auto-detected if empty) |
| `nginx.jsTrustedCertPath` | `""` | Path to trusted CA cert for STS calls (needed for non-EKS IRSA) |
| `nginx.headerPrefixesToStrip` | `""` | Semicolon-separated header prefixes to remove from S3 responses (e.g. `x-goog-;x-custom-`) |
| `nginx.headerPrefixesAllowed` | `""` | Semicolon-separated header prefixes to pass through to clients (use with caution) |
| `nginx.proxyCacheBypassPaths` | `[]` | PCRE patterns for paths that bypass the proxy cache (OR-combined); empty disables |
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
