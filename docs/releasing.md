# Release Procedure

A release marks a completed capability from the delivery roadmap. The tag must
identify a merged commit on `main` whose required validation has passed.

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
make acceptance
git status --short
```

The working tree must be clean, and `HEAD` must identify the commit whose CI
passed. If the candidate changes, repeat validation for the new commit.

## Tag And Publication

Create an annotated tag on the verified main commit. For the Local PostgreSQL
Foundation release:

```bash
git tag -a v0.1.0 -m 'v0.1.0: local PostgreSQL foundation'
git push origin v0.1.0
```

Create a GitHub Release from that tag using the corresponding release notes.
Tag the merged commit because a squash merge produces a different commit from
its source branch. Never move a published tag; publish a new version for fixes.
