#!/usr/bin/env python3
"""Runs one SQL FRAGMENT at a time, against a table built for it.

tests/run_duckdb.py runs the whole emitted script over the CDM fixtures and
checks golden numbers off the finished tables. That cannot reach a rule the
fixtures never trip: every stratum in them sits under the suppression floor,
so no rate is ever published, and turning the rate formula from a division
into a MULTIPLICATION changed nothing any check could see. The same held for
the confidence interval's z, for the time-to-event boundary, and for the
months divisor.

So the fragments in R/windows.R and R/person_time.R are executed here on their
own, against three or four rows built for each rule. Transpiled from Spark to
DuckDB with sqlglot, so what this checks is the arithmetic, not the dialect.

Usage:  run_expr.py <spec.json>

spec.json: {"tables":  {name: {"columns": {col: type, ...}, "rows": [...]}},
            "queries": [{"id": "...", "sql": "..."}, ...]}

Queries run in order against one connection, so a statement may build
something a later one reads. Prints one TSV line per returned cell:

    <query id>  <row index>  <column>  <value>

and, for a statement that could not be transpiled or run,

    <query id>  ERROR  <message>

so a failure is reported rather than read as an empty result.
"""
import json, sys

try:
    import duckdb, sqlglot
except ImportError as ex:                       # pragma: no cover
    print("SKIP\t" + str(ex))
    sys.exit(0)


def load(spec):
    con = duckdb.connect()
    for name, tab in spec["tables"].items():
        cols = ", ".join(f'"{c}" {ty}' for c, ty in tab["columns"].items())
        con.execute(f'CREATE TABLE "{name}" ({cols})')
    return con


def rows_of(spec):
    return {n: t.get("rows", []) for n, t in spec["tables"].items()}


def fill(con, spec, data):
    """A table absent from `data` is created empty rather than skipped."""
    for name, tab in spec["tables"].items():
        con.execute(f'DELETE FROM "{name}"')
        names = list(tab["columns"])
        for r in data.get(name, []):
            vals = [r.get(n) for n in names]
            ph = ", ".join("?" for _ in names)
            q = ", ".join(f'"{n}"' for n in names)
            con.execute(f'INSERT INTO "{name}" ({q}) VALUES ({ph})', vals)


def out(qid, row, col, val):
    if val is None:
        val = ""
    print("\t".join([qid, str(row), str(col), str(val)]))


def main():
    spec = json.load(open(sys.argv[1]))
    con = load(spec)
    fill(con, spec, rows_of(spec))
    for q in spec["queries"]:
        try:
            duck = sqlglot.transpile(q["sql"], read="spark", write="duckdb")[0]
            cur = con.execute(duck)
            cols = [d[0] for d in cur.description]
            for i, row in enumerate(cur.fetchall()):
                for c, v in zip(cols, row):
                    out(q["id"], i, c, v)
        except Exception as ex:
            print("\t".join([q["id"], "ERROR", str(ex).replace("\n", " "), ""]))


if __name__ == "__main__":
    main()
