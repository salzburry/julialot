#!/usr/bin/env python3
"""Runs statements against fixture rows and prints what each one returned.

run_duckdb.py, beside this, answers how many rows a QC check counted. The
fold-in trace is not a check: its candidate query has to return one set of rows
and no others - the right line, the right drug, the right return date - and its
per-patient reads have to come back in the shape the renderer expects. So this
prints the rows.

It cannot run Spark, so each statement is transpiled to DuckDB with sqlglot.
The transpile is a compromise: DuckDB is not Spark, and a statement Spark would
reject can still run here. Complementary to the text tests, not a replacement
for a run against the warehouse.

Usage:  run_duckdb_rows.py <spec.json>

spec.json: {"tables":  {name: {"columns": {col: type, ...}}, ...},
            "data":    {name: [row, ...], ...},
            "queries": [{"id": ..., "sql": ...}, ...]}

Prints, per query, a TSV block:
    == <id>
    <col>\t<col>...
    <val>\t<val>...          one line per row, NULL as empty
A statement that could not run prints "== <id>" and then "!! <message>", so
a query nobody can run is never read as one that returned nothing.
"""
import datetime, json, sys

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
    """`data` is {table: [row, ...]}. A table absent from it is emptied."""
    for name, tab in spec["tables"].items():
        con.execute(f'DELETE FROM "{name}"')
        names = list(tab["columns"])
        for r in data.get(name, []):
            vals = [r.get(n) for n in names]
            ph = ", ".join("?" for _ in names)
            q = ", ".join(f'"{n}"' for n in names)
            con.execute(f'INSERT INTO "{name}" ({q}) VALUES ({ph})', vals)


def cell(v):
    if v is None:
        return ""
    # DuckDB's date_add() yields a TIMESTAMP where Spark yields a DATE, so a
    # window end came back as "2020-07-30 00:00:00". Printed as the date it
    # is, so the R side compares what Spark would have returned.
    if isinstance(v, datetime.datetime) and v.time() == datetime.time(0):
        return v.date().isoformat()
    return str(v).replace("\t", " ").replace("\n", " ")


def main():
    spec = json.load(open(sys.argv[1]))
    con = load(spec)
    fill(con, spec, spec.get("data", {}))
    for q in spec["queries"]:
        print("== " + q["id"])
        try:
            duck = sqlglot.transpile(q["sql"], read="spark", write="duckdb")[0]
            cur = con.execute(duck)
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
            print("\t".join(cols))
            for r in rows:
                print("\t".join(cell(v) for v in r))
        except Exception as ex:
            print("!! " + str(ex).replace("\n", " "))


if __name__ == "__main__":
    main()
