#!/usr/bin/env python3
"""A stand-in warehouse for the MDV suites: one DuckDB connection behind a socket.

The builds talk to Databricks through two functions, db_exec_once() and db_q().
The suites replace those two with calls to this server, so a whole build runs
unchanged - every statement it would send to the warehouse, in its order, with
its checks reading real answers - against small synthetic MDV tables.

It cannot run Spark, so each statement is transpiled to DuckDB with sqlglot and
a few rewrites sqlglot does not do. That is the compromise, and a real one:
DuckDB is not Spark, and a statement Spark would reject can still run here. It
complements a run against the warehouse; it does not replace one.

Usage:  duck_bridge.py <port-file> <fixture-dir>

Every <schema>.<table>.csv in <fixture-dir> is loaded as that table, with
DuckDB's own type sniffing - so a date column arrives as a DATE, a month as an
integer, a code as a number - because the MDV build has to read all of those.
The chosen port is written to <port-file> once the server is listening.

Protocol, one request at a time:
    client -> "Q" or "E" line, a byte-count line, then that many bytes of SQL
    server -> "OK" or "ERR" line, a byte-count line, then that many bytes:
              for Q a TSV with a header row (NULL as \\N), for E nothing,
              for ERR the error message.
"""
import datetime, os, re, socket, sys

import duckdb
import sqlglot
from sqlglot import exp


def load(con, fixture_dir):
    for f in sorted(os.listdir(fixture_dir)):
        if not f.endswith(".csv"):
            continue
        name = f[:-4]
        schema = name.split(".")[0] if "." in name else "main"
        con.execute(f"CREATE SCHEMA IF NOT EXISTS {schema}")
        con.execute(
            f"CREATE OR REPLACE TABLE {name} AS SELECT * FROM read_csv("
            f"'{os.path.join(fixture_dir, f)}', header=true, nullstr='', "
            f"sample_size=-1)")


ADD_COLUMNS = re.compile(r"ALTER\s+TABLE\s+(\S+)\s+ADD\s+COLUMNS\s*\((.*)\)\s*$",
                         re.I | re.S)


def _try_to_timestamp(node):
    # Spark's try_to_timestamp(s, 'yyyyMMdd') - NULL on a string that is not a
    # calendar date - is DuckDB's try_strptime(s, '%Y%m%d'). sqlglot leaves it
    # as a function DuckDB does not have. Only the one format the builds use
    # is translated; any other stops the statement rather than guessing.
    if isinstance(node, exp.Anonymous) and node.name.upper() == "TRY_TO_TIMESTAMP":
        args = node.expressions
        if len(args) == 2 and isinstance(args[1], exp.Literal) and args[1].this == "yyyyMMdd":
            return exp.Anonymous(this="TRY_STRPTIME",
                                 expressions=[args[0], exp.Literal.string("%Y%m%d")])
        raise ValueError("duck_bridge: try_to_timestamp with a format it does not "
                         "translate: " + node.sql())
    return node


def to_duckdb(sql):
    """Spark -> DuckDB statements, plus the rewrites sqlglot does not do."""
    s = sql.strip().rstrip(";")
    # Three-part names: there is no hive_metastore catalog here.
    s = s.replace("hive_metastore.", "")
    m = ADD_COLUMNS.match(s)
    if m:
        # Spark's ADD COLUMNS (c T, ...) is DuckDB's ADD COLUMN c T, one each.
        out = []
        for col in [c.strip() for c in m.group(2).split(",") if c.strip()]:
            out += sqlglot.transpile(f"ALTER TABLE {m.group(1)} ADD COLUMN {col}",
                                     read="spark", write="duckdb")
        return out
    out = [t.transform(_try_to_timestamp).sql(dialect="duckdb")
           for t in sqlglot.parse(s, read="spark") if t is not None]
    # DuckDB spells the null-safe comparison IS NOT DISTINCT FROM, and its
    # CURRENT_TIMESTAMP carries a time zone, which Python can only fetch with
    # pytz; Spark's has none, so it is cast to a plain timestamp.
    # A Spark TIMESTAMP column transpiles to TIMESTAMPTZ for the same reason,
    # and is declared plain for the same reason.
    return [re.sub(r"\bTIMESTAMPTZ\b", "TIMESTAMP",
                   re.sub(r"\bCURRENT_TIMESTAMP\b", "CAST(CURRENT_TIMESTAMP AS TIMESTAMP)",
                          o.replace("<=>", "IS NOT DISTINCT FROM"))) for o in out]


def spark_error(msg):
    # The builds tell "the table is not there" from "it could not be read" by
    # Spark's wording. DuckDB words it differently; say it Spark's way too.
    if re.search(r"Table with name .* does not exist|Table .* does not exist", msg):
        return "TABLE_OR_VIEW_NOT_FOUND: " + msg
    return msg


def cell(v):
    if v is None:
        return "\\N"
    # DuckDB's date + interval is a TIMESTAMP where Spark's date_add() is a
    # DATE; a midnight timestamp is printed as the date Spark would return.
    if isinstance(v, datetime.datetime) and v.time() == datetime.time(0):
        return v.date().isoformat()
    return str(v).replace("\t", " ").replace("\n", " ")


def run(con, kind, sql):
    head = sql.lstrip().upper()
    if head.startswith("DESCRIBE "):
        cur = con.execute("DESCRIBE " + sql.strip()[9:].replace("hive_metastore.", ""))
        rows = cur.fetchall()
        # Spark's DESCRIBE names its columns col_name and data_type.
        return "col_name\tdata_type\n" + "".join(
            f"{r[0]}\t{r[1]}\n" for r in rows)
    body = ""
    for stmt in to_duckdb(sql):
        cur = con.execute(stmt)
        if kind == "Q" and cur.description is not None:
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
            body = "\t".join(cols) + "\n" + "".join(
                "\t".join(cell(v) for v in r) + "\n" for r in rows)
    return body


def recv_exact(conn, n):
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise EOFError
        buf += chunk
    return buf


def recv_line(conn):
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(1)
        if not chunk:
            raise EOFError
        buf += chunk
    return buf.decode().strip()


def send(conn, status, body):
    b = body.encode()
    conn.sendall(f"{status}\n{len(b)}\n".encode() + b)


def main():
    port_file, fixture_dir = sys.argv[1], sys.argv[2]
    con = duckdb.connect()
    load(con, fixture_dir)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    with open(port_file + ".tmp", "w") as fh:
        fh.write(str(srv.getsockname()[1]))
    os.replace(port_file + ".tmp", port_file)
    conn, _ = srv.accept()
    try:
        while True:
            try:
                kind = recv_line(conn)
            except EOFError:
                break
            if kind == "BYE":
                break
            n = int(recv_line(conn))
            sql = recv_exact(conn, n).decode()
            try:
                send(conn, "OK", run(con, kind, sql))
            except Exception as ex:          # the build decides what an error means
                send(conn, "ERR", spark_error(str(ex)))
    finally:
        conn.close()
        srv.close()


if __name__ == "__main__":
    main()
