# Default backend for charts/bitnami-nginx-ingress-controller.
#
# Drop-in for docker.io/bitnami/nginx (no longer updated, affected by the 2026
# NGINX CVEs) in the role the Bitnami chart uses it for: a tiny server on
# :8080 answering /healthz with 200 and everything else with 404. Runs the
# same patched NGINX as the controller, as uid 1001, read-only-root friendly.

ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG VERSION
LABEL org.opencontainers.image.title="NGINX default backend (Bitnami layout, patched)"
LABEL org.opencontainers.image.source="https://github.com/jwklijnsma/nginx-ingress"
LABEL org.opencontainers.image.version="${VERSION}"

USER root
COPY conf/ /opt/bitnami/nginx/conf/
RUN set -eu; \
  adduser -S -D -H -u 1001 -G root -h /opt/bitnami/nginx -s /sbin/nologin nginx-backend; \
  mkdir -p /opt/bitnami/nginx/tmp; \
  chown -R 1001:0 /opt/bitnami/nginx; \
  chmod -R g+rwX /opt/bitnami/nginx; \
  nginx -t -e stderr -c /opt/bitnami/nginx/conf/nginx.conf

USER 1001
EXPOSE 8080
# -e stderr: avoid the compiled-in /var/log/nginx/error.log (read-only root fs)
ENTRYPOINT ["/usr/local/nginx/sbin/nginx", "-e", "stderr", "-c", "/opt/bitnami/nginx/conf/nginx.conf", "-g", "daemon off;"]
