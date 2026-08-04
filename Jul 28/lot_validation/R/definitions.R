# How this algorithm operationalises "line of therapy", point by point.
#
# The ask: map these rules against IMWG consensus and the pivotal trial
# definitions, and flag where they agree and where they do not.
#
# OUR column is complete, cited to file and line. It is the half the code can
# settle, and the half nobody had written down: the rules sit across eight step
# files, and "does this count SCT as a line" had no single place to look.
#
# THEIR columns are empty, because the consensus paper and the trial protocols
# are not in this folder and nothing here can stand in for them. What must not
# go in these cells is a summary of a document rather than the document: it
# reads like a citation, cannot be checked by anyone holding the same source,
# and would make a table that looks authoritative and is not.
#
# So it ships as a grid somebody with the documents can fill mechanically: one
# row per dimension, the question to put to a protocol, and a citation required
# before a cell counts.

# What the sources may be. The test is whether someone holding the same
# document could check the cell. A protocol section passes it; a recollection
# does not, and neither does a summary.
DEF_SOURCE_TYPES <- c(
  protocol      = "the trial protocol or SAP, with a section reference",
  registry      = "the ClinicalTrials.gov record, with the NCT id and field",
  publication   = "a peer-reviewed paper, with the page or section",
  guideline     = "a consensus or guideline document, with the section")
DEF_SOURCE_REJECTED <- c(
  search_summary = paste0("a summary of a document rather than the document. ",
                          "Reads like a citation, cannot be checked by anyone ",
                          "holding the source, and is how an unsourced claim ",
                          "gets into a table that looks authoritative."),
  recollection   = paste0("written from memory. The same objection, and ",
                          "nothing at all for a reader to go to."))

