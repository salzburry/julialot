# Packing a delivery

A delivery leaves here as a zip and is opened by someone with no access to
this repository. `pack_delivery.py` is what writes it, and its job is as much
refusal as packaging.

```
STUDY_FOLDER="Sep 16" PACK_NAME=sep_16_2026 python3 validation/package/pack_delivery.py
python3 validation/package/pack_delivery.py --selftest
```

It copies what git tracks — nothing is rewritten on the way through, so the
archive and the repository cannot disagree — then scans the copy, and writes
the zip only if the scan is clean. A finding exits non-zero with no archive
written, because a warning at the end of a long run is a warning nobody reads.

**Two things can leak.** The content can name the machine, the account or the
working history that built it; and the archive's own fields can, whatever the
content says. A default zip entry records the kind of system that wrote it and
the file's permission bits, and carries each file's modification time — the
build machine's clock and timezone, and a spread of them is a working history
nobody asked for. Every entry is written as a plain FAT entry with no
permissions and one fixed date, so the archive is byte-identical from any
checkout of the same tree, which is what lets two people compare hashes and
conclude something.

**The identity patterns are not written down.** Writing the builder's name
into the scanner puts it in the repository for good — the thing the scan
exists to prevent, one folder along — and it goes stale the moment somebody
else runs it. So that half is derived at run time from `git config` and the
remote, and the file names nobody. If none of it can be read the scan would
look for nobody and pass for that reason, so it refuses;
`PACK_ALLOW_NO_IDENTITY=TRUE` says you meant it. The sibling delivery folders
are read off the repository for the same reason a list would go stale.

**`--selftest` is what makes a pass mean anything.** It plants a file for
every pattern and requires each to be reported, requires a clean file not to
be, and requires a file that is not text to be reported rather than silently
skipped. CI runs it; the pack itself is not run in CI, which has no business
inventing a name for somebody's deliverable.

Settings are documented at the top of the script: `STUDY_FOLDER`, `PACK_NAME`,
`PACK_OUT`, `PACK_STAMP` (defaults to the delivery folder's own last commit
date — reproducible from any clone, and not a clock) and `PACK_BANNED_EXTRA`.
