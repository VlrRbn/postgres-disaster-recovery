.DEFAULT_GOAL := help

.PHONY: help stop-all
.PHONY: alerts-setup alerts-acceptance
.PHONY: replication-tls-setup
.PHONY: setup check image up psql down acceptance backup-init backup-check backup backup-info backup-verify backup-health backup-health-acceptance restore restore-time restore-latest-wal restore-up restore-psql restore-down pgadmin-up pgadmin-down pgadmin-acceptance rpo-acceptance s3-setup s3-up s3-down s3-psql s3-backup s3-backup-info s3-backup-check s3-backup-health s3-acceptance s3-restore s3-restore-time s3-restore-latest-wal s3-restore-up s3-restore-psql s3-restore-down replication-up replication-down replication-primary-psql replication-standby-psql replication-status replication-acceptance replication-switchover replication-rejoin
.PHONY: schedule-install schedule-enable schedule-disable schedule-remove schedule-status schedule-check schedule-acceptance scheduled-backup scheduled-backup-health

##@ Overview
help: ## Show commands grouped by purpose (also the default make target)
	@awk 'BEGIN {FS = ":.*## "} /^##@ / {printf "\n%s\n", substr($$0, 5)} /^[a-zA-Z0-9_-]+:.*## / {printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

stop-all: ## Disable installed project timers and stop all containers from this checkout; retain data
	bash scripts/compose.sh --stop-all

##@ Local setup
setup: ## Generate or preserve the local database password
	bash scripts/setup.sh

