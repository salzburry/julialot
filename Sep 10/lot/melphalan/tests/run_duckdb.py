#!/usr/bin/env python3
"""Runs this package's SQL against fixture data, and reports what came back.

The rest of the suite reads the SQL as text: generated with fake table names
and inspected. Text cannot tell you that a join lost a bound, that a CASE can
never be true, or that a count is measuring something other than what its
alias says. These statements produce the numbers the melphalan comparison is
read from, and the rule's own decision CTEs decide where a line starts - so
both are executed here against fixtures whose answers are worked out by hand.

It cannot run Spark, so each statement is transpiled to DuckDB with sqlglot.
That is a real compromise: DuckDB is not Spark, and a statement Spark would
reject can still run here. Complementary to the text tests and to a run
against the warehouse, not a replacement for either.

Usage:  run_duckdb.py <spec.json>

spec.json: {"tables":  {name: {"columns": {col: type, ...}}, ...},
            "data":    {name: [row, ...], ...},
            "queries": [{"id": "...", "sql": "..."}, ...]}

Prints one TSV line per returned cell:

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
    fill(con, spec, spec.get("data", {}))
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
