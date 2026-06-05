# syntax=docker/dockerfile:1

# ─── Upstream base image ──────────────────────────────────────────────────────
# Pin the tag to control when you absorb upstream changes.
# Available tags: https://hub.docker.com/r/nginxinc/nginx-s3-gateway/tags
ARG BASE_IMAGE=nginxinc/nginx-s3-gateway:latest-njs-oss
FROM ${BASE_IMAGE}

# ─── Overlay: only the files we modified ──────────────────────────────────────

# default.conf.template: replaces js_var $s3_host with three map blocks for
# dynamic bucket routing ($s3_bucket_name_var, $s3_host, $s3_upstream).
COPY common/etc/nginx/templates/default.conf.template \
     /etc/nginx/templates/default.conf.template

# upstreams.conf.template: adds keepalive to storage_urls and documents the
# per-bucket upstream pattern for S3_STYLE=virtual-v2.
COPY oss/etc/nginx/templates/upstreams.conf.template \
     /etc/nginx/templates/upstreams.conf.template

# s3_location_common.conf.template: proxy_ssl_name and proxy_pass now use
# per-request variables ($s3_host, $s3_upstream) instead of static env values.
COPY common/etc/nginx/templates/gateway/s3_location_common.conf.template \
     /etc/nginx/templates/gateway/s3_location_common.conf.template

# s3gateway.js: s3auth() and s3BaseUri() resolve the bucket name per-request
# via _resolveBucket(), falling back to S3_BUCKET_NAME env when no header given.
COPY common/etc/nginx/include/s3gateway.js \
     /etc/nginx/include/s3gateway.js
