FROM postgres:17.11-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652

RUN set -eux; \
    postgres_version="$(postgres --version)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends python3-venv ca-certificates; \
    python3 -m venv /opt/patroni; \
    /opt/patroni/bin/pip install --no-cache-dir 'patroni[etcd3]==4.1.5' 'psycopg2-binary==2.9.11'; \
    /opt/patroni/bin/pip check; \
    test "$(postgres --version)" = "$postgres_version"; \
    test "$(/opt/patroni/bin/patroni --version)" = 'patroni 4.1.5'; \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/patroni/bin:${PATH}"
ENTRYPOINT ["bash", "/opt/patroni.sh", "start-node"]
CMD []
