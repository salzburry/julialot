#!/usr/bin/env python3
"""Stage a delivery folder as a flat archive, and refuse to write one that
says where it was built.

    STUDY_FOLDER="Sep 16" PACK_NAME=sep_16_2026 python3 validation/package/pack_delivery.py
    python3 validation/package/pack_delivery.py --selftest

A delivery is handed over as a zip and opened by someone with no access to
this repository. Two things can travel with it that nobody asked for: the
CONTENT can name the machine, the account or the working history that made it,
and the ARCHIVE'S OWN FIELDS can, whatever the content says. This does both
jobs - it copies what git tracks, scans the copy, and writes the zip with its
metadata flattened - and it exits non-zero rather than writing a zip it is
unhappy with, because a warning at the end of a long run is a warning nobody
reads.

Nothing is rewritten on the way through. What is tracked is what ships, so
the archive and the repository cannot disagree; a file that needs changing is
changed in the repository and the scan is what says which.

## Why the identity patterns are not written down here

The obvious way to scan for the builder's name is to write the name in the
scanner. That puts it in the repository for good, which is the thing the scan
exists to prevent one folder along, and it goes stale the moment somebody else
runs it. So the identity half of the list is derived at run time from
`git config` and the remote, and this file names nobody. It also means the
scan is about whoever is running it rather than about one person.

If none of that can be read, the scan is weaker than it looks, and a scan
that is quietly weaker is worse than no scan. It refuses. `PACK_ALLOW_NO_IDENTITY=TRUE`
says you meant it.

## Settings

    STUDY_FOLDER   which delivery to pack. Required where more than one
                   folder could be one, for the reason validation/synthetic
                   refuses to guess.
    PACK_NAME      the archive's root directory and zip stem. Required: this
                   is somebody's deliverable and its name is not ours to
                   invent.
    PACK_OUT       where to write. Defaults to a temporary directory, so a
                   run cannot leave a zip inside the repository.
    PACK_STAMP     the one date every entry carries, YYYY-MM-DD. Defaults to
                   the delivery folder's own last commit date, which is
                   reproducible from any clone and is not a clock.
    PACK_BANNED_EXTRA
                   extra regexes, comma-separated, for a delivery with its
                   own things to keep out.
"""
import os, re, shutil, subprocess, sys, tempfile, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


