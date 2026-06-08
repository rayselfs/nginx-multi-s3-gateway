# AGENTS.md — nginx-multi-s3-gateway

## What this repo is

A **thin Docker overlay** on `nginxinc/nginx-s3-gateway`. Only 4 upstream files are replaced:

| Local file | Why overridden |
|---|---|
| `common/etc/nginx/templates/default.conf.template` | Adds `map` blocks for X-S3-Bucket routing |
| `oss/etc/nginx/templates/upstreams.conf.template` | Adds keepalive + per-bucket upstream blocks |
| `common/etc/nginx/templates/gateway/s3_location_common.conf.template` | Uses per-request `$s3_host` / `$s3_upstream` vars |
| `common/etc/nginx/include/s3gateway.js` | Adds `_resolveBucket()` for per-request bucket resolution |

Everything else (auth, signing, caching, CORS) is inherited from upstream unmodified.

## How multi-bucket routing works

1. Helm renders `chart/templates/configmap-bucket.yaml` → `bucket-map.conf` (nginx `map` blocks)
2. `map $http_x_s3_bucket` sets `$s3_bucket_name_var`, `$s3_host`, `$s3_upstream` per request
3. `_resolveBucket(r)` in `s3gateway.js` picks `$s3_bucket_name_var` over `S3_BUCKET_NAME` env
4. `checksum/config` annotation on Deployment triggers rolling restart on any ConfigMap change — no manual rollout needed

`bucket-map.conf` is mounted via `subPath` to avoid clobbering other files in `/etc/nginx/conf.d/gateway/`.

## Local dev

```bash
cp .env.example .env   # fill in S3_BUCKET_NAME and optional AWS_ACCESS_KEY_ID
docker build -t nginx-multi-s3-gateway:dev .
docker run --rm -p 8080:80 --env-file .env nginx-multi-s3-gateway:dev

curl http://localhost:8080/path/to/object
curl -H "X-S3-Bucket: other-bucket" http://localhost:8080/path/to/object
```

## Helm chart

```bash
helm template test chart/ --set s3.bucketName=test   # verify renders cleanly
helm lint chart/
```

**Critical**: `values.schema.json` uses `additionalProperties: false` on every object. Adding a key to `values.yaml` without a matching entry in `values.schema.json` causes `helm template` / `helm install` to fail with a schema validation error.

SA name default: `<release-name>-nginx-multi-s3-gateway`. If `fullnameOverride: nginx-multi-s3-gateway` is set, SA name is just `nginx-multi-s3-gateway`.

## CI / Release

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | PR → main | Docker build only (no push) |
| `ci.yml` | push → main | Build + push `latest` + `sha-<short>` to GHCR ⚠️ redundant, pending removal |
| `release.yml` | `git tag v*` | Build + push versioned image + Helm chart to GHCR |

**Release flow:**
```bash
git tag v0.2.0
git push origin v0.2.0
```

`release.yml` auto-stamps `chart/Chart.yaml` (`version:` and `appVersion:`) from the tag using `sed` — do not rely on the value committed in `Chart.yaml` for what was actually published. Only bump `Chart.yaml` manually when preparing a chart-only change that needs to be tracked in the branch.

## GHCR packages are private

Both the Docker image and the Helm chart OCI package require authentication:

```bash
echo $GITHUB_TOKEN | helm registry login ghcr.io --username <username> --password-stdin
```

## Base image update

Pin is in `Dockerfile` line 6:
```
ARG BASE_IMAGE=nginxinc/nginx-s3-gateway:latest-njs-oss-<date>
```
Check available tags at https://hub.docker.com/r/nginxinc/nginx-s3-gateway/tags. After updating, tag and push a new release.

## Known open issue

`ci.yml` still has `push: branches: [main]` which fires a Docker build + GHCR push on every merge (including docs-only PRs). This is redundant with `release.yml`. Intended fix: remove the `push: branches: [main]` trigger and keep only `pull_request`.
