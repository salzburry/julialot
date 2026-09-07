#!/usr/bin/env python3
"""Executes the SQL the modules emit, against synthetic data, and checks numbers.

Everything else in the suite reads text: the source, or the emitted statement.
Text cannot tell you that a rate is divided by 365 instead of 365.25, that a
GROUP BY lost LOT_NUM, or that a re-run doubles every count. Mutation testing
put the suite's kill rate at 12% for exactly that reason.

So this runs the statements. It cannot run Spark, so it transpiles each one to
DuckDB with sqlglot and executes it against tiny fixture tables whose answers
are worked out by hand in tests/fixtures/EXPECTED.md. What it checks is
numbers, not text.

The transpile is the compromise, and it is a real one: DuckDB is not Spark, and
a statement Spark would reject can still run here. It is complementary to
parse_sql.py, not a replacement for a run against the warehouse.

Usage:  run_duckdb.py <emitted.sql> <staged-dir> <fixture-dir> [prefix]

`prefix` is OBJECT_PREFIX, which sits between the schema and the table name.
The golden queries are written without it and it is substituted in, so the
same expectations hold whatever a run is configured to call its tables.
"""
import csv, os, re, sys

DELIM = "-- @@STMT "

# CDM columns Optum stores as CHARACTER despite looking numeric.
STRING_COLUMNS = [
    "ICD_FLAG", "DIAG_POSITION", "POS", "RVNU_CD", "PROC_CD", "BILL_PROC_CD",
    "LOC_CD", "TOS_CD", "CONF_ID", "YRDOB", "LOS", "NDC", "DAYS_SUP",
    "DIAG1", "DIAG2", "DIAG3", "DIAG4", "DIAG5",
]
# Statements this harness does not execute, with the reason. Kept short and
# explicit: a silently skipped statement is an unchecked statement.
SKIP = {
    # MERGE INTO is Delta/Spark; DuckDB's MERGE has different syntax and this
    # one only backfills a display column.
    "MERGE INTO": "MERGE is Delta-specific",
}


def read_statements(path):
    out, tag, buf = [], None, []
    for line in open(path).read().splitlines():
        if line.startswith(DELIM):
            if tag is not None:
                out.append((tag, "\n".join(buf)))
            tag, buf = line[len(DELIM):].strip(), []
        else:
            buf.append(line)
    if tag is not None:
        out.append((tag, "\n".join(buf)))
    return [(t, s) for t, s in out if s.strip()]


def load_fixtures(con, fixture_dir, prefix=""):
    """Creates the source tables. Names match what cdm_src()/lot_tbl() emit."""
    con.execute("CREATE SCHEMA IF NOT EXISTS clnprw_optum")
    con.execute("CREATE SCHEMA IF NOT EXISTS wk")
    quarter = "2026q1"
    # file stem -> the name the SQL refers to
    mapping = {
        "t_member_enrollment": f"clnprw_optum.t_member_enrollment_{quarter}",
        # The fixture stems are the PHYSICAL CDM names, not the short names
        # the modules use. They differ - med_diagnosis, not diagnosis - and a
        # fixture named after the short name would make the harness agree with
        # a wrong table name instead of catching it.
        "t_med_diagnosis":     f"clnprw_optum.t_med_diagnosis_{quarter}",
        "t_medical":           f"clnprw_optum.t_medical_{quarter}",
        "t_confinement":       f"clnprw_optum.t_confinement_{quarter}",
        "t_rx":                f"clnprw_optum.t_rx_{quarter}",
        # lot_tbl() carries OBJECT_PREFIX too.
        "LOT_LONG_FINAL":      "wk.%sLOT_LONG_FINAL" % prefix,
        "ndmm_NDMM_COHORT":    "ndmm_NDMM_COHORT",
    }
    for stem, target in mapping.items():
        path = os.path.join(fixture_dir, stem + ".csv")
        if not os.path.exists(path):
            continue
        # Types are sniffed, not forced to VARCHAR: the CDM's dates are dates,
        # and a fixture that hands every column over as a string lets a
        # missing cast in the real SQL pass here and fail on Spark. The
        # exceptions are the CDM columns Optum stores as CHARACTER even though
        # they look numeric - ICD_FLAG is '9' or '10', POS and the revenue and
        # procedure codes are zero-padded - and sniffing those as integers
        # would let a trim() that Spark accepts fail here for the wrong reason.
        with open(path) as fh:
            header = fh.readline().strip().split(",")
        present = [c for c in STRING_COLUMNS if c in header]
        types = ""
        if present:
            types = ", types={%s}" % ", ".join(
                "'%s': 'VARCHAR'" % c for c in present)
        con.execute(
            f"CREATE OR REPLACE TABLE {target} AS "
            f"SELECT * FROM read_csv('{path}', header=true, "
            f"nullstr='', sample_size=-1{types})")
    return mapping


