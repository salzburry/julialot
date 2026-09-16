#!/usr/bin/env python3
"""Parses every statement the R harness emitted, in the Spark dialect.

Reads a file of `-- @@STMT <tag>` delimited statements on stdin or argv[1] and
exits non-zero listing anything that does not parse. Spark's own parser is the
authority; sqlglot is the closest thing available without a cluster, and it
catches the class of defect that shipped: a statement chopped in half, a CTE
list with a comma missing, an unsubstituted placeholder.
"""
import sys

DELIM = "-- @@STMT "

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else None
    text = open(path).read() if path else sys.stdin.read()

    try:
        import sqlglot
    except ImportError:
        print("SKIP: sqlglot is not installed; SQL parsing was not checked.")
        return 0

    stmts, tag, buf = [], None, []
    for line in text.splitlines():
        if line.startswith(DELIM):
            if tag is not None:
                stmts.append((tag, "\n".join(buf)))
            tag, buf = line[len(DELIM):].strip(), []
        else:
            buf.append(line)
    if tag is not None:
        stmts.append((tag, "\n".join(buf)))

    bad = []
    for i, (tag, sql) in enumerate(stmts):
        if not sql.strip():
            continue
        # A leftover sprintf placeholder means a template was never filled in.
        # sqlglot parses `%s` as a modulo expression rather than failing, so it
        # is checked separately.
        for ph in ("%s", "%d", "%1$s"):
            if ph in sql:
                bad.append((i, tag, "unsubstituted placeholder %r" % ph, sql))
                break
        else:
            try:
                sqlglot.parse_one(sql, dialect="spark")
            except Exception as e:
                bad.append((i, tag, str(e).splitlines()[0], sql))

    print("parsed %d statement(s), %d failure(s)" % (len(stmts), len(bad)))
    for i, tag, msg, sql in bad:
        print("\n--- #%d [%s] %s" % (i, tag, msg))
        print("\n".join(sql.splitlines()[:14]))
    return 1 if bad else 0

if __name__ == "__main__":
    sys.exit(main())
