.PHONY: setup check up psql down acceptance

setup:
	bash scripts/setup.sh

check:
	@for script in scripts/*.sh; do bash -n "$$script" || exit; done
	shellcheck scripts/*.sh
	bash scripts/compose.sh config --quiet
	git diff --check

up: setup
	bash scripts/compose.sh up --detach --wait --wait-timeout 120

psql:
	bash scripts/compose.sh exec --user postgres postgres psql -X -U postgres -d orders

down:
	bash scripts/compose.sh down

acceptance:
	bash scripts/acceptance.sh