def git(*args, cwd=REPO):
    """git, or None where it has nothing to say. Never raises: every caller
    here is asking a question that may legitimately have no answer."""
    try:
        out = subprocess.run(["git"] + list(args), cwd=cwd, capture_output=True,
                             text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else None


# ---------------------------------------------------------------------------
# What must not be in a delivery.
#
# Two halves. The STRUCTURAL half is about the shape of a path or a name and
# is the same whoever builds it. The IDENTITY half is about the person and
# the account, and is derived - see the note at the top.


def structural_patterns(src_name):
    """The half that does not depend on who is running this."""
    pats = [
        (r"/home/[A-Za-z0-9._-]+/", "a build path"),
        (r"/root/", "a build path"),
        (r"/Users/[A-Za-z]", "a home directory"),
        # A drive letter, which is ONE letter, so nothing word-like may
        # precede it. That lookbehind is the whole discriminator: it lets
        # C:\work\alice through the net while leaving alone the ":\n" that
        # ends half the error strings in this codebase - in the SOURCE those
        # are a colon, a backslash and an n, and the character before the
        # colon is the last letter of a word. The earlier pattern asked for
        # TWO backslashes instead, which caught a doubled path in a string
        # literal and missed every ordinary one.
        # ...and at least two characters of a path segment after it. The
        # lookbehind alone was not enough: "the rule's:\n" puts an
        # APOSTROPHE before the s, so the s reads as a standalone drive
        # letter and the \n as a separator and a segment. Asking for two
        # characters leaves every escape of that shape alone - the n is
        # followed by a quote - while any real path has a segment worth the
        # name.
        (r"(?<![A-Za-z0-9])[A-Za-z]:[\\/][A-Za-z0-9_.-]{2,}",
         "a Windows path"),
        (r"OneDrive|Documents[\\/]GitHub", "a Windows user folder"),
        (r"/tmp/[A-Za-z0-9._-]*/", "a scratch path"),
        (r"github\.com", "a repository host"),
        (r"Co-Authored-By", "a commit trailer"),
        # Structural, NOT derived. These were caught only while the runner's
        # git identity happened to be the assistant's - which it is in the
        # container that builds this, and is not on the desk it is handed
        # over from. A delivery should never name what wrote it whoever
        # packs it, so the rule does not depend on who does.
        (r"(?i)\bclaude\b", "the assistant"),
        (r"(?i)\banthropic\b", "the assistant's maker"),
        (r"session_[0-9A-Za-z]{10,}", "a session identifier"),
        (r"https?://", "an outside link"),
        (r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", "an email address"),
        (re.escape(src_name) + r"/", "this folder's name in the repository"),
        (r"\.pdf\b", "a document not shipped"),
        (r"\.(?:png|jpe?g|gif|bmp|tiff?|svg|docx?|xlsx?|pptx?|zip)\b",
         "a binary or image file"),
        # The protocol was supplied as a scan with unreadable stretches. The
        # delivery cites the protocol, never the copy it was read from -
        # "scan" alone is the engine's own word for a pass over claims, so
        # the phrases are matched rather than the word.
        (r"scanned copy|scan of the protocol|unreadable in the copy|pages read",
         "the copy a source document was read from"),
        # A personal warehouse schema. usr00000 is the delivery's own
        # placeholder and is what every example should use; GSK2857916 is the
        # study asset and belongs. Anything else of that shape points a
        # reader's session at somebody's real workspace.
        (r"\b(?!usr00000\b|GSK2857916\b)[A-Za-z]{2,5}[0-9]{4,}\b",
         "a real account or schema"),
    ]
    # Every SIBLING delivery, read off the repository rather than listed -
    # a list here would go stale the next time a folder is added, and the
    # folder that gets missed is the one nobody remembers to add.
    for d in sorted(os.listdir(REPO)):
        if d == src_name or d.startswith(".") or not os.path.isdir(os.path.join(REPO, d)):
            continue
        if re.match(r"^[A-Z][a-z]{2} \d{1,2}$", d):
            pats.append((r"\b" + re.escape(d) + r"\b", "another delivery folder"))
    extra = os.environ.get("PACK_BANNED_EXTRA", "").strip()
    for e in [x.strip() for x in extra.split(",") if x.strip()]:
        pats.append((e, "named in PACK_BANNED_EXTRA"))
    return pats


def identity_patterns():
    """The half that is about whoever is running this, derived rather than
    written down. Returns (patterns, what_was_found)."""
    pats, found = [], []
    name = git("config", "user.name")
    email = git("config", "user.email")
    remote = git("config", "--get", "remote.origin.url")
    if name:
        for part in re.split(r"[\s.]+", name):
            if len(part) >= 3:
                # Word-bounded. Unbounded, a short common name matched inside
                # ordinary words - "Ann" in "announce" - and the tool answers
                # a false positive by refusing to write anything, so the cost
                # of one lands on the person trying to hand work over. A name
                # inside a PATH is caught by the path patterns above, and one
                # inside an address by the address pattern, so nothing is
                # given up by asking for the boundary here.
                pats.append((r"(?i)\b" + re.escape(part) + r"\b",
                             "the builder's name"))
                found.append("name")
    if email:
        pats.append(("(?i)" + re.escape(email), "the builder's email"))
        local = email.split("@")[0]
        if len(local) >= 3:
            pats.append(("(?i)" + re.escape(local), "the builder's email"))
        found.append("email")
    if remote:
        # owner and repository out of any remote shape, ssh or https.
        m = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.git)?$", remote)
        if m:
            for g in m.groups():
                if len(g) >= 3:
                    pats.append(("(?i)" + re.escape(g), "the repository or its account"))
            found.append("remote")
    return pats, sorted(set(found))


def scan(tree, patterns):
    """Every line of every text file under `tree` that matches. Binary files
    are skipped here and refused separately - a delivery of text should not
    contain one at all, so silence about it would be the wrong answer."""
    bad = []
    for root, _, fs in os.walk(tree):
        for fn in sorted(fs):
            p = os.path.join(root, fn)
            rel = os.path.relpath(p, tree)
            try:
                s = open(p, encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                bad.append((rel, 0, "not readable as text", ""))
                continue
            lines = s.splitlines()
            for pat, why in patterns:
                for m in re.finditer(pat, s):
                    n = s.count("\n", 0, m.start()) + 1
                    ctx = lines[n - 1].strip()[:120] if n <= len(lines) else ""
                    bad.append((rel, n, why, ctx))
    return bad


SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def safe_target(out_dir, root_name, src):
    """Where the staging tree may go, or a refusal with the reason.

    rmtree is the one destructive thing in this file and it runs before
    anything else does, so every way of aiming it somewhere it should not go
    has to be closed BEFORE it is reached. os.path.join is the trap: an
    ABSOLUTE PACK_NAME discards PACK_OUT entirely, so join(out, "/a/b") is
    "/a/b", and ".." walks out of it. A name is not a name until it has been
    checked to be one.

    Four questions, and the answer to any of them refuses rather than
    repairs. Silently correcting a path somebody typed is how the wrong
    directory gets deleted while the output still looks right.
    """
    if not SAFE_NAME.match(root_name):
        return None, ("PACK_NAME must be a plain archive name - letters, "
                      "digits, dot, dash, underscore - and %r is not. It is "
                      "joined into a path that gets removed before staging, "
                      "and an absolute name or one with '..' in it is not a "
                      "name, it is a different directory." % root_name)
    out = os.path.realpath(out_dir)
    repo = os.path.realpath(REPO)
    if out == repo or out.startswith(repo + os.sep):
        return None, ("PACK_OUT is inside the repository (%s). A run must not "
                      "be able to leave an archive in the tree it packed, and "
                      "must not be able to remove part of it either." % out)
    tree = os.path.realpath(os.path.join(out, root_name))
    if tree != out and not tree.startswith(out + os.sep):
        return None, "the staging tree resolves outside PACK_OUT: " + tree
    if tree == out:
        return None, "the staging tree resolves to PACK_OUT itself"
    src_r = os.path.realpath(src)
    if tree == src_r or tree.startswith(src_r + os.sep) or \
            src_r.startswith(tree + os.sep):
        return None, ("the staging tree overlaps the delivery being packed "
                      "(%s). Nothing is worth removing to make room for a "
                      "copy of itself." % src_r)
    return tree, None


def stage(src, out):
    """What git tracks, minus what never belongs in a handover."""
    files = [f for f in subprocess.check_output(
        ["git", "ls-files", "-z"], cwd=src).decode().split("\0") if f]
    kept, skipped = [], []
    for f in files:
        if f.lower().endswith(".pdf") or "__pycache__" in f:
            skipped.append(f)
            continue
        d = os.path.join(out, f)
        os.makedirs(os.path.dirname(d), exist_ok=True)
        shutil.copy2(os.path.join(src, f), d)
        kept.append(f)
    return kept, skipped


def write_zip(tree, zip_path, root_name, stamp):
    """The archive, with its own fields flattened.

    A zip entry records the kind of system that wrote it and, on a Unix-like
    one, the file's permission bits - so a default archive says "made on Unix,
    mode 644" on every entry. Neither is content anyone needs and both
    describe the machine rather than the delivery, so each entry is written as
    a plain FAT entry with no permissions. Extraction is unaffected: the
    reader applies its own defaults, as it does for any archive made on
    Windows.

    One fixed date, too. An mtime is not a machine name, but it is the build
    machine's clock and its timezone, and a spread of them is a working
    history nobody asked to receive. Fixed, and walked in sorted order, the
    archive is byte-identical for the same STAGED BYTES - so packing twice
    from one working tree gives one hash, and two people can compare.

    Not from the same GIT TREE, which is a stronger claim and a false one.
    This copies working-tree bytes, and a checkout with core.autocrlf=true
    has CRLF on disk where the object store has LF; the same commit then
    stages different bytes and compresses to a different archive. Nothing
    here can fix that without rewriting content on the way through, which is
    the one thing this must not do - what is tracked is what ships. If two
    archives have to match across such checkouts, normalise the checkouts,
    not the packer.
    """
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for root, dirs, fs in sorted(os.walk(tree)):
            dirs.sort(); fs.sort()
            for fn in fs:
                p = os.path.join(root, fn)
                arc = root_name + "/" + os.path.relpath(p, tree).replace(os.sep, "/")
                zi = zipfile.ZipInfo(arc, date_time=stamp)
                zi.create_system = 0      # FAT, so no Unix mode bits travel
                zi.external_attr = 0      # a plain file, no permissions
                zi.compress_type = zipfile.ZIP_DEFLATED
                with open(p, "rb") as fh:
                    z.writestr(zi, fh.read())
                # ...and again after, because writestr() stamps its own 0o600
                # over what it was handed. external_attr lives only in the
                # central directory, written at close from these very objects,
                # so clearing it here is what lands in the file.
                z.infolist()[-1].external_attr = 0


# ---------------------------------------------------------------------------


def selftest():
    """Prove the scan can fail.

    A scan that has never caught anything says nothing about the tree it
    passed. Each pattern gets a file that trips it, and each has to be
    reported; then a clean file has to be reported as clean. The identity
    half is driven with a fixed pretend identity rather than the runner's, so
    the test means the same thing on every machine.
    """
    tmp = tempfile.mkdtemp(prefix="packselftest_")
    pats = structural_patterns("Sep 16") + [
        ("(?i)" + re.escape("Nobody"), "the builder's name"),
        ("(?i)" + re.escape("nobody@example.com"), "the builder's email"),
    ]
    cases = [
        ("home.txt", "see /home/someone/thing"),
        ("root.txt", "/root/build"),
        ("mac.txt", "/Users/a/x"),
        ("win.txt", r"C:/Users/x"),
        # The ordinary form, which the doubled-backslash pattern missed.
        ("win_bs.txt", r"C:\work\alice\clinical.R"),
        ("win2.txt", "OneDrive is here"),
        ("scratch.txt", "/tmp/somewhere/x"),
        ("host.txt", "github.com/x"),
        ("trailer.txt", "Co-Authored-By: someone"),
        ("session.txt", "session_01ABCDEFGHIJ"),
        ("link.txt", "https://example.org"),
        ("mail.txt", "a.person@example.org"),
        ("self.txt", "Sep 16/lot"),
        ("doc.txt", "see protocol.pdf"),
        ("img.txt", "figure.png"),
        ("prov.txt", "a scanned copy of it"),
        ("schema.txt", "usr12345 wrote it"),
        ("name.txt", "built by Nobody"),
        ("email.txt", "nobody@example.com"),
        # The pretend identity above is not the assistant's, so these two
        # can only be caught by the structural half - which is the point of
        # moving them there.
        ("assistant.txt", "generated with Claude"),
        ("maker.txt", "an Anthropic model wrote this"),
    ]
    for fn, body in cases:
        open(os.path.join(tmp, fn), "w", encoding="utf-8").write(body + "\n")
    hits = {rel for rel, _, _, _ in scan(tmp, pats)}
    missed = [fn for fn, _ in cases if fn not in hits]

    clean = tempfile.mkdtemp(prefix="packselfclean_")
    open(os.path.join(clean, "ok.md"), "w", encoding="utf-8").write(
        "The line ends on the added medication, in usr00000, for GSK2857916.\n")
    # A three-letter name is the case that made the boundary necessary: it
    # has to catch the name and leave the words that contain it alone.
    short = [(r"(?i)\b" + re.escape("Ann") + r"\b", "the builder's name")]
    open(os.path.join(clean, "prose.md"), "w", encoding="utf-8").write(
        "The build will announce the channel and the planned tandem.\n")
    # The false positive the drive-letter pattern has to keep avoiding: an R
    # error string ending in a colon and a newline escape.
    # Two shapes from this codebase that the drive-letter pattern has to keep
    # leaving alone. The second is why the lookbehind is not enough on its
    # own: an apostrophe before the s makes it look like a drive letter.
    open(os.path.join(clean, "msg.R"), "w", encoding="utf-8").write(
        'stop("could not read these tables:\\n  ", paste(bad))\n'
        '  "differences between them are not the rule\'s:\\n",\n')
    false_alarms = scan(clean, pats + short)

    binary = tempfile.mkdtemp(prefix="packselfbin_")
    open(os.path.join(binary, "x.bin"), "wb").write(b"\xff\xfe\x00\x01")
    bin_hits = scan(binary, pats)

    shutil.rmtree(tmp); shutil.rmtree(clean); shutil.rmtree(binary)

    # The guard on the one destructive call. Each of these once resolved to a
    # directory that would have been removed before staging began.
    src = os.path.join(REPO, "Sep 16")
    out = tempfile.mkdtemp(prefix="packselfout_")
    attacks = [
        ("an absolute name, which discards PACK_OUT entirely", src),
        ("a relative escape", os.path.join("..", "victim")),
        ("a separator in the name", "a/b"),
        ("an empty name", ""),
        ("a name that is only dots", ".."),
    ]
    let_through = [w for w, n in attacks if safe_target(out, n, src)[0] is not None]
    refused_ok = safe_target(out, "sep_16_2026", src)[0] is not None
    in_repo = safe_target(os.path.join(REPO, "dist"), "x", src)[0] is not None
    shutil.rmtree(out)

    fails = []
    if missed:
        fails.append("these planted cases were NOT caught: " + ", ".join(missed))
    if false_alarms:
        fails.append("a clean file was reported: %s" % (false_alarms[:2],))
    if not bin_hits:
        fails.append("a file that is not text was not reported")
    if let_through:
        fails.append("these would have been removed before staging: "
                     + "; ".join(let_through))
    if not refused_ok:
        fails.append("an ordinary archive name was refused")
    if in_repo:
        fails.append("PACK_OUT inside the repository was allowed")
    for f in fails:
        print("  FAIL  " + f)
    if fails:
        print("\n%d selftest failure(s)" % len(fails))
        return 1
    print("  ok    all %d planted cases are caught" % len(cases))
    print("  ok    a clean file is not")
    print("  ok    ...and a file that is not text is reported rather than skipped")
    print("  ok    all %d ways of aiming rmtree out of bounds are refused"
          % len(attacks))
    print("  ok    ...an ordinary name is not, and PACK_OUT in the repo is")
    print("\nthe scan can fail, so its passing means something")
    return 0


def main():
    if "--selftest" in sys.argv:
        return selftest()

    src_name = os.environ.get("STUDY_FOLDER", "").strip()
    if not src_name:
        raise SystemExit("STUDY_FOLDER names the delivery to pack. More than "
                         "one folder here could be one, and picking for you "
                         "is how the wrong thing gets handed over.")
    src = os.path.join(REPO, src_name)
    if not os.path.isdir(src):
        raise SystemExit("no such delivery folder: " + src_name)

    root_name = os.environ.get("PACK_NAME", "").strip()
    if not root_name:
        raise SystemExit("PACK_NAME is the archive's root directory and zip "
                         "stem. This is somebody's deliverable and its name "
                         "is not ours to invent.")

    stamp_s = os.environ.get("PACK_STAMP", "").strip()
    if not stamp_s:
        stamp_s = (git("log", "-1", "--format=%cd", "--date=format:%Y-%m-%d",
                       "--", src_name) or "")
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", stamp_s):
        raise SystemExit("PACK_STAMP must be YYYY-MM-DD, and the delivery's "
                         "last commit date could not be read to default it. "
                         "Every entry carries one date and it is not the "
                         "clock, so there is nothing safe to fall back to.")
    stamp = tuple(int(x) for x in stamp_s.split("-")) + (0, 0, 0)

    ident, found = identity_patterns()
    if not found and os.environ.get("PACK_ALLOW_NO_IDENTITY", "").upper() != "TRUE":
        raise SystemExit(
            "no name, email or remote could be read from git, so the scan "
            "would look for nobody and pass for that reason. Set git's "
            "user.name and user.email, or PACK_ALLOW_NO_IDENTITY=TRUE if "
            "this really is a tree with no builder to name.")
    print("identity patterns from:", ", ".join(found) or "(none - allowed)")

    out_dir = os.environ.get("PACK_OUT") or tempfile.mkdtemp(prefix="pack_")
    os.makedirs(out_dir, exist_ok=True)
    tree, why = safe_target(out_dir, root_name, src)
    if why:
        raise SystemExit("refusing to pack: " + why)
    zip_path = os.path.join(os.path.realpath(out_dir), root_name + ".zip")
    if os.path.exists(tree): shutil.rmtree(tree)
    if os.path.exists(zip_path): os.remove(zip_path)
    os.makedirs(tree)

    kept, skipped = stage(src, tree)
    print("staged", len(kept), "files;", len(skipped), "skipped", skipped or "")

    bad = scan(tree, structural_patterns(src_name) + ident)
    if bad:
        print("\n%d line(s) name something the delivery should not:" % len(bad))
        for rel, line, why, ctx in bad[:60]:
            print("  %s:%d  (%s)\n      %s" % (rel, line, why, ctx))
        if len(bad) > 60:
            print("  ... and", len(bad) - 60, "more")
        print("\nNo archive written.")
        return 1

    write_zip(tree, zip_path, root_name, stamp)
    print("clean; every entry stamped %s" % stamp_s)
    print(zip_path, os.path.getsize(zip_path), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
