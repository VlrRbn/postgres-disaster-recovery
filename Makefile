.PHONY: setup check image up psql down acceptance backup-init backup-check backup backup-info backup-verify backup-health backup-health-acceptance restore restore-time restore-latest restore-up restore-psql restore-down pgadmin-up pgadmin-down pgadmin-acceptance rpo-acceptance s3-setup s3-up s3-down s3-psql s3-backup s3-info s3-check s3-health s3-acceptance s3-restore s3-restore-time s3-restore-latest s3-restore-up s3-restore-psql s3-restore-down replication-up replication-down replication-psql standby-psql replication-status replication-acceptance replication-promote replication-rejoin

setup:
	bash scripts/setup.sh

check:
	@for script in scripts/*.sh terraform/ec2-recovery/user-data.sh; do bash -n "$$script" || exit; done
	shellcheck scripts/*.sh terraform/ec2-recovery/user-data.sh
	python3 -m unittest discover -s tests -p 'test_*.py' -v
	bash scripts/compose.sh config --quiet
	PGDR_REPOSITORY=s3 bash scripts/compose.sh config --quiet
	PGDR_REPOSITORY=s3 PGDR_S3_FIXTURE=1 PGDR_S3_DIR=.local/s3 bash scripts/compose.sh config --quiet
	bash scripts/compose.sh --replication config --quiet
	git diff --check

replication-up:
	bash scripts/replication.sh up

replication-down:
	bash scripts/compose.sh --replication down

replication-psql:
	bash scripts/replication.sh primary-psql

standby-psql:
	bash scripts/replication.sh standby-psql

replication-promote:
	bash scripts/replication.sh promote

replication-rejoin:
	bash scripts/replication.sh rejoin

replication-status:
	bash scripts/replication.sh status

replication-acceptance:
	bash scripts/replication-acceptance.sh

image:
	bash scripts/compose.sh build postgres

s3-setup:
	python3 scripts/setup_s3.py
	PGDR_REPOSITORY=s3 bash scripts/setup.sh

s3-up: s3-setup
	PGDR_REPOSITORY=s3 bash scripts/compose.sh up --build --force-recreate --detach --wait --wait-timeout 120 postgres
	PGDR_REPOSITORY=s3 bash scripts/backup.sh init

s3-down:
	PGDR_REPOSITORY=s3 bash scripts/compose.sh --profile restore down

s3-restore: s3-setup
	PGDR_REPOSITORY=s3 bash scripts/restore.sh restore

s3-restore-time: s3-setup
	PGDR_REPOSITORY=s3 bash scripts/restore.sh time

s3-restore-latest: s3-setup
	PGDR_REPOSITORY=s3 bash scripts/restore.sh latest

s3-restore-up:
	PGDR_REPOSITORY=s3 bash scripts/restore.sh start

s3-restore-psql:
	PGDR_REPOSITORY=s3 bash scripts/compose.sh exec --user postgres restore psql -X -U postgres -d orders

s3-restore-down:
	PGDR_REPOSITORY=s3 bash scripts/compose.sh stop restore
	PGDR_REPOSITORY=s3 bash scripts/compose.sh rm --force restore

s3-psql:
	PGDR_REPOSITORY=s3 bash scripts/compose.sh exec --user postgres postgres psql -X -U postgres -d orders

s3-backup:
	PGDR_REPOSITORY=s3 bash scripts/backup.sh full

s3-info:
	PGDR_REPOSITORY=s3 bash scripts/backup.sh info

s3-check:
	PGDR_REPOSITORY=s3 bash scripts/backup.sh check

s3-health:
	@PGDR_REPOSITORY=s3 python3 scripts/backup_health.py

s3-acceptance:
	bash scripts/s3-acceptance.sh

up: setup
	bash scripts/compose.sh up --build --detach --wait --wait-timeout 120
	bash scripts/backup.sh init

psql:
	bash scripts/compose.sh exec --user postgres postgres psql -X -U postgres -d orders

down:
	bash scripts/compose.sh --profile restore --profile tools down

pgadmin-up: up
	bash scripts/setup.sh pgadmin
	bash scripts/compose.sh up --no-build --detach --wait --wait-timeout 180 pgadmin

pgadmin-down:
	bash scripts/compose.sh stop pgadmin
	bash scripts/compose.sh rm --force pgadmin

pgadmin-acceptance:
	bash scripts/pgadmin-acceptance.sh

acceptance:
	bash scripts/acceptance.sh

rpo-acceptance:
	bash scripts/rpo-acceptance.sh

backup-init:
	bash scripts/backup.sh init

backup-check:
	bash scripts/backup.sh check

backup:
	bash scripts/backup.sh full

backup-info:
	bash scripts/backup.sh info

backup-verify:
	bash scripts/backup.sh verify

backup-health:
	@python3 scripts/backup_health.py

backup-health-acceptance:
	bash scripts/backup-health-acceptance.sh

restore:
	bash scripts/restore.sh restore

restore-time:
	bash scripts/restore.sh time

restore-latest:
	bash scripts/restore.sh latest

restore-up:
	bash scripts/restore.sh start

restore-psql:
	bash scripts/compose.sh exec --user postgres restore psql -X -U postgres -d orders

restore-down:
	bash scripts/compose.sh stop restore
	bash scripts/compose.sh rm --force restore