##@ Validation
check: ## Validate scripts, unit tests, Compose files and systemd definitions
	@for script in scripts/*.sh terraform/ec2-recovery/user-data.sh; do bash -n "$$script" || exit; done
	shellcheck scripts/*.sh terraform/ec2-recovery/user-data.sh
	python3 -m unittest discover -s tests -p 'test_*.py' -v
	bash scripts/compose.sh config --quiet
	PGDR_REPOSITORY=s3 bash scripts/compose.sh config --quiet
	PGDR_REPOSITORY=s3 PGDR_S3_FIXTURE=1 PGDR_S3_DIR=.local/s3 bash scripts/compose.sh config --quiet
	bash scripts/compose.sh --replication config --quiet
	$(MAKE) --no-print-directory schedule-check
	git diff --check

##@ Scheduling
schedule-check: ## Validate systemd unit files and UTC calendars without installing them
	systemd-analyze --user verify systemd/user/postgres-dr-backup.service systemd/user/postgres-dr-backup.timer systemd/user/postgres-dr-backup-health.service systemd/user/postgres-dr-backup-health.timer
	systemd-analyze calendar '*-*-* 02:00:00 UTC' '*-*-* *:15,45:00 UTC'

schedule-install: ## Install user units and preserve config; leave timers disabled
	bash scripts/setup.sh schedule

schedule-enable: ## Enable daily backup and thirty-minute health timers
	systemctl --user enable --now postgres-dr-backup.timer postgres-dr-backup-health.timer

schedule-disable: ## Disable timers; allow running jobs to finish
	bash scripts/setup.sh schedule-disable

schedule-remove: schedule-disable ## Remove idle installed units; retain config and backups
	bash scripts/setup.sh schedule-remove

schedule-status: ## Show upcoming timer activations and last service results
	@echo 'Next scheduled runs'
	systemctl --user list-timers --all 'postgres-dr-backup*.timer'
	@echo 'Last job results (completed oneshot services are normally inactive)'
	systemctl --user show postgres-dr-backup.service postgres-dr-backup-health.service --property=Id,ActiveState,SubState,Result,ExecMainStatus

scheduled-backup: ## Run a verified local backup through the shared scheduling lock
	bash scripts/backup.sh scheduled-backup

scheduled-backup-health: ## Run JSON backup health through the shared scheduling lock
	@bash scripts/backup.sh scheduled-backup-health

schedule-acceptance: ## Test health and scheduled jobs in a disposable project; no host timers
	bash scripts/backup-health-acceptance.sh --schedule

##@ Alerting
alerts-setup: ## Create private Telegram/SMTP configuration; leave both channels disabled
	python3 scripts/backup_alerts.py setup

alerts-acceptance: ## Verify alert transitions and local TLS Telegram/SMTP fixtures; no external messages
	python3 -m unittest discover -s tests -p 'test_backup_alerts.py' -v

##@ Replication
replication-tls-setup: ## Generate or validate private CA and node certificates; preserve existing keys
	bash scripts/setup.sh replication-tls

replication-up: ## Start or resume the replication topology using saved roles
	bash scripts/replication.sh up

replication-down: ## Remove replication containers/network; retain both databases and control state
	bash scripts/compose.sh --replication down

replication-primary-psql: ## Open SQL on the current writable replication node
	bash scripts/replication.sh primary-psql

replication-standby-psql: ## Open SQL on the current read-only replication node
	bash scripts/replication.sh standby-psql

replication-switchover: ## With writers stopped, fence the old primary and promote its standby
	bash scripts/replication.sh switchover

replication-rejoin: ## Briefly stop the new primary and rejoin the old node read-only
	bash scripts/replication.sh rejoin

replication-status: ## Show database roles, WAL connections, replay and retained WAL
	bash scripts/replication.sh status

replication-acceptance: ## Test streaming, outages, controlled promotion and rejoin
	bash scripts/replication-acceptance.sh

##@ Image
image: ## Build the PostgreSQL image with pgBackRest
	bash scripts/compose.sh build postgres

##@ AWS S3
s3-setup: ## Prepare the private S3 config and database password
	python3 scripts/setup_s3.py
	PGDR_REPOSITORY=s3 bash scripts/setup.sh

s3-up: s3-setup ## Start the S3 primary, initialize its stanza and check WAL delivery
	PGDR_REPOSITORY=s3 bash scripts/compose.sh up --build --force-recreate --detach --wait --wait-timeout 120 postgres
	PGDR_REPOSITORY=s3 bash scripts/backup.sh init

s3-down: ## Remove S3 project containers/network; retain data and S3 backups
	PGDR_REPOSITORY=s3 bash scripts/compose.sh --profile restore down

s3-restore: s3-setup ## Recover an explicit S3 BACKUP_LABEL into an empty target
	PGDR_REPOSITORY=s3 bash scripts/restore.sh restore

s3-restore-time: s3-setup ## Recover S3 BACKUP_LABEL to an inclusive UTC RECOVERY_TIME
	PGDR_REPOSITORY=s3 bash scripts/restore.sh time

s3-restore-latest-wal: s3-setup ## Recover S3 BACKUP_LABEL through available archived WAL
	PGDR_REPOSITORY=s3 bash scripts/restore.sh latest-wal

s3-restore-up: ## Resume existing S3-restored data without a new restore
	PGDR_REPOSITORY=s3 bash scripts/restore.sh start

s3-restore-psql: ## Open SQL in the S3-restored database
	PGDR_REPOSITORY=s3 bash scripts/compose.sh exec --user postgres restore psql -X -U postgres -d orders

s3-restore-down: ## Remove the S3-restored container; retain its data
	PGDR_REPOSITORY=s3 bash scripts/compose.sh stop restore
	PGDR_REPOSITORY=s3 bash scripts/compose.sh rm --force restore

s3-psql: ## Open SQL in the S3 primary
	PGDR_REPOSITORY=s3 bash scripts/compose.sh exec --user postgres postgres psql -X -U postgres -d orders

s3-backup: ## Create and verify a full backup in S3
	PGDR_REPOSITORY=s3 bash scripts/backup.sh full

s3-backup-info: ## Show S3 backups and WAL ranges
	PGDR_REPOSITORY=s3 bash scripts/backup.sh info

s3-backup-check: ## Force and verify current WAL delivery to S3
	PGDR_REPOSITORY=s3 bash scripts/backup.sh check

s3-backup-health: ## Print S3 backup freshness and active WAL delivery as JSON
	@PGDR_REPOSITORY=s3 python3 scripts/backup_health.py

s3-acceptance: ## Test the S3 runtime against a disposable local API fixture
	bash scripts/s3-acceptance.sh

##@ Local database
up: setup ## Start the local primary, initialize its stanza and check WAL delivery
	bash scripts/compose.sh up --build --detach --wait --wait-timeout 120
	bash scripts/backup.sh init

psql: ## Open SQL in the local primary
	bash scripts/compose.sh exec --user postgres postgres psql -X -U postgres -d orders

down: ## Remove local primary, restore and UI containers/network; retain data
	bash scripts/compose.sh --profile restore --profile tools down

##@ Database interface
pgadmin-up: up ## Start the local primary and optional loopback pgAdmin interface
	bash scripts/setup.sh pgadmin
	bash scripts/compose.sh up --no-build --detach --wait --wait-timeout 180 pgadmin

pgadmin-down: ## Remove only pgAdmin; retain its settings and databases
	bash scripts/compose.sh stop pgadmin
	bash scripts/compose.sh rm --force pgadmin

pgadmin-acceptance: ## Test pgAdmin login and database access in a disposable project
	bash scripts/pgadmin-acceptance.sh

##@ Acceptance
acceptance: ## Test local persistence, backup, physical restore, PITR and failure detection
	bash scripts/acceptance.sh

rpo-acceptance: ## Measure acknowledged loss during an archive outage
	bash scripts/rpo-acceptance.sh

##@ Local backups
backup-init: ## Initialize the local stanza and check WAL archiving
	bash scripts/backup.sh init

backup-check: ## Force a WAL switch and verify archive delivery
	bash scripts/backup.sh check

backup: ## Create a full local backup and verify repository integrity
	bash scripts/backup.sh full

backup-info: ## Show local backups and archived WAL ranges
	bash scripts/backup.sh info

backup-verify: ## Verify existing backup integrity; reject empty or damaged repositories
	bash scripts/backup.sh verify

backup-health: ## Print local backup freshness and active WAL delivery as JSON
	@python3 scripts/backup_health.py

backup-health-acceptance: ## Test missing/stale backups, archive outages and health recovery
	bash scripts/backup-health-acceptance.sh

##@ Local restore
restore: ## Recover explicit BACKUP_LABEL into an empty local target
	bash scripts/restore.sh restore

restore-time: ## Recover BACKUP_LABEL to an inclusive UTC RECOVERY_TIME
	bash scripts/restore.sh time

restore-latest-wal: ## Recover BACKUP_LABEL through available archived WAL
	bash scripts/restore.sh latest-wal

restore-up: ## Resume the existing restored local database
	bash scripts/restore.sh start

restore-psql: ## Open SQL in the restored local database
	bash scripts/compose.sh exec --user postgres restore psql -X -U postgres -d orders

restore-down: ## Remove the restored container; retain restored data
	bash scripts/compose.sh stop restore
	bash scripts/compose.sh rm --force restore
