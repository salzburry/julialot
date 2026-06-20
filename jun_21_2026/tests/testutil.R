# Tiny dependency-free test framework for the local toolkit.
.T <- new.env(); .T$pass <- 0L; .T$fail <- 0L
ok <- function(cond, msg) {
  if (isTRUE(cond)) { .T$pass <- .T$pass + 1L; cat("  ok  ", msg, "\n") }
  else { .T$fail <- .T$fail + 1L; cat("  FAIL", msg, "\n") }
}
eq <- function(a, b, msg) ok(isTRUE(all.equal(a, b)),
                             sprintf("%s (got %s, want %s)", msg,
                                     paste(a, collapse = ","), paste(b, collapse = ",")))
test_summary <- function() {
  cat(sprintf("\n==== %d passed, %d failed ====\n", .T$pass, .T$fail))
  quit(status = if (.T$fail > 0) 1L else 0L)
}
