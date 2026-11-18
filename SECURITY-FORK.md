# Security fork: ingress-nginx v1.15.1 + NGINX 1.31.9

The Kubernetes `ingress-nginx` project was retired in March 2026. Its last release,
**v1.15.1**, bundles **NGINX 1.27.1**, which is affected by every NGINX CVE published
since. This fork (`jwklijnsma/nginx-ingress`) keeps the v1.15.1 controller
and rebuilds the NGINX base image on **NGINX 1.31.9**, the mainline security release
from 2026-11-18.

## What changed

| Area | Upstream v1.15.1 | This fork |
|---|---|---|
| NGINX core | 1.27.1 + 35 patches | **1.31.9** + 34 OpenResty 1.31.8.1 patches + `00_drop-alias-root` |
| lua-nginx-module / lua-resty-core | v0.10.28 / v0.1.31 | v0.10.32rc7 / v0.1.35rc2 (the pair OpenResty 1.31.8.1 ships) |
| stream-lua-nginx-module | v0.0.16 | v0.0.20rc3 |
| LuaJIT (openresty/luajit2) | v2.1-20250117 | v2.1-20261107 |
| NDK / set-misc / headers-more / lua-upstream | 0.3.3 / 0.33 / 0.37 / 0.07 | 0.3.4 / 0.34 / 0.40 / 0.08 |
| lua-cjson, resty-dns/-memcached/-redis/-string | 2.1.0.14, 0.23/0.17/0.31/0.16 | 2.1.0.20, 0.24/0.18/0.34/0.19 |
| Go toolchain | 1.26.1 | 1.26.10 |
| Images | registry.k8s.io | `ghcr.io/jwklijnsma/nginx-ingress/{nginx,controller}` (cosign-signed) |

Patch notes:
* `CVE-2025-23419` patch dropped: fixed in core since 1.27.4.
* `stream_proxy_protocol_v2` patch dropped: NGINX 1.31 has native `proxy_protocol v2`
  in the stream module, with the same `off|on|v2` syntax the controller template uses.
* `00_drop-alias-root` (removes `root`/`alias`) regenerated for 1.31.9.
* Not taken from OpenResty: `server_header` and `builtin_error_page_footer` (they would
  change the `Server:` header and error pages) and `no_pool` (debug-only).

## How it was verified

* All patches apply cleanly to the `release-1.31.9` tag, in OpenResty's order.
* NGINX 1.31.9 builds with the exact `configure` flags and module set from `build.sh`
  (NDK, set-misc, headers-more, lua, stream-lua, lua-upstream, auth-digest,
  ModSecurity-nginx, geoip2, brotli, njs 0.9.0). The OpenTelemetry module is only
  built in CI.
* Every directive in `rootfs/etc/nginx/template/nginx.tmpl` resolves to a directive in
  that build.
* Runtime smoke test passed: `resty.core` loads, and `init_by_lua`,
  `init_worker_by_lua`, `ssl_certificate_by_lua`, HTTP and stream `balancer_by_lua`,
  HTTP/2, njs and brotli all work.
* The "Fork images" workflow checks `nginx -V` reports 1.31.9 in both base and
  controller images, then runs a Trivy scan.

## NGINX CVEs fixed versus upstream v1.15.1 (NGINX 1.27.1)

From NGINX's own `changes.xml` (1.27.2 to 1.31.9). Mail-proxy CVEs are fixed in the
source, and the mail modules aren't compiled in anyway.

