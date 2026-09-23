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
permissions and one fixed date, so the archive is byte-identical **for the
same staged bytes** — pack twice from one working tree and the hashes match,
which is what lets two people compare and conclude something.

Not across checkouts of the same commit, which is a stronger claim and a
false one: this copies working-tree bytes, and a checkout with
`core.autocrlf=true` has CRLF on disk where the object store has LF. The same
commit then stages different bytes. Fixing that would mean rewriting content
on the way through, which is the one thing this must not do — normalise the
checkouts instead.

**The identity patterns are not written down.** Writing the builder's name
into the scanner puts it in the repository for good — the thing the scan
exists to prevent, one folder along — and it goes stale the moment somebody
else runs it. So that half is derived at run time from `git config` and the
remote, and the file names nobody. If none of it can be read the scan would
look for nobody and pass for that reason, so it refuses;
`PACK_ALLOW_NO_IDENTITY=TRUE` says you meant it. The sibling delivery folders
are read off the repository for the same reason a list would go stale.

**What is NOT derived, and why it matters.** The assistant's name and its
maker's are in the *structural* list, not the identity one. They were briefly
in neither by name: they were caught only while the runner's git identity
happened to be the assistant's, which it is in the container that builds this
and is not on the desk it is handed over from. A delivery should never name
what wrote it whoever packs it, so that rule does not depend on who does.
Anything else in the same class — another tool, another account — belongs
beside them or in `PACK_BANNED_EXTRA`, not in the derived half.

**A short name will not flood you with false positives.** *Every* derived
token is word-bounded — the name, the email's local part, and the account and
repository taken off the remote — so a three-letter one does not match inside
`announce` or `channel`. Nothing is given up by that: a token inside a *path*
is caught by the path patterns and one inside an *address* by the address
pattern. The tool answers a false positive by refusing to write anything, so
the cost of one falls on the person trying to hand work over, which is the
wrong place for it.

**A run that stops changes nothing.** The output directory is created after
the target check, not before, so a refused run leaves no empty directory
behind — which matters because the standalone-folder check reads any
top-level directory as another delivery. The archive is built beside the
previous one and moved onto it only once it is complete, so a scan finding, a
staging failure or a half-written zip leaves the last archive that *was* handed
over exactly as it was. It is the only copy of it there is.

**One spelling for every path.** The guard on the single destructive call
compares resolved paths as strings, so every alias has to be folded away
before the comparison: Windows keeps a `\\?\` namespace prefix through
`realpath`, and without folding it `\\?\<delivery>` and `<delivery>` compare
as two different directories — which is enough to get the delivery itself
accepted as a staging tree. Case and separator are folded the same way, on the
platforms where they are aliases too.

**`--selftest` is what makes a pass mean anything.** It plants a file for
every pattern and requires each to be reported, requires a clean file not to
be, and requires a file that is not text to be reported rather than silently
skipped. It drives the *real* identity helper with a pretend identity rather
than rebuilding its patterns alongside it — a test that builds the pattern it
then checks is a test of the copy. And it runs the script end to end for the
two claims that are about what a run leaves behind: a refusal writes nothing,
and a refusal does not cost you the previous archive. Those two do pack, into
a throwaway directory under a throwaway name, because the claim is about what
a run leaves on disk and only a run can answer it. CI runs the selftest; it
does not produce a deliverable, having no business inventing a name for
somebody's.

Settings are documented at the top of the script: `STUDY_FOLDER`, `PACK_NAME`,
`PACK_OUT`, `PACK_STAMP` (defaults to the delivery folder's own last commit
date — reproducible from any clone, and not a clock) and `PACK_BANNED_EXTRA`.
