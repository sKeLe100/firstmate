# Roundtable instrumentation

A fleet design-review roundtable must review each registered project from a
fresh, generated picture, never a hand-maintained document that can rot, and
must disclose exactly what it actually read. These two scripts and one marker
file are that contract's mechanics; the recurring roundtable task body (data-
side) is what invokes them.

## Procedure

For every registered project (`data/projects.md`), a roundtable:

1. Generates a fact sheet: `bin/fm-roundtable-factsheet.sh <project-clone-path>`.
   With no `--since`, it reports a delta against that project's last recorded
   mark, if one exists. Read-only, no network, seconds per project.
2. Grills the project against that fact sheet, reading whichever files the
   fact sheet's tree and doc listing point to (never the fact sheet's own
   output as a substitute for reading the code).
3. Logs every file it actually read for that project.
4. Ends the roundtable report with, per project:
   - the coverage ledger: `bin/fm-roundtable-coverage.sh <project-clone-path> <file>...`
     passing the logged read list.
   - an updated mark: rerun the fact sheet with `--mark` to record this
     review's HEAD as the baseline for the next roundtable's delta.

## Files

- `bin/fm-roundtable-factsheet.sh` - the fact sheet generator (see its header
  for the exact `--since`/`--mark` contract).
- `bin/fm-roundtable-coverage.sh` - the coverage ledger, walking the same
  tracked-file tree as the fact sheet so its "N of M files" always lines up.
- `bin/fm-roundtable-lib.sh` - the shared tree-walk both scripts source.
- `data/roundtable-marks.tsv` - one row per project: `project<TAB>head_sha<TAB>iso_date`,
  the HEAD each project was last reviewed at. Local, gitignored, updated only
  via `--mark`.

Both scripts read only the git object database at each project's `HEAD` (via
`git ls-tree`), so results are deterministic across a dirty working tree and
require no network access.
