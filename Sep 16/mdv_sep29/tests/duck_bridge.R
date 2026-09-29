# The R side of duck_bridge.py: start it, talk to it, and point a build's two
# warehouse functions at it.
#
# A build reaches the warehouse only through db_exec_once() and db_q(). Once
# use_duck() has replaced those two, the build runs unchanged against the
# synthetic MDV tables the server loaded - its own statements, in its own
# order, with every check reading a real answer.

duck_start <- function(fixture_dir, bridge = NULL) {
  if (is.null(bridge))
    bridge <- file.path(dirname(sys.frame(1)$ofile %||% "."), "duck_bridge.py")
  pf <- tempfile("duckport")
  log <- tempfile("duckbridge", fileext = ".log")
  system2("python3", c(shQuote(bridge), shQuote(pf), shQuote(fixture_dir)),
          wait = FALSE, stdout = log, stderr = log)
  for (i in seq_len(600)) {
    if (file.exists(pf)) break
    Sys.sleep(0.1)
  }
  if (!file.exists(pf))
    stop("duck_bridge.py did not start: ", paste(readLines(log, warn = FALSE),
                                                 collapse = "\n"), call. = FALSE)
  port <- as.integer(readLines(pf, warn = FALSE)[1])
  con <- socketConnection("127.0.0.1", port, blocking = TRUE, open = "r+b",
                          timeout = 600)
  assign("duck_con", con, envir = globalenv())
  invisible(con)
}

duck_stop <- function() {
  if (!exists("duck_con", envir = globalenv())) return(invisible(FALSE))
  con <- get("duck_con", envir = globalenv())
  try({ writeLines("BYE", con); flush(con); close(con) }, silent = TRUE)
  rm("duck_con", envir = globalenv())
  invisible(TRUE)
}

.duck_send <- function(kind, sql) {
  con <- get("duck_con", envir = globalenv())
  raw <- charToRaw(enc2utf8(paste(sql, collapse = "\n")))
  writeLines(kind, con)
  writeLines(as.character(length(raw)), con)
  writeBin(raw, con)
  flush(con)
  status <- readLines(con, n = 1L)
  n <- as.integer(readLines(con, n = 1L))
  body <- raw(0)
  while (length(body) < n) body <- c(body, readBin(con, "raw", n - length(body)))
  list(status = status, body = rawToChar(body))
}

# The SQL the build sent, every statement, for the suites that read it back.
duck_log <- new.env()
duck_log$sql <- character(0)

duck_exec <- function(sql) {
  duck_log$sql <- c(duck_log$sql, paste(sql, collapse = "\n"))
  r <- .duck_send("E", sql)
  if (r$status != "OK") stop(r$body, call. = FALSE)
  invisible(0L)
}

duck_query <- function(sql) {
  duck_log$sql <- c(duck_log$sql, paste(sql, collapse = "\n"))
  r <- .duck_send("Q", sql)
  if (r$status != "OK") stop(r$body, call. = FALSE)
  if (!nzchar(r$body)) return(data.frame())
  utils::read.delim(text = r$body, sep = "\t", quote = "", na.strings = "\\N",
                    stringsAsFactors = FALSE, check.names = FALSE,
                    comment.char = "")
}

# Point a loaded build at the bridge. Retries off: a statement DuckDB refuses
# will be refused again, and the build's backoff would only add minutes.
use_duck <- function() {
  assign("db_exec_once", function(con, sql) duck_exec(sql), envir = globalenv())
  assign("db_q", function(con, sql) duck_query(sql), envir = globalenv())
  if (exists("cfg_defaults", envir = globalenv())) {
    d <- get("cfg_defaults", envir = globalenv())
    d$max_retries <- 1L; d$base_sleep <- 0
    assign("cfg_defaults", d, envir = globalenv())
  }
  invisible(TRUE)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
