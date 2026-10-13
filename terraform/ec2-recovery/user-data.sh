#!/usr/bin/env bash
set -euo pipefail

# Prepare tools only. Never initialize PostgreSQL or download AWS credentials.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates docker.io docker-compose-v2 git make python3
systemctl enable --now docker
snap start amazon-ssm-agent
docker compose version
install -d -m 0755 /opt/postgres-disaster-recovery
