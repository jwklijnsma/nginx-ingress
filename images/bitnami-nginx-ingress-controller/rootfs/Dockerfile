# Bitnami-style variant of the patched ingress-nginx controller.
#
# Same binaries and NGINX as ghcr.io/<owner>/nginx-ingress/controller (nothing
# is rebuilt), but runs as uid 1001 / group root with group-writable state
# directories, the convention of docker.io/bitnami/nginx-ingress-controller.
# That lets charts/bitnami-nginx-ingress-controller keep its stock security
# context (runAsUser 1001), and also works with OpenShift's arbitrary UIDs
# (random uid, gid 0).
#
# Only directories are re-owned: chown on the binaries would strip their
# cap_net_bind_service file capability.

ARG CONTROLLER_IMAGE
FROM ${CONTROLLER_IMAGE}

ARG VERSION
ARG COMMIT_SHA

LABEL org.opencontainers.image.title="NGINX Ingress Controller (Bitnami-style, patched)"
LABEL org.opencontainers.image.description="ingress-nginx with NGINX 1.31.9 and CVE fixes; uid 1001 layout for the Bitnami chart"
LABEL org.opencontainers.image.source="https://github.com/jwklijnsma/nginx-ingress"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${COMMIT_SHA}"

USER root

RUN set -eu; \
  adduser -S -D -H -u 1001 -G root -h /etc/nginx -s /sbin/nologin nginx-ingress; \
  for d in \
    /etc/nginx \
    /etc/ingress-controller \
    /var/log/nginx \
    /var/log/audit \
    /var/lib/nginx \
    /tmp/nginx; do \
    mkdir -p "$d"; \
    chown -hR 1001:0 "$d"; \
    chmod -R g+rwX "$d"; \
  done

USER 1001

# Like docker.io/bitnami/nginx-ingress-controller, the controller binary is part
# of the entrypoint: the Bitnami chart passes only flags as `args`
# (--default-backend-service=..., --http-port=...). With the upstream entrypoint
# (dumb-init alone) dumb-init would try to execute the first flag.
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/nginx-ingress-controller"]
CMD []