# The dimensions a line-of-therapy definition has to answer. The first three
# the ask named; the rest are where this algorithm decides something another
# could decide differently.
#
# `ours` is what this build does. `where` is where to check it, as `path:line`,
# comma-separated, a bare `:line` continuing the previous path. Line numbers,
# not file names: a file name sends the reader to eight hundred lines of SQL,
# and a claim that expensive to check does not get checked. `question` is what
# to put to a protocol, worded so filling the cell is reading, not interpreting.
LOT_DIMENSIONS <- list(
  # The LOT1 half alone reads as complete and is not. SCT_AUTO is one of the
  # start types a LOT-N takes, so a later transplant is a line of its own.
  list(id = "sct_auto_is_a_line",
       dimension = "Is an autologous transplant its own line, or part of induction?",
       ours = paste0("Both, depending on where it falls. Inside a line it is ",
                     "part of it: LOT1 allows a single AUTO and allows a tandem ",
                     "pair, and a later line allows an AUTO within its own ",
                     "induction window. Beyond that it is a boundary - the ",
                     "excess AUTO ends the current line with reason SCT_AUTO, ",
                     "and SCT_AUTO is one of the start types the next line can ",
                     "take, so a further transplant becomes a line of its own ",
                     "even with no drug beside it."),
       where = "lot/R/steps/05_sct.R:11, lot/R/steps/10_lot2_5_base.R:239, :309",
       question = paste0("Does the definition count ASCT as a separate prior ",
                         "line, or as part of the induction line it follows? ",
                         "Does the answer change for a transplant at second ",
                         "line or later?")),

  list(id = "sct_allo_is_a_line",
       dimension = "Is an allogeneic transplant its own line?",
       ours = paste0("Yes, and it spans a single day - start and end are the ",
                     "transplant date. It carries no regimen string, because ",
                     "induction rows are suppressed for it."),
       where = "lot/R/steps/10_lot2_5_base.R:348, :658",
       question = "Is alloSCT counted as a prior line in its own right?"),

  list(id = "cart_is_a_line",
       dimension = "Is CAR-T its own line, and what happens to bridging therapy?",
       ours = paste0("CAR-T starts a line of its own. An agent added within ",
                     "the consolidation window before it is read as bridging ",
                     "and stays in the prior line, which ends CART_INIT."),
       where = "lot/R/steps/06_lot1_end.R:186",
       question = paste0("Is CAR-T a prior line? Is bridging therapy counted ",
                         "separately from it?")),

  list(id = "maintenance_is_a_line",
       dimension = "Is maintenance counted as a line?",
       ours = paste0("No. Maintenance is a descriptive flag (contains_mtx_reg) ",
                     "and there is no maintenance period at all. A regimen ",
                     "reduced to a single agent continues the same line."),
       where = "lot/R/steps/05_sct.R:13",
       question = paste0("Does the definition count maintenance as part of the ",
                         "preceding line, or as a line of its own?")),

  list(id = "what_starts_a_new_line",
       dimension = "What starts a new line?",
       ours = paste0("A non-steroid agent that is not a permissible substitute ",
                     "of a drug in the current line, or a transplant or CAR-T ",
                     "event. There is no requirement that progression be ",
                     "documented - claims do not carry it."),
       where = "lot/R/steps/10_lot2_5_base.R:204, :239",
       question = paste0("Does a new line require documented progression or ",
                         "relapse, or is any regimen change enough?")),

  list(id = "gap_ends_a_line",
       dimension = "When does a gap in treatment end a line?",
       ours = paste0("A gap of MAP_DISCON_GAP_DAYS or more after an agent's ",
                     "exposure ends discontinues it. The predicate is >=, so ",
                     "the threshold day itself counts as a gap."),
       where = "lot/R/steps/03_mma_map.R:391",
       question = paste0("Does the definition end a line on a treatment gap, ",
                         "and at what length? Are holds for toxicity excluded?")),

  list(id = "regimen_membership_window",
       dimension = "How long may an agent join a line's regimen?",
       ours = paste0("Day 0 through INDUCTION_WINDOW_DAYS - 1 for LOT1, and ",
                     "the shorter LOT-N window for later lines. An agent after ",
                     "that is an addition, not part of the regimen."),
       where = "lot/R/steps/10_lot2_5_base.R:341",
       question = paste0("Is there a window within which added agents belong to ",
                         "the same regimen, and how long?")),

  list(id = "substitution",
       dimension = "Does swapping to a substitute start a line?",
       ours = paste0("No, where the pair is declared in permissible_subs.csv. ",
                     "A substitution the code list does not know about looks ",
                     "like a regimen change and starts a line."),
       where = "lot/R/steps/01_codelists.R:66",
       question = paste0("Are biosimilars, route changes or generic swaps ",
                         "treated as the same agent?")),

  list(id = "steroids",
       dimension = "Do steroids affect the line?",
       ours = paste0("No. Steroids are dropped from the code list, so they ",
                     "never start a line, never join a regimen and never keep ",
                     "one alive."),
       where = "lot/R/steps/10_lot2_5_base.R:346",
       question = paste0("Are corticosteroids counted as agents in the regimen, ",
                         "or disregarded?")),

  list(id = "dose_change",
       dimension = "Does a dose change or a hold start a line?",
       ours = paste0("No. Neither is visible as a regimen change: the agent ",
                     "set is unchanged, and a hold shorter than the ",
                     "discontinuation gap does not end exposure."),
       where = "lot/R/steps/03_mma_map.R:391",
       question = "Does the definition exclude dose modification and holds?"),

  list(id = "line_cap",
       dimension = "Is there a cap on how many lines are counted?",
       ours = paste0("Yes - MAX_LOT. Nothing above it is built, so a capped ",
                     "patient is indistinguishable from a completed one."),
       where = "lot/R/steps/10_lot2_5_base.R:1008, lot/R/build_lot.R:1404",
       question = paste0("Does the source cap the line count, or report the ",
                         "full distribution?")),

  list(id = "first_line_start",
       dimension = "What fixes the start of the first line?",
       ours = paste0("The first eligible MM therapy claim on or after the MM ",
                     "diagnosis and on or after LOT1_FROM. Belantamab and ",
                     "steroids cannot set it. That date is the cohort index."),
       where = "nndm/R/steps/00b_lot1_index.R:147",
       question = paste0("How is the start of first-line therapy defined, and ",
                         "may any agent set it?")))

DEF_SOURCE_COLS <- c("dimension_id", "source_id", "source_type", "citation",
                     "retrieved", "answer", "concordance", "notes")

