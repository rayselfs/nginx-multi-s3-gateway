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

## ⚠️ Mandatory doc sync on every chart change

**Every chart change (new value, behavior change, version bump) MUST include all of the following updates in the same PR — no exceptions:**

| What to update | Where |
|---|---|
| All `--version X.Y.Z` version strings | `README.md`, `chart/README.md` |
| `tag: "X.Y.Z"` version string | `chart/README.md` (Full production setup example) |
| New value description and usage example | `README.md` Configuration section |
| New value table row | `README.md` Full values reference table, `chart/README.md` corresponding section table |

Quick check for missed version strings (replace `0.X.Y` with the old version):
```bash
grep -rn "0\.X\.Y" README.md chart/README.md
```

> **Why**: `release.yml` auto-stamps `chart/Chart.yaml` via `sed`, but version strings in READMEs are maintained entirely by hand. Missing an update causes users to install the wrong version.

## CI / Release

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | PR → main | Docker build only (no push) |
| `release.yml` | `git tag v*` | Build + push versioned image + Helm chart to GHCR |

**Release flow:**
```bash
git tag v0.3.0
git push origin v0.3.0
```

`release.yml` auto-stamps `chart/Chart.yaml` (`version:` and `appVersion:`) from the tag using `sed` — do not rely on the value committed in `Chart.yaml` for what was actually published. Only bump `Chart.yaml` manually when preparing a chart-only change that needs to be tracked in the branch.

**Release checklist** — every time `chart/Chart.yaml` version is bumped:
1. Update all `--version X.Y.Z` references in `README.md`
2. Update all `--version X.Y.Z` and `tag: "X.Y.Z"` references in `chart/README.md`
3. Document any new values in both README files (Configuration section + values table)

## GHCR packages are public

The Docker image and Helm chart OCI package are public — no authentication required:

```bash
helm pull oci://ghcr.io/rayselfs/charts/nginx-multi-s3-gateway --version 0.3.0
```

## Base image update

Pin is in `Dockerfile` line 6:
```
ARG BASE_IMAGE=nginxinc/nginx-s3-gateway:latest-njs-oss-<date>
```
Check available tags at https://hub.docker.com/r/nginxinc/nginx-s3-gateway/tags. After updating, tag and push a new release.
