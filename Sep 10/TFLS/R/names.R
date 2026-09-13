# The two kinds of name this run is told, and what each may be.
#
# A prefix, a schema, a catalog and a cohort table all arrive from the
# environment, so each is a string somebody typed. They are used in two
# different places, and the two places have different rules.
#
# A FILE path segment is matched against what a path may hold, because a
# segment holding a slash or a dot-dot would read somewhere other than where it
# was asked to. There is no quoting for a path: a bad segment is refused.
#
# A TABLE name is quoted instead. Backticks are this warehouse's delimited
# identifier, so a name that is quoted means exactly itself however it is
# spelt; only what quoting cannot survive is refused. Matching a table name
# against a pattern gets this wrong twice - it lets a dot through, which is a
# second identifier rather than a character, and it refuses names the warehouse
# is perfectly happy with.
#
# Sourced into R/ rather than kept beside the runner so that both are checked
# by running them, not by reading them.

# --- a file path segment -----------------------------------------------------

# A name that may be used as one path segment or one plain table name, and
# nothing else. Refused rather than repaired.
safe_segment <- function(x) {
  x <- chr(x)
  length(x) == 1L && nzchar(x) && grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", x)
}

# --- a warehouse identifier ---------------------------------------------------

# One part of a warehouse name, quoted for the statement. NA where quoting
# cannot hold it: a backtick would close the quoting early, a control character
# would not survive the round trip, and an empty or missing name is not a name.
# Everything else - a leading underscore, a hyphen, an all-digit name, a
# reserved word, a whole statement - comes out as one identifier with that
# name, which is a name no warehouse has.
sql_name <- function(x) {
  v <- chr(x)
  if (length(v) != 1L || is.na(v) || !nzchar(v) ||
      grepl("[`]", v) || grepl("[[:cntrl:]]", v)) return(NA_character_)
  sprintf("`%s`", v)
}

# A name already written as one to three dotted parts - the input cohort table,
# which the run is told by name - quoted part by part. NA if there are more
# parts than a warehouse name has, or if any part cannot be quoted.
sql_qualified_name <- function(x) {
  parts <- strsplit(chr(x), ".", fixed = TRUE)[[1]]
  q <- vapply(parts, sql_name, character(1))
  if (!length(q) || length(q) > 3L || anyNA(q)) return(NA_character_)
  paste(q, collapse = ".")
}
