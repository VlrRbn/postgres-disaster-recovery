# Contributing

Changes are delivered as focused pull requests with reproducible validation.
Use capability names from the [delivery roadmap](docs/roadmap.md) in public
commits, PRs, and release notes.

## Local Development

Follow the [README](README.md) for prerequisites and setup. Create a feature
branch from the latest `main`, then implement one complete change with its
relevant checks and documentation. Sign commits with GPG.

For changes to SQL, Compose, scripts, or CI, run:

```bash
make check
make acceptance
```

The acceptance command operates on a disposable database. For documentation-only
changes, verify commands, links, and formatting; rerun the database scenario when
a documented runtime procedure changes.

## Script Readability

- Keep the execution order visible at the end of a shell script or in Python's
  `main()`. Name functions after complete actions such as preparing a database,
  verifying recovery, or saving a report.
- Show numbered progress stages in long acceptance scenarios. Keep short
  commands compact; a single operation does not need an extra framework.
- Separate CLI argument parsing, data collection, validation, and output when
  they make the main flow difficult to follow.
- Preserve machine-readable stdout: JSON commands print JSON only. Put diagnostic
  messages on stderr and never include passwords, keys, or tokens.
- Reuse existing scripts and local helpers. Validate behavior with the relevant
  disposable acceptance scenarios when restructuring an operational command.

## Pull Requests

Describe the resulting behavior, the reason for the change, and the validation
performed. Include evidence when changing database persistence or recovery
behavior. CI must pass before merge.

Update the capability status only when its acceptance criteria have been
verified. Keep future work in the roadmap and distinguish local validation
from GitHub CI results.

## Evidence Handling

Use synthetic data for database exercises. Keep credentials, local environment
files, database contents, and backups out of Git. Review command output before
including it in a PR or an evidence report.

Acceptance criteria belong in `docs/`. Completed run reports belong in
`evidence/` and describe the tested environment, results, and interpretation.

## Releases

Releases mark completed capabilities on verified commits from `main`.
See the [release procedure](docs/releasing.md) for validation and tag handling.