def load_staged(con, staged_dir):
    """The code-list frames register_codelist_view() would have copy_to'd."""
    if not os.path.isdir(staged_dir):
        return
    for f in sorted(os.listdir(staged_dir)):
        if not f.endswith(".csv"):
            continue
        name = f[:-4]
        con.execute(
            f"CREATE OR REPLACE TABLE {name} AS "
            f"SELECT * FROM read_csv('{os.path.join(staged_dir, f)}', "
            f"header=true, all_varchar=true)")


def to_duckdb(sql):
    """Spark -> DuckDB, plus the rewrites sqlglot does not do for us."""
    import sqlglot
    # Three-part names: DuckDB has no `hive_metastore` catalog here.
    sql = sql.replace("hive_metastore.", "")
    # Spark's `LATERAL VIEW explode(map(...))` becomes a DuckDB UNNEST over a
    # struct list. It is lifted out BEFORE transpiling and put back after: the
    # replacement is DuckDB syntax, and handing DuckDB struct literals to
    # sqlglot's Spark parser is a parse error.
    sql, lifted = lift_lateral(sql)
    out = sqlglot.transpile(sql, read="spark", write="duckdb")[0]
    for token, repl in lifted.items():
        out = re.sub(r",?\s*\b%s\b(?:\s+AS)?\s+\w+" % token, " " + repl, out)
    # DuckDB spells the null-safe comparison IS NOT DISTINCT FROM.
    out = out.replace("<=>", "IS NOT DISTINCT FROM")
    return out


def _match_paren(sql, open_idx):
    """Index just past the `)` matching the `(` at open_idx."""
    depth, i, inq = 0, open_idx, False
    while i < len(sql):
        ch = sql[i]
        if ch == "'":
            inq = not inq
        elif not inq:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return i + 1
        i += 1
    raise ValueError("unbalanced parentheses")


def lift_lateral(sql):
    """`LATERAL VIEW explode(...) alias AS cols` -> a DuckDB UNNEST.

    Scanned rather than matched with a regex: the map body contains nested
    parentheses (every value is a CASE expression), and a non-greedy `.*?`
    stops at the first `))` inside one.
    """
    marker = "LATERAL VIEW explode("
    lifted, n = {}, 0
    while True:
        at = sql.find(marker)
        if at < 0:
            return sql, lifted
        open_idx = at + len(marker) - 1
        close = _match_paren(sql, open_idx)
        inner = sql[open_idx + 1:close - 1].strip()
        # `alias AS c1, c2` (map) or `alias AS c1` (array)
        tail = sql[close:]
        mt = re.match(r"\s*(\w+)\s+AS\s+(\w+)\s*(?:,\s*(\w+))?", tail,
                      re.I)
        if not mt:
            raise ValueError("cannot read the LATERAL VIEW alias: " + tail[:60])
        alias, c1, c2 = mt.group(1), mt.group(2), mt.group(3)
        rest = tail[mt.end():]

        if inner.lower().startswith("map(") and c2:
            body = inner[inner.index("(") + 1:_match_paren(inner, inner.index("(")) - 1]
            parts = split_top_level(body)
            pairs = [(parts[i], parts[i + 1]) for i in range(0, len(parts) - 1, 2)]
            # A LATERAL VALUES list, not UNNEST of a struct array: DuckDB's
            # UNNEST over structs yields one struct column, so a two-column
            # alias does not bind. VALUES gives the two named columns the
            # Spark original produces.
            vals = ", ".join("(%s, %s)" % (k.strip(), v.strip())
                             for k, v in pairs)
            repl = (", LATERAL (SELECT * FROM (VALUES {v}) AS __m({c1}, {c2})) "
                    "AS {a}".format(v=vals, c1=c1, c2=c2, a=alias))
        elif inner.lower().startswith("array("):
            body = inner[inner.index("(") + 1:_match_paren(inner, inner.index("(")) - 1]
            repl = (", LATERAL (SELECT unnest([{b}]) AS {c}) AS {a}"
                    .format(b=body, a=alias, c=c1))
        else:
            repl = ", UNNEST({b}) AS {a}({c})".format(b=inner, a=alias, c=c1)
        token = "__LV%d__" % n
        n += 1
        lifted[token] = repl.lstrip(", ")
        sql = sql[:at] + ", " + token + " " + alias + " " + rest


