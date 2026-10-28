FROM postgres:17.11-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652

# Keep the official entrypoint and database version; add the reviewed backup tool.
RUN set -eux; \
    postgres_version="$(postgres --version)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    printf '%s\n' \
        'deb [signed-by=/usr/local/share/keyrings/postgres.gpg.asc] https://apt-archive.postgresql.org/pub/repos/apt bookworm-pgdg-archive main' \
        > /etc/apt/sources.list.d/pgdg-archive.list; \
    printf '%s\n' 'Package: *' 'Pin: origin apt-archive.postgresql.org' 'Pin-Priority: 100' \
        > /etc/apt/preferences.d/pgdg-archive; \
    apt-get update; \
    apt-get install -y --no-install-recommends pgbackrest=2.59.1-1.pgdg12+1; \
    test "$(postgres --version)" = "$postgres_version"; \
    test "$(pgbackrest version)" = 'pgBackRest 2.59.1'; \
    test -s /etc/ssl/certs/ca-certificates.crt; \
    rm -rf /var/lib/apt/lists/*; \
    install -d -o postgres -g postgres -m 0750 /var/lib/pgbackrest
