.PHONY: setup check image up psql down acceptance backup-init backup-check backup backup-info backup-verify

setup:
	bash scripts/setup.sh

check:
	@for script in scripts/*.sh; do bash -n "$$script" || exit; done
	shellcheck scripts/*.sh
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
	bash scripts/compose.sh down

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
