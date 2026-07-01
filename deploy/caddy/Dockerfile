# deploy/caddy/Dockerfile — custom HelixCode Caddy edge image WITH a Brotli encoder.
#
# Purpose      : stock caddy:2 ships only the gzip + zstd `encode` encoders. The
#                edge (up.sh renders `encode zstd br gzip`) also wants Brotli
#                (`br`) for text/editor assets, so this 2-stage build adds the
#                `br` encoder via xcaddy and drops the resulting binary into a
#                stock caddy:2 runtime.
# Module       : github.com/ueffel/caddy-brotli — a PURE-GO Brotli encoder that
#                registers the `br` encode directive (verified upstream
#                2026-07-01, §11.4.99). Chosen over the cgo
#                github.com/dunglas/caddy-cbrotli (§11.4.6, honest engineering
#                trade-off): cbrotli needs the brotli C library + headers in the
#                BUILDER *and* the brotli shared libs in the RUNTIME image,
#                making the final image fragile and non-self-contained. The
#                pure-Go module builds with plain xcaddy (no cgo, no apk deps)
#                and produces a single self-contained binary that runs unchanged
#                on stock caddy:2 — the robust choice for this rootless edge.
# Build        : referenced by deploy/compose.codeserver.yml (build: ./caddy);
#                `podman compose -f compose.codeserver.yml up -d --build` builds
#                it. Standalone: `podman build -t localhost/helixcode-caddy-brotli:2 .`
# Extending    : a future DNS-01 provider plugin (TLS_MODE=letsencrypt* +
#                ACME_DNS_PROVIDER) is added here the same way — append another
#                `--with <module>` to the xcaddy line (see docs/guides/TLS.md).
# Cross-refs   : §11.4.76 (Caddy stays containerized) §11.4.6 (no-cgo choice)
#                §11.4.99 (module verified against upstream) §11.4.174 (build is
#                ours; tagged under a project-local name, never the shared caddy:2)
FROM docker.io/library/caddy:2-builder AS build
RUN xcaddy build --with github.com/ueffel/caddy-brotli

FROM docker.io/library/caddy:2
COPY --from=build /usr/bin/caddy /usr/bin/caddy