| CVE | Fixed in mainline | Issue | Status in this fork |
|---|---|---|---|
| CVE-2026-125283 | 1.31.9 (2026-11-18) | a buffer overflow might occur in a worker process when using the "try_files" and "alias" directives in certain configurations | Fixed |
| CVE-2026-123007 | 1.31.9 (2026-11-18) | a flow control window overflow in HTTP/2 might allow an attacker to cause a segmentation fault in a worker process, or might have potential other impa… | Fixed |
| CVE-2026-123633 | 1.31.9 (2026-11-18) | use-after-free might occur in a worker process when using HTTP/2 if worker_connections were not enough | Fixed |
| CVE-2026-121810 | 1.31.9 (2026-11-18) | use-after-free might occur in a worker process when using HTTP/3 if worker_connections were not enough | Fixed |
| CVE-2026-123634 | 1.31.9 (2026-11-18) | use-after-free condition might occur if the "resolver" directive was used and the same name was simultaneously resolved in subrequests, allowing an at… | Fixed |
| CVE-2026-113425 | 1.31.9 (2026-11-18) | use-after-free might occur in a worker process in the mail proxy server | Fixed (mail modules are also compiled out) |
| CVE-2026-120967 | 1.31.9 (2026-11-18) | in the stream module, an attacker who is able to complete the SSL handshake synchronously might cause client SSL certificates to be verified using the… | Fixed |
| CVE-2026-120993 | 1.31.9 (2026-11-18) | a segmentation fault might occur in a worker process when using PROXY protocol version 2 with dynamic SSL certificate loading | Fixed |
| CVE-2026-123640 | 1.31.9 (2026-11-18) | the ngx_stream_ssl_preread_module might interpret malformed ClientHello messages differently than other TLS implementations, which might result in byp… | Fixed |
| CVE-2026-118899 | 1.31.9 (2026-11-18) | worker processes might get caught in an endless loop while reading the request body over SSL | Fixed |
| CVE-2026-15176 | 1.31.7 (2026-10-14) | a buffer overflow might occur in a worker process when using the "alias" directive if the request URI was changed by the "rewrite" directive and was t… | Fixed |
| CVE-2026-93479 | 1.31.7 (2026-10-14) | a buffer overflow might occur in a worker process while evaluating string expressions with variables, which affected the document root calculation and… | Fixed |
| CVE-2026-95101 | 1.31.7 (2026-10-14) | when using HTTP/3 a part of an unknown frame might be treated as the request body, which might result in bypassing the "client_max_body_size" limit or… | Fixed |
| CVE-2026-97629 | 1.31.7 (2026-10-14) | when using TLS session ticket key rotation, one of the keys was left uninitialized, which might allow to forge a session | Fixed |
| CVE-2026-97205 | 1.31.7 (2026-10-14) | when using asynchronous file I/O (AIO), use-after-free might occur in certain configurations if the SSI page has "include virtual" commands | Fixed |
| CVE-2026-90439 | 1.31.6 (2026-09-15) | a heap memory buffer overflow might occur in a worker process under certain configurations when using HTTP/3 with OpenSSL 3.5.0 and earlier | Fixed |
| CVE-2026-42533 | 1.31.3 (2026-07-15) | heap buffer overflow might occur in a worker process when using the map directive with regex matching if the map variable was included in a string exp… | Fixed |
| CVE-2026-60005 | 1.31.3 (2026-07-15) | uninitialized memory access might occur when using unnamed regex captures with the "slice" directive or background cache update, which could result in… | Fixed |
| CVE-2026-56434 | 1.31.3 (2026-07-15) | use-after-free might occur when processing a specially crafted proxied backend response with the ngx_http_ssi_filter_module | Fixed |
| CVE-2026-42530 | 1.31.2 (2026-06-17) | use-after-free might occur when using HTTP/3 and processing a specially crafted QUIC session, allowing an attacker to cause worker process memory corr… | Fixed |
| CVE-2026-42055 | 1.31.2 (2026-06-17) | a heap memory buffer overflow might occur in a worker process when using a configuration with "ignore_invalid_headers off;" and "large_client_header_b… | Fixed |
| CVE-2026-48142 | 1.31.2 (2026-06-17) | a heap memory buffer overread might occur in a worker process while handling a specially sent response with decoding from UTF-8 via the "charset_map" … | Fixed |
| CVE-2026-9256 | 1.31.1 (2026-05-22) | a heap memory buffer overflow might occur in a worker process when using a configuration with overlapping captures in ngx_http_rewrite_module, potenti… | Fixed |
| CVE-2026-42926 | 1.31.0 (2026-05-13) | when using the "proxy_set_body" directive, an attacker might inject data in the proxied request to an HTTP/2 backend | Fixed |
| CVE-2026-42945 | 1.31.0 (2026-05-13) | a heap memory buffer overflow might occur in a worker process while handling a specially crafted request by ngx_http_rewrite_module, potentially resul… | Fixed |
| CVE-2026-42946 | 1.31.0 (2026-05-13) | a heap memory buffer overread might occur in a worker process while handling a specially crafted response by ngx_http_scgi_module or ngx_http_uwsgi_mo… | Fixed |
| CVE-2026-42934 | 1.31.0 (2026-05-13) | a heap memory buffer overread might occur in a worker process while handling a specially sent response with decoding from UTF-8 via the "charset_map" … | Fixed |
| CVE-2026-40460 | 1.31.0 (2026-05-13) | when using HTTP/3, processing of connection migration might cause new QUIC streams to receive a new client address before validation, allowing an atta… | Fixed |
| CVE-2026-40701 | 1.31.0 (2026-05-13) | use-after-free might occur during DNS server response processing if the "ssl_ocsp" directive was used, allowing an attacker to cause worker process me… | Fixed |
| CVE-2026-27654 | 1.29.7 (2026-03-24) | a buffer overflow might occur while handling a COPY or MOVE request in a location with "alias", allowing an attacker to modify the source or destinati… | Fixed |
| CVE-2026-27784 | 1.29.7 (2026-03-24) | processing of a specially crafted mp4 file by the ngx_http_mp4_module on 32-bit platforms might cause a worker process crash, or might have potential … | Fixed |
| CVE-2026-32647 | 1.29.7 (2026-03-24) | processing of a specially crafted mp4 file by the ngx_http_mp4_module might cause a worker process crash, or might have potential other impact | Fixed |
| CVE-2026-27651 | 1.29.7 (2026-03-24) | a segmentation fault might occur in a worker process if the CRAM-MD5 or APOP authentication methods were used and authentication retry was enabled | Fixed |
| CVE-2026-28753 | 1.29.7 (2026-03-24) | an attacker might use PTR DNS records to inject data in auth_http requests, as well as in the XCLIENT command in the backend SMTP connection | Fixed |
| CVE-2026-28755 | 1.29.7 (2026-03-24) | SSL handshake might succeed despite OCSP rejecting a client certificate in the stream module | Fixed |
| CVE-2026-1642 | 1.29.5 (2026-02-04) | an attacker might inject plain text data in the response from an SSL backend | Fixed |
| CVE-2025-53859 | 1.29.1 (2025-08-13) | processing of a specially crafted login/password when using the "none" authentication method in the ngx_mail_smtp_module might cause worker process me… | Fixed |
| CVE-2025-23419 | 1.27.4 (2025-02-05) | insufficient check in virtual servers handling with TLSv1.3 SNI allowed to reuse SSL sessions in a different virtual server, to bypass client SSL cert… | Fixed |

Not covered here: controller-level CVEs (Go code, annotations). v1.15.1 already includes
the Feb 2026 fixes (CVE-2026-24512, -1580, -24513, -24514). Go stdlib issues are
handled by the toolchain bump.

## Known caveat

`get_src` in `images/nginx/rootfs/build.sh` has checksum verification commented out
upstream (`# TODO: Reenable checksum verification`). This fork leaves that unchanged, so
source tarballs are fetched over HTTPS without hash pinning, same as upstream.

## Stopgap if you can't roll this out yet

Disabling HTTP/2 and HTTP/3 blocks only CVE-2026-123007, -123633 and -121810. It does
**not** block the resolver, stream or alias bugs. The real fix is the rebuilt image.
