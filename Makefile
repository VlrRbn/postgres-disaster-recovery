.PHONY: setup check image up psql down acceptance backup-init backup-check backup backup-info backup-verify restore restore-time restore-up restore-psql restore-down pgadmin-up pgadmin-down pgadmin-acceptance

setup:
	bash scripts/setup.sh

check:
	@for script in scripts/*.sh; do bash -n "$$script" || exit; done
	shellcheck scripts/*.sh
	python3 -m unittest discover -s tests -p 'test_*.py'
	bash scripts/compose.sh config --quiet
	git diff --check

image:
	bash scripts/compose.sh build postgres

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

restore:
	bash scripts/restore.sh restore

restore-time:
	bash scripts/restore.sh time

restore-up:
	bash scripts/restore.sh start

restore-psql:
	bash scripts/compose.sh exec --user postgres restore psql -X -U postgres -d orders

restore-down:
	bash scripts/compose.sh stop restore
	bash scripts/compose.sh rm --force restore
