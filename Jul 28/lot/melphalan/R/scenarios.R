# The study team's worked scenarios, and the rule run over them.
#
# Four patients came with the restated ask, each drawn twice - as the build
# classifies them today, and as the study team says the rule should. They are
# the only statement of the rule that names dates rather than branches, so they
# are held here as data and re-run rather than checked once by eye.
#
# Nothing here restates the rule. The branch decision is lifted out of the SQL
# `melp_decision_ctes()` generates - the same text the build runs - by cutting
# each arm's WHERE clause and evaluating it over the judged rows. A second copy
# of the decision would agree with whatever this file believed, which is exactly
# what these scenarios exist to test.
#
# Two things ARE re-expressed here, and both are named in the output rather than
# hidden:
#
#   the exposure chain   doses closer together than melp_exposure_days are one
#                        administration. A window function in the build; a fold
#                        here, off the same setting.
#   the engine's default what happens at a melphalan date the rule leaves alone.
#                        A dose first seen outside the induction window is an
#                        added medication and advances the line; a repeat of a
#                        drug already in the regimen extends it instead. That is
#                        the behaviour lot/questions/melphalan_lot_rule.md
#                        records under "What the build does today", and it is a
#                        model of the engine, not the engine.
#
# So a disagreement here is a real disagreement about the rule; an agreement
# says the branches line up, not that a warehouse run would.

# Day numbers are relative to the line the melphalan falls in, which is what the
# induction window is measured from. `starts` is where the study team's drawing
# puts a new line - empty when the reclassified picture has none.
MELP_SCENARIOS <- list(
  list(id = "example_1",
       what = paste0("First MELP outside the 1L induction window, a second 90 ",
                     "days later, and no third. B.2 both times."),
       doses = c(120, 210), induction_end = 60,
       starts = numeric(0),
       drawn = "no new line - MELP is retained as an add-on to 1L"),

  list(id = "example_2",
       what = paste0("The same, and then a third exposure 210 days after the ",
                     "second. B.2 then B.3."),
       doses = c(120, 210, 420), induction_end = 60,
       starts = 420,
       drawn = "a new line at the third dose, on its own date"),

  list(id = "example_3",
       what = paste0("First MELP inside a later line's own 30-day induction ",
                     "window, then +50 and +70 days. A.1 then B.2."),
       doses = c(10, 60, 130), induction_end = 30,
       starts = numeric(0),
       drawn = "unchanged - the line the build already found"),

  list(id = "example_4",
       what = paste0("The same opening, and then 190 days. A.1 then B.3."),
       doses = c(10, 60, 250), induction_end = 30,
       starts = 250,
       drawn = "a new line at the third dose, on its own date")
)

# ---- the decision, lifted ---------------------------------------------------

# Cut one CTE's body out of the generated SQL.
.melp_cte <- function(sql, cte) {
  i <- regexpr(paste0(cte, " AS \\("), sql)
  if (i < 0) stop("no ", cte, " in the generated SQL", call. = FALSE)
  gsub("\\s+", " ",
       sub("(?s)\\).*$", "",
           substr(sql, i + attr(i, "match.length"), nchar(sql)), perl = TRUE))
}

# One arm of a suppress/inject CTE: which column it emits, and the predicate
# that decides it. Comments are stripped first - the arms carry several, and a
# "--" run to end-of-line swallows the rest of a collapsed one-line string.
.melp_arms <- function(body) {
  lapply(strsplit(body, "UNION", fixed = TRUE)[[1]], function(a) {
    a <- gsub("--[^\n]*?(?=SELECT|WHERE|$)", " ", a, perl = TRUE)
    col <- regmatches(a, regexpr("(EXPO_DT|NEXT_DT)(?= AS)", a, perl = TRUE))
    w   <- sub("^.*?\\bWHERE\\b", "", a, perl = TRUE)
    list(col = if (length(col)) col else NA_character_, where = trimws(w))
  })
}

# SQL predicate -> R expression. The arms use only the four judged columns,
# numeric comparison, AND, and IS NOT NULL, so this is a translation rather than
# a parser - and anything it does not know about is left alone and will fail
# loudly at eval() rather than quietly evaluating to something.
.melp_pred <- function(where) {
  x <- gsub("\\bAND\\b", "&", where)
  x <- gsub("([A-Z_]+) IS NOT NULL", "!is.na(\\1)", x)
  x <- gsub("([A-Z_]+) IS NULL", "is.na(\\1)", x)
  gsub("(?<![<>!=])=(?!=)", "==", x, perl = TRUE)
}

# The exposure chain: doses closer together than the setting are one
# administration, and the exposure is dated at the first of them.
melp_exposures <- function(doses, exposure_days) {
  d <- sort(unique(doses))
  if (!length(d)) return(numeric(0))
  keep <- d[1]; last <- d[1]
  for (x in d[-1]) { if (x - last >= exposure_days) keep <- c(keep, x); last <- x }
  keep
}

# Run one scenario. Returns the judged rows, what the rule did to each, and the
# line starts that fall out.
melp_scenario_run <- function(cfg, sc) {
  sql <- melp_decision_ctes(cfg, "L", "S", "E", "L.IND_END")
  arms <- list(suppress = .melp_arms(.melp_cte(sql, "melp_suppress")),
               inject   = .melp_arms(.melp_cte(sql, "melp_inject")))

  e <- melp_exposures(sc$doses, cfg$melp_exposure_days)
  rows <- data.frame(EXPO_DT = e, NEXT_DT = c(e[-1], NA))
  rows$GAP        <- rows$NEXT_DT - rows$EXPO_DT
  rows$INSIDE     <- as.integer(rows$EXPO_DT <= sc$induction_end)
  # No coded transplant in any scenario, so nothing yields. Named, not assumed:
  # a scenario that carried one would need the AUTO dates too.
  rows$YIELD_THIS <- 0L
  rows$YIELD_NEXT <- 0L

  fire <- function(arm) {
    keep <- vapply(seq_len(nrow(rows)), function(i)
      isTRUE(eval(parse(text = .melp_pred(arm$where)), envir = rows[i, ])),
      logical(1))
    v <- rows[[arm$col]][keep]
    v[!is.na(v)]
  }
  suppress <- sort(unique(unlist(lapply(arms$suppress, fire))))
  inject   <- sort(unique(unlist(lapply(arms$inject,   fire))))

  # What the engine does with what the rule left it. See the header: this is a
  # model of the engine, from the recorded behaviour, not the engine itself.
  in_regimen <- nrow(rows) > 0L && rows$INSIDE[1] == 1L
  engine <- if (in_regimen) numeric(0)
            else setdiff(rows$EXPO_DT[rows$INSIDE == 0L], suppress)

  list(rows = rows, suppress = suppress, inject = inject,
       in_regimen = in_regimen,
       starts = sort(unique(c(inject, engine))))
}

# Which branch of the ask a row is in, for the report. Read off the same
# settings the rule is built from, so a changed threshold moves both together.
melp_branch <- function(row, cfg) {
  if (is.na(row$GAP)) return(if (row$INSIDE == 1L) "A (last)" else "B (last)")
  if (row$INSIDE == 1L)
    return(if (row$GAP >= cfg$melp_advance_days) "A.2" else "A.1")
  if (row$GAP <  cfg$melp_restart_days) return("B.1")
  if (row$GAP <  cfg$melp_advance_days) return("B.2")
  "B.3"
}
