FROM postgres:17.11-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652

# Keep the official entrypoint and database version; add the reviewed backup tool.
RUN set -eux; \
    postgres_version="$(postgres --version)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends pgbackrest=2.59.1-1.pgdg12+1; \
    test "$(postgres --version)" = "$postgres_version"; \
    test "$(pgbackrest version)" = 'pgBackRest 2.59.1'; \
    rm -rf /var/lib/apt/lists/*
