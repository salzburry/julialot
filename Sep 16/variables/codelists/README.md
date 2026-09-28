# Code lists

The shapes of the eleven code lists this package reads, shipped so the folder is
complete on its own. **The codes are blank.** They come from the protocol's
Annexes 2, 3 and 7, from Quan et al. 2011, from a study decision (the ED
construction), or from the production files the cohort and LOT builds already
read. `../CODELISTS.md` §4 has every file: its columns, what it is matched
against, which module reads it, what is filled here and where its codes come
from.

A blank code column is not a gap the run papers over. The loader refuses a file
with an unfilled row and names the concepts, because a rate of zero for want of
a code list is indistinguishable downstream from a rate of zero for want of
events. So these files are a to-do list the code checks rather than defaults
anything could quietly run on.

The preflight **loads** each file the selected modules need rather than
checking that its path exists, so a run pointed at this directory finds what is
unfilled before the connection is opened: under `MODULES=all` the modules that
need an unfilled list are left out by name and the rest run; a module named in
`MODULES` stops the run.

`CODELIST_DIR` blank means this directory. On production, point it at the real
one:

```
CODELIST_DIR=/mnt/code/codelist Rscript build.R
```

The two `safety_events.csv` rows the protocol types both acute and chronic stop
the safety module before its codes do (`../CODELISTS.md` §4, notes).

## Not these: `../tests/fixtures/codelists/`

The test harness ships its own filled miniatures of all eleven files, so it can
run the modules that need one. Those are dummy codes chosen to exercise the
loader and the SQL. They are not codes to run a study on, and nothing outside
`tests/` reads them.
