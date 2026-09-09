#!/usr/bin/env python3
"""Runs the QC checks against planted data, and reports what each one counted.

The rest of the QC suite reads the checks as TEXT: generated with fake table
names and inspected. Text cannot tell you that a WHERE can never be true, that
a predicate was inverted, or that a check lost the half of its condition that
made it bite. A check that cannot fail reports "pass" on a real defect for
ever, and these are the checks that decide whether a LOT build is trustworthy.

So this runs them. It cannot run Spark, so it transpiles each check to DuckDB
with sqlglot and executes it against a tiny fixture - once clean, where the
check must count nothing, and once with the defect that check describes planted
in it, where it must count that.

The transpile is a real compromise: DuckDB is not Spark, and a statement Spark
would reject can still run here. Complementary to the text tests, not a
replacement for a run against the warehouse.

Usage:  run_duckdb.py <cases.json>

cases.json: {"table": "...", "columns": {...}, "clean": [row, ...],
             "cases": [{"id","sql","planted":[row,...]}, ...]}
Prints one TSV line per case: id, n_clean, n_planted, detail, error.
"""
import json, sys

try:
    import duckdb, sqlglot
except ImportError as ex:                       # pragma: no cover
    print("SKIP\t" + str(ex))
    sys.exit(0)


def load(spec):
    con = duckdb.connect()
    cols = ", ".join(f'"{c}" {t}' for c, t in spec["columns"].items())
    con.execute(f'CREATE TABLE "{spec["table"]}" ({cols})')
    return con


def fill(con, spec, rows):
    con.execute(f'DELETE FROM "{spec["table"]}"')
    names = list(spec["columns"])
    for r in rows:
        vals = [r.get(n) for n in names]
        ph = ", ".join("?" for _ in names)
        q = ", ".join(f'"{n}"' for n in names)
        con.execute(f'INSERT INTO "{spec["table"]}" ({q}) VALUES ({ph})', vals)


def run(con, sql):
    # The checks are written for Spark. Transpiling is the only way to execute
    # them here, and a failure to transpile is reported rather than skipped -
    # a check nobody can run is not a check that passed.
    duck = sqlglot.transpile(sql, read="spark", write="duckdb")[0]
    row = con.execute(duck).fetchone()
    return (row[0], row[1]) if row else (None, None)


def main():
    spec = json.load(open(sys.argv[1]))
    con = load(spec)
    for case in spec["cases"]:
        try:
            fill(con, spec, spec["clean"])
            n_clean, _ = run(con, case["sql"])
            fill(con, spec, spec["clean"] + case["planted"])
            n_planted, detail = run(con, case["sql"])
            print("\t".join([case["id"], str(n_clean), str(n_planted),
                             str(detail or ""), ""]))
        except Exception as ex:
            print("\t".join([case["id"], "", "", "", str(ex).replace("\n", " ")]))


if __name__ == "__main__":
    main()
