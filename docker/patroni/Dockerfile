FROM postgres:17.11-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652

RUN set -eux; \
    postgres_version="$(postgres --version)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends python3-venv ca-certificates; \
    printf '%s\n' \
        'deb [signed-by=/usr/local/share/keyrings/postgres.gpg.asc] https://apt-archive.postgresql.org/pub/repos/apt bookworm-pgdg-archive main' \
        > /etc/apt/sources.list.d/pgdg-archive.list; \
    printf '%s\n' 'Package: *' 'Pin: origin apt-archive.postgresql.org' 'Pin-Priority: 100' \
        > /etc/apt/preferences.d/pgdg-archive; \
    apt-get update; \
    apt-get install -y --no-install-recommends pgbackrest=2.59.1-1.pgdg12+1; \
    python3 -m venv /opt/patroni; \
    /opt/patroni/bin/pip install --no-cache-dir 'patroni[etcd3]==4.1.5' 'psycopg2-binary==2.9.11'; \
    /opt/patroni/bin/pip check; \
    test "$(postgres --version)" = "$postgres_version"; \
    test "$(/opt/patroni/bin/patroni --version)" = 'patroni 4.1.5'; \
    test "$(pgbackrest version)" = 'pgBackRest 2.59.1'; \
    rm -rf /var/lib/apt/lists/*; \
    install -d -o postgres -g postgres -m 0750 /var/lib/pgbackrest

# Patroni 4.1.5 selects the gateway route from etcd's cluster feature version.
# A fresh quorum can report 3.0 until the last member joins, while etcd 3.6
# serves only /v3. Select the route from the server version without changing
# the reported cluster features. Fail the build if the pinned patch target moves.
RUN /opt/patroni/bin/python - <<'PY'
from importlib import reload
from importlib.metadata import version
from pathlib import Path
from types import SimpleNamespace
import patroni.dcs.etcd3 as etcd3

assert version('patroni') == '4.1.5', 'Review the etcd gateway patch before upgrading Patroni'
assert etcd3.__file__ is not None
path = Path(etcd3.__file__)
source = path.read_text()
original = '            if self._cluster_version < (3, 3):\n'
replacement = (
    '            if server_version >= (3, 4):\n'
    "                self.version_prefix = '/v3'\n"
    '            elif self._cluster_version < (3, 3):\n'
)
assert source.count(original) == 1, 'Unexpected Patroni etcd gateway implementation'
path.write_text(source.replace(original, replacement))
reload(etcd3)

for server, cluster, expected in (
    ('3.6.5', '3.0.0', '/v3'),
    ('3.6.5', '3.6.0', '/v3'),
    ('3.5.21', '3.0.0', '/v3'),
    ('3.4.0', '3.0.0', '/v3'),
    ('3.3.0', '3.3.0', '/v3beta'),
    ('3.2.0', '3.2.0', '/v3alpha'),
    ('3.6.5', '2.3.0', None),
    ('2.3.0', '3.0.0', None),
):
    response = {'etcdserver': server, 'etcdcluster': cluster}
    client = SimpleNamespace(version_prefix='/v3beta', _MGET='GET', username=None, password=None,
                             http=SimpleNamespace(urlopen=lambda *args, **kwargs: response),
                             _handle_server_response=lambda data: data)
    try:
        etcd3.Etcd3Client._ensure_version_prefix(client, 'https://unused.invalid')
    except etcd3.UnsupportedEtcdVersion:
        assert expected is None, (server, cluster)
    else:
        assert expected is not None and client.version_prefix == expected, (server, cluster)
        assert client._cluster_version == tuple(int(part) for part in cluster.split('.'))
print('Verified Patroni etcd gateway compatibility: 8 cases')
PY

ENV PATH="/opt/patroni/bin:${PATH}"
ENTRYPOINT ["bash", "/opt/patroni.sh", "start-node"]
CMD []
