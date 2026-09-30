"""Spark itself, running the builds' own SQL.

The DuckDB bridge (duck_bridge.py) translates Spark SQL, so it cannot say what
Spark does with a statement - and the two differ exactly where it matters: under
ANSI mode, Databricks SQL's default, to_date() raises on 20200230 where DuckDB
returns NULL. This runs statements in a local SparkSession with ANSI mode on and
no translation at all.

    python3 spark_sql.py <steps file> <results file>

The steps file is plain text, one step per block:

    @@step <name> <fetch: 0|1>
    <one Spark SQL statement>

The results file gives each step's outcome and, where fetched, its rows:

    @@spark <version> <ansi>
    @@result <name> ok
    <tab-separated header>
    <tab-separated rows; NULL for a null, arrays joined with ','>
    @@result <name> error <first line of the message>

A step that raises is reported, not fatal: some steps exist to show that Spark
raises. Needs pyspark and a Java runtime.
"""
import sys

from pyspark.sql import SparkSession


def read_steps(path):
    steps, cur = [], None
    for line in open(path, encoding="utf-8").read().split("\n"):
        if line.startswith("@@step "):
            _, name, fetch = line.split(" ")
            cur = {"name": name, "fetch": fetch == "1", "sql": []}
            steps.append(cur)
        elif cur is not None:
            cur["sql"].append(line)
    for s in steps:
        s["sql"] = "\n".join(s["sql"]).strip()
    return steps


def cell(v):
    if v is None:
        return "NULL"
    if isinstance(v, (list, tuple)):
        return ",".join(cell(x) for x in v)
    if hasattr(v, "isoformat"):
        return v.isoformat()
    return str(v).replace("\t", " ").replace("\n", " ")


def main(steps_path, out_path):
    spark = (SparkSession.builder.master("local[1]").appName("mdv_sep29")
             .config("spark.ui.enabled", "false")
             .config("spark.sql.ansi.enabled", "true")
             .config("spark.sql.session.timeZone", "UTC")
             .config("spark.sql.shuffle.partitions", "1")
             .getOrCreate())
    spark.sparkContext.setLogLevel("OFF")
    out = ["@@spark %s %s" % (spark.version, spark.conf.get("spark.sql.ansi.enabled"))]
    for st in read_steps(steps_path):
        try:
            df = spark.sql(st["sql"])
            rows = df.collect() if st["fetch"] else None
            out.append("@@result %s ok" % st["name"])
            if rows is not None:
                out.append("\t".join(df.columns))
                out.extend("\t".join(cell(v) for v in r) for r in rows)
        except Exception as e:  # reported, not fatal - see above
            msg = str(e).strip().split("\n")[0]
            out.append("@@result %s error %s" % (st["name"], msg))
    spark.stop()
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
