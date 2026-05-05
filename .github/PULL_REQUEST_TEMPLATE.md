<!-- Thanks for the contribution! Most submissions can also go through an
issue form (see .github/ISSUE_TEMPLATE/) which is friendlier for non-edit
proposals. -->

## Type of change
<!-- Pick one. Delete the others. -->

- [ ] **Pin add** — appending to `sources/pins/{block,allow}.txt`
- [ ] **URL source add** — appending to `sources/{block,allow}_urls.txt`
- [ ] **URL source remove / obsolete** — moving to `sources/obsolete/`
- [ ] **Pipeline change** — modifying scripts under `pipeline/`
- [ ] **Documentation only**
- [ ] **Other** (describe below)

## Description / rationale
<!-- Why is this change needed? Link any related issues with `Fixes #123` so
they auto-close on merge. -->

## Validation
<!-- Required for any change touching `sources/pins/*` or `sources/*_urls.txt`.
The CI test workflow runs the validator and shellcheck automatically; please
also run them locally. -->

- [ ] `python3 pipeline/tests/python/test_validate.py` passes
- [ ] `bash pipeline/tests/bash/test_reconcile_guard.sh` passes
- [ ] `python3 pipeline/extract-pins.py` reports 0 rejections (only if you
      changed `sources/pins/*`)

## Pin / list provenance
<!-- For pin additions: short note on why each entry deserves to be pinned.
For URL list additions: source maintainer + license + update frequency. -->

## Maintainer checklist
<!-- For maintainers, before merging. -->

- [ ] CI green
- [ ] Validation report has 0 rejections
- [ ] Provenance is sufficient (evidence linked in PR or referenced issue)
- [ ] Auto-merge label applied if appropriate