def split_top_level(s):
    """Split on commas not inside parens or quotes."""
    out, depth, cur, inq = [], 0, [], False
    for ch in s:
        if ch == "'":
            inq = not inq
        if not inq:
            if ch in "([":
                depth += 1
            elif ch in ")]":
                depth -= 1
            elif ch == "," and depth == 0:
                out.append("".join(cur)); cur = []; continue
        cur.append(ch)
    out.append("".join(cur))
    return out


def main():
    emitted, staged_dir, fixture_dir = sys.argv[1], sys.argv[2], sys.argv[3]
    prefix = sys.argv[4] if len(sys.argv) > 4 else ""
    try:
        import duckdb, sqlglot  # noqa: F401
    except ImportError as e:
        print("SKIP: %s is not installed; the emitted SQL was not executed." % e.name)
        return 0

    con = duckdb.connect()
    con.execute("SET TimeZone='UTC'")
    load_fixtures(con, fixture_dir, prefix)
    load_staged(con, staged_dir)

    statements = read_statements(emitted)
    ran, skipped, failed = 0, [], []
    for i, (tag, sql) in enumerate(statements):
        reason = next((r for k, r in SKIP.items() if k in sql), None)
        if reason:
            skipped.append((i, tag, reason))
            continue
        try:
            con.execute(to_duckdb(sql))
            ran += 1
        except Exception as e:
            failed.append((i, tag, str(e).splitlines()[0], sql))

    print("executed %d statement(s), %d skipped, %d failed"
          % (ran, len(skipped), len(failed)))
    for i, tag, reason in skipped:
        print("  skip #%d [%s]: %s" % (i, tag, reason))
    for i, tag, msg, sql in failed:
        print("\n--- FAILED #%d [%s]\n    %s" % (i, tag, msg))
        print("\n".join("    " + l for l in sql.splitlines()[:12]))
    if failed:
        return 1
    rc = check(con, prefix)
    return rerun(con, statements, prefix) or rc


def rerun(con, statements, prefix=""):
    """Runs the whole script again and checks nothing doubled.

    The package's header promises it can be "re-run against a finished LOT run
    as often as needed". A module that stops clearing its scope before writing
    keeps that promise syntactically and doubles every count, person-year and
    rate, with no error anywhere. Nothing that reads text can see it.
    """
    from expectations import RERUN_STABLE_TABLES
    tables = [qualify(t, prefix) for t in RERUN_STABLE_TABLES]
    before = {t: con.execute("SELECT count(*) FROM " + t).fetchone()[0]
              for t in tables}
    for tag, sql in statements:
        if any(k in sql for k in SKIP):
            continue
        con.execute(to_duckdb(sql))
    bad = []
    for t in tables:
        after = con.execute("SELECT count(*) FROM " + t).fetchone()[0]
        if after != before[t]:
            bad.append((t, before[t], after))
    print("re-ran the script: %d of %d table(s) changed row count"
          % (len(bad), len(tables)))
    for t, b, a in bad:
        print("  %-28s %d rows -> %d after a second run" % (t, b, a))
    return 1 if bad else 0


def qualify(sql, prefix):
    """Put OBJECT_PREFIX back between the schema and the table name."""
    return sql.replace("wk.S_", "wk." + prefix + "S_") if prefix else sql


def check(con, prefix=""):
    """The golden numbers. tests/fixtures/EXPECTED.md derives every one."""
    from expectations import EXPECTATIONS
    bad = []
    for name, sql, want in EXPECTATIONS:
        try:
            got = con.execute(qualify(sql, prefix)).fetchall()
        except Exception as e:
            bad.append((name, "query failed: " + str(e).splitlines()[0], want))
            continue
        got = [tuple(r) for r in got]
        want = [tuple(r) for r in want]
        if got != want:
            bad.append((name, got, want))
    print("checked %d golden number(s), %d wrong" % (len(EXPECTATIONS), len(bad)))
    for name, got, want in bad:
        print("\n--- WRONG: %s\n    got  %r\n    want %r" % (name, got, want))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    sys.exit(main())
