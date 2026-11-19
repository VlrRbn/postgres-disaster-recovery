# Release Procedure

A release marks a verified capability or project baseline from the delivery
roadmap. The tag must identify a merged commit on `main` whose required validation
has passed.

## Version Policy

Starting with `v1.0.0`, the public interface is the documented operational
commands and required configuration names and meanings. Existing invocations
remain compatible within the major version. New optional commands or settings
can be added without changing existing workflows.

Version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- Patch: compatible fixes.
- Minor: compatible functionality additions.
- Major: incompatible changes to the documented interface.

Documentation-only changes can merge without a release. A project baseline
can consolidate previously delivered capabilities, their validation, and an
explicit compatibility contract. Package versions, observed timings, and
deployment-specific identifiers retain their separately documented boundaries.

## Release Preparation

Include release notes in the milestone PR under `docs/releases/`. Describe the
implemented behavior, validation, and known limitations. Merge the PR after
review and successful CI, then confirm that CI passes for the resulting commit
on `main`.

## Release Validation

Update the local branch and verify the release candidate:

```bash
git switch main
git pull --ff-only origin main
make check
PGDR_REPOSITORY=local make acceptance
git status --short
git log -1 --oneline
```

The working tree must be clean, and `HEAD` must identify the commit whose CI
passed. If the candidate changes, repeat the relevant validation and confirm
CI for its exact commit. Required checks are `Foundation checks` and
`S3 infrastructure validation`.

Find the run associated with the candidate and wait for its result:

```bash
gh run list --branch main --commit "$(git rev-parse HEAD)" --limit 5
gh run watch RUN_ID --exit-status
```

Replace `RUN_ID` with the run for that exact commit. A successful source-branch
run does not replace validation of the resulting `main` commit.

## Tag And Publication

Create a GPG-signed annotated tag on the verified main commit.
For the `v1.0.0` baseline, first check that no local or remote tag already exists:

```bash
git tag --list v1.0.0
git ls-remote --tags origin 'refs/tags/v1.0.0*'
```

If a tag exists, inspect it before taking further action. Otherwise, create a
GPG-signed annotated tag on the verified `main` commit, verify its signature,
and publish it:

```bash
git tag -s v1.0.0 -m 'Release v1.0.0'
git tag -v v1.0.0
git push origin v1.0.0

gh release create v1.0.0 \
  --verify-tag \
  --title 'v1.0.0 — PostgreSQL Disaster Recovery' \
  --notes-file docs/releases/v1.0.0.md
```

Tag the merged commit because a squash merge produces a different commit from
its source branch. Never move a published tag; publish a new version for fixes.