# Read strictly. A filled answer with no citation, or with a rejected source
# type, stops the load - in the output it would look no different from one
# somebody read out of a protocol.
read_definition_sources <- function(path) {
  if (!file.exists(path))
    stop("No source grid at ", path, call. = FALSE)
  df <- read.csv(path, stringsAsFactors = FALSE, colClasses = "character",
                 na.strings = c("", "NA"))
  miss <- setdiff(DEF_SOURCE_COLS, names(df))
  if (length(miss))
    stop("The source grid is missing: ", paste(miss, collapse = ", "), call. = FALSE)
  bad <- character(0)
  unknown <- setdiff(unique(df$dimension_id[!is.na(df$dimension_id)]),
                     vapply(LOT_DIMENSIONS, function(d) d$id, character(1)))
  if (length(unknown))
    bad <- c(bad, paste0("names dimensions that do not exist: ",
                         paste(unknown, collapse = ", ")))
  filled <- !is.na(df$answer) & nzchar(trimws(df$answer))
  nocite <- filled & (is.na(df$citation) | !nzchar(trimws(df$citation)))
  if (any(nocite))
    bad <- c(bad, paste0("an answer with no citation on row(s): ",
                         paste(which(nocite), collapse = ", ")))
  st <- tolower(trimws(ifelse(is.na(df$source_type), "", df$source_type)))
  rejected <- filled & st %in% names(DEF_SOURCE_REJECTED)
  if (any(rejected))
    bad <- c(bad, paste0("row(s) ", paste(which(rejected), collapse = ", "),
                         " use a source type this grid rejects. ",
                         DEF_SOURCE_REJECTED[[st[which(rejected)[1]]]]))
  badtype <- filled & !st %in% names(DEF_SOURCE_TYPES) & !st %in% names(DEF_SOURCE_REJECTED)
  if (any(badtype))
    bad <- c(bad, paste0("source_type must be one of ",
                         paste(names(DEF_SOURCE_TYPES), collapse = "/"),
                         " on row(s): ", paste(which(badtype), collapse = ", ")))
  norel <- filled & st %in% c("registry", "publication", "guideline") &
    (is.na(df$retrieved) | !nzchar(trimws(df$retrieved)))
  if (any(norel))
    bad <- c(bad, paste0("a retrieved date is needed for a registry, publication ",
                         "or guideline citation - records change. Row(s): ",
                         paste(which(norel), collapse = ", ")))
  okc <- c("agrees", "differs", "unclear", "")
  badc <- filled & !tolower(trimws(ifelse(is.na(df$concordance), "", df$concordance))) %in% okc
  if (any(badc))
    bad <- c(bad, paste0("concordance must be agrees/differs/unclear on row(s): ",
                         paste(which(badc), collapse = ", ")))
  if (length(bad))
    stop("The definition source grid does not load:\n  ",
         paste(bad, collapse = "\n  "), call. = FALSE)
  df
}

# Our side, rendered. Every row citable to a file.
render_definitions <- function(dims = LOT_DIMENSIONS) {
  do.call(rbind, lapply(dims, function(d) data.frame(
    dimension_id = d$id, dimension = d$dimension, ours = d$ours,
    ours_at = d$where, ask_the_protocol = d$question,
    stringsAsFactors = FALSE)))
}

# Concordance, only where a source answered. A dimension nobody filled is "not
# yet sourced", never "agrees" - an empty comparison reading as agreement
# retires the question instead of answering it.
compare_definitions <- function(sources, dims = LOT_DIMENSIONS) {
  ours <- render_definitions(dims)
  filled <- sources[!is.na(sources$answer) & nzchar(trimws(sources$answer)), , drop = FALSE]
  out <- lapply(seq_len(nrow(ours)), function(i) {
    d <- ours[i, , drop = FALSE]
    rows <- filled[filled$dimension_id == d$dimension_id, , drop = FALSE]
    if (!nrow(rows))
      return(data.frame(dimension_id = d$dimension_id, dimension = d$dimension,
                        ours = d$ours, source_id = NA_character_,
                        source_type = NA_character_, citation = NA_character_,
                        answer = NA_character_, concordance = "not yet sourced",
                        stringsAsFactors = FALSE))
    data.frame(dimension_id = d$dimension_id, dimension = d$dimension,
               ours = d$ours, source_id = rows$source_id,
               source_type = rows$source_type, citation = rows$citation,
               answer = rows$answer,
               concordance = ifelse(is.na(rows$concordance) |
                                      !nzchar(trimws(rows$concordance)),
                                    "unclear", tolower(trimws(rows$concordance))),
               stringsAsFactors = FALSE)
  })
  do.call(rbind, out)
}
