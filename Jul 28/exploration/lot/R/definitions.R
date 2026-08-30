# How this algorithm operationalises "line of therapy", point by point.
#
# The ask: map these rules against IMWG consensus and the pivotal trial
# definitions, and flag where they agree and where they do not.
#
# OUR column is complete, cited to file and line. It is the half the code can
# settle. The rules sit across eight step files, so a question like "does this
# count SCT as a line" otherwise has no single place to look.
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
       where = "lot/engine/R/steps/05b_lot1_sct.R:142, :167, lot/engine/R/steps/10_lot2_5_base.R:352, :451",
       proves = c("sct_tandem_days", "ENDING_AUTO_DT", "d_AUTO", "SCT_AUTO"),
       question = paste0("Does the definition count ASCT as a separate prior ",
                         "line, or as part of the induction line it follows? ",
                         "Does the answer change for a transplant at second ",
                         "line or later?")),

  list(id = "sct_allo_is_a_line",
       dimension = "Is an allogeneic transplant its own line?",
       ours = paste0("Yes, and it spans a single day - start and end are the ",
                     "transplant date. It carries no regimen string, because ",
                     "induction rows are suppressed for it."),
       where = "lot/engine/R/steps/10_lot2_5_base.R:449, :636",
       proves = c("SCT_ALLO", "allo_lot_span"),
       question = "Is alloSCT counted as a prior line in its own right?"),

  list(id = "cart_is_a_line",
       dimension = "Is CAR-T its own line, and what happens to bridging therapy?",
       ours = paste0("Usually, but not inside first-line induction. A CAR-T in ",
                     "LOT1's induction window is part of LOT1: it does not end ",
                     "the line and does not start one. Anywhere else it starts ",
                     "a line of its own, and an agent added within the ",
                     "consolidation window before it is read as bridging and ",
                     "stays in the prior line, which ends CART_INIT."),
       where = "lot/engine/R/cart_rule.R:27, lot/engine/R/steps/06_lot1_end.R:272, lot/engine/R/steps/10_lot2_5_base.R:317, :450",
       proves = c("LOT1_BASE_1ST_ADD_MED_DT", "CART", "cart_eligible_dt"),
       question = paste0("Is CAR-T a prior line? Is bridging therapy counted ",
                         "separately from it? Does a CAR-T during first-line ",
                         "induction count as a second line?")),

  list(id = "maintenance_is_a_line",
       dimension = "Is maintenance counted as a line?",
       ours = paste0("No. Maintenance is a descriptive flag (contains_mtx_reg) ",
                     "and there is no maintenance period at all. A regimen ",
                     "reduced to a single agent continues the same line."),
       where = "lot/engine/R/steps/06_lot1_end.R:18, :57",
       proves = c("contains_mtx_reg"),
       question = paste0("Does the definition count maintenance as part of the ",
                         "preceding line, or as a line of its own?")),

  list(id = "what_starts_a_new_line",
       dimension = "What starts a new line?",
       ours = paste0("A non-steroid agent that is not a permissible substitute ",
                     "of a drug in the current line, or a transplant or CAR-T ",
                     "event. There is no requirement that progression be ",
                     "documented - claims do not carry it. One agent is read ",
                     "differently: a short melphalan course outside the line's ",
                     "induction window does not start a line on its own, and ",
                     "starts one on its own first day when another agent ",
                     "begins while it still covers. Two rules narrow what ",
                     "counts as a new agent at all. A drug the patient has ",
                     "had before never starts a line, whatever the gap since ",
                     "it stopped - the line it belonged to runs on over the ",
                     "return. And a drug of the immediately previous line's ",
                     "regimen coming back after exactly one agent advanced ",
                     "the line is folded into the line it returns in, joining ",
                     "that line's regimen rather than opening the next."),
       where = paste0("lot/engine/R/steps/10_lot2_5_base.R:270, :282, :292, ",
                      ":317, :352, :450, :451, :452, lot/engine/R/melp_rule.R:513, :529, ",
                      "lot/engine/R/prior_regimen.R:34, lot/engine/R/foldin_rule.R:344"),
       proves = c("d_MED", "d_AUTO", "CART", "STEROID", "permissible_subs",
                  "melp_suppress", "melp_inject", "apply_own_return_fold",
                  "N_ADVANCES"),
       question = paste0("Does a new line require documented progression or ",
                         "relapse, or is any regimen change enough?")),

  list(id = "gap_ends_a_line",
       dimension = "When does a gap in treatment end a line?",
       ours = paste0("A gap of MAP_DISCON_GAP_DAYS or more after an agent's ",
                     "exposure ends discontinues it. The predicate is >=, so ",
                     "the threshold day itself counts as a gap."),
       where = "lot/engine/R/steps/03_mma_map.R:401",
       proves = c("map_discon_gap_days", ">="),
       question = paste0("Does the definition end a line on a treatment gap, ",
                         "and at what length? Are holds for toxicity excluded?")),

  list(id = "regimen_membership_window",
       dimension = "How long may an agent join a line's regimen?",
       ours = paste0("Day 0 through INDUCTION_WINDOW_DAYS - 1 for LOT1, and ",
                     "the shorter LOT-N window for later lines. An agent after ",
                     "that is an addition, not part of the regimen. Membership ",
                     "is an episode start inside the window, not a fill inside ",
                     "it: cover carried over from the previous line does not ",
                     "join, and neither does a real fill that a still-open ",
                     "episode of the same agent absorbs."),
       where = "lot/engine/R/steps/10_lot2_5_base.R:516, :517, :520",
       proves = c("MAP_START_DT", "date_add", "cart_consolidation_days"),
       question = paste0("Is there a window within which added agents belong to ",
                         "the same regimen, and how long?")),

  list(id = "substitution",
       dimension = "Does swapping to a substitute start a line?",
       ours = paste0("No, where the pair is declared in permissible_subs.csv. ",
                     "A substitution the code list does not know about looks ",
                     "like a regimen change and starts a line."),
       where = "lot/engine/R/steps/10_lot2_5_base.R:270, lot/engine/R/prior_regimen.R:75",
       proves = c("permissible_subs", "original_med"),
       question = paste0("Are biosimilars, route changes or generic swaps ",
                         "treated as the same agent?")),

  list(id = "steroids",
       dimension = "Do steroids affect the line?",
       ours = paste0("No. Steroids are dropped from the code list, so they ",
                     "never start a line, never join a regimen and never keep ",
                     "one alive."),
       where = "lot/engine/R/steps/01_codelists.R:43, lot/engine/R/steps/10_lot2_5_base.R:523",
       proves = c("CL_MED_CLASS", "STEROID"),
       question = paste0("Are corticosteroids counted as agents in the regimen, ",
                         "or disregarded?")),

  list(id = "dose_change",
       dimension = "Does a dose change or a hold start a line?",
       ours = paste0("No. Neither is visible as a regimen change: the agent ",
                     "set is unchanged, and a hold shorter than the ",
                     "discontinuation gap does not end exposure."),
       where = "lot/engine/R/steps/03_mma_map.R:401",
       proves = c("map_discon_gap_days"),
       question = "Does the definition exclude dose modification and holds?"),

  list(id = "line_cap",
       dimension = "Is there a cap on how many lines are counted?",
       ours = paste0("Yes - MAX_LOT. Nothing above it is built, so a capped ",
                     "patient is indistinguishable from a completed one."),
       where = "lot/engine/R/build_lot.R:1829",
       proves = c("max_lot"),
       question = paste0("Does the source cap the line count, or report the ",
                         "full distribution?")),

  list(id = "first_line_start",
       dimension = "What fixes the start of the first line?",
       ours = paste0("The first eligible MM therapy claim on or after the MM ",
                     "diagnosis and on or after LOT1_FROM. Belantamab and ",
                     "steroids cannot set it. That date is the cohort index."),
       where = "ndmm/R/steps/00b_lot1_index.R:160, :161, :162, :196",
       proves = c("bl.code IS NULL", "MM_DX_DT", "NDMM_LOT1_FROM", "min(tx_dt)"),
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
  # The grid is one row per (dimension, source), and that is the whole of its
  # arithmetic: twelve dimensions against six sources. Nothing checked the
  # source side of it, so trail_1 was a source, a second row for the same cell
  # was an addition rather than a correction, and trial_1 could be a different
  # protocol on every row - twelve trials wearing one name, rendered as one
  # column. None of it would have failed to load.
  DEF_SOURCE_IDS <- c("IMWG_consensus", paste0("trial_", 1:5))
  sid <- ifelse(is.na(df$source_id), "", trimws(df$source_id))
  unk <- setdiff(unique(sid[nzchar(sid)]), DEF_SOURCE_IDS)
  if (length(unk))
    bad <- c(bad, paste0("source_id must be one of ",
                         paste(DEF_SOURCE_IDS, collapse = "/"), " - found: ",
                         paste(unk, collapse = ", ")))
  # The IMWG slot is required, not merely permitted. The ask names IMWG
  # consensus by name and it is the one source that is not a trial, so deleting
  # the block outright left a grid that loaded, satisfied a row count of
  # dimensions x sources, and answered a different question - the trials
  # without the consensus they are usually read against.
  if (!"IMWG_consensus" %in% sid)
    bad <- c(bad, paste0("no IMWG_consensus rows. The ask names IMWG by name ",
                         "and it is the only non-trial source here, so a grid ",
                         "without it is a different comparison that still ",
                         "loads and still looks complete."))
  k <- paste(ifelse(is.na(df$dimension_id), "", df$dimension_id), sid, sep = "|")
  dup <- unique(k[duplicated(k) & nzchar(sid)])
  if (length(dup))
    bad <- c(bad, paste0("more than one row for the same (dimension, source): ",
                         paste(sub("\\|", " / ", dup), collapse = "; "),
                         ". A correction replaces the row; two rows render as ",
                         "two answers from one source."))
  filled <- !is.na(df$answer) & nzchar(trimws(df$answer))
  # An answered row that does not say which dimension it answers, or which
  # source answered it. A blank dimension_id is the NA-subscript trap: the
  # comparison selects on `filled$dimension_id == d$dimension_id`, NA == anything
  # is NA, and an NA subscript returns an all-NA row - so one malformed row
  # appears against every dimension with an answer nobody wrote.
  nodim <- filled & (is.na(df$dimension_id) | !nzchar(trimws(df$dimension_id)))
  if (any(nodim))
    bad <- c(bad, paste0("an answer with no dimension_id on row(s): ",
                         paste(which(nodim), collapse = ", "),
                         ". It matches no dimension, and a row that matches no ",
                         "dimension is selected against all of them."))
  nosid <- filled & !nzchar(sid)
  if (any(nosid))
    bad <- c(bad, paste0("an answer with no source_id on row(s): ",
                         paste(which(nosid), collapse = ", "),
                         ". Every check on this grid - one row per slot, one ",
                         "trial per slot - is keyed on the source, so a blank ",
                         "one is an answer nothing holds to anything."))
  # One trial per slot. The identity lives in the citation, so a slot whose
  # answered rows cite two different NCT ids is two trials in one column.
  cit <- ifelse(is.na(df$citation), "", df$citation)
  has_nct <- grepl("NCT[0-9]{8}", cit)
  # One id per CELL as well as one per slot. The slot check reads the first
  # match, so a cell citing "NCT-A and NCT-B" passed it while naming two
  # trials - and a slot could then hold "NCT-A and NCT-B" on one row and
  # "NCT-A and NCT-C" on the next, agreeing on their first matches and being
  # three trials. A cell that names two trials cannot say which one answered.
  n_per_cell <- vapply(regmatches(cit, gregexpr("NCT[0-9]{8}", cit)),
                       function(x) length(unique(x)), integer(1))
  multi <- filled & n_per_cell > 1L
  if (any(multi))
    bad <- c(bad, paste0("citation(s) naming more than one trial on row(s): ",
                         paste(which(multi), collapse = ", "),
                         ". One cell is one source answering one dimension; ",
                         "only the first id is read, so the rest are invisible."))
  for (s in setdiff(unique(sid[filled & nzchar(sid)]), "")) {
    ids <- unique(unlist(regmatches(cit[filled & sid == s & has_nct],
                                    gregexpr("NCT[0-9]{8}",
                                             cit[filled & sid == s & has_nct]))))
    if (length(ids) > 1L)
      bad <- c(bad, paste0(s, " cites more than one trial: ",
                           paste(ids, collapse = ", "),
                           ". One slot is one trial, or the column is a blend."))
    # The check above only bites once a citation carries an NCT id, so a slot
    # citing "the protocol, section 5.2" on every row could be a different
    # protocol each time. A trial slot has to be identifiable, so every answered
    # row names its trial. IMWG_consensus is not a trial and is not asked to.
    if (grepl("^trial_", s)) {
      un <- filled & sid == s & !has_nct
      if (any(un))
        bad <- c(bad, paste0(s, " has answered row(s) whose citation names no ",
                             "NCT id: ", paste(which(un), collapse = ", "),
                             ". Without one the slot cannot be shown to be a ",
                             "single trial, which is what the column claims."))
    } else {
      # IMWG is not a trial and has no NCT id, so identity comes from the
      # document. Unchecked, one slot could answer from the IMWG consensus on
      # one dimension and a different guideline on the next, rendered as one
      # column headed IMWG. The check is that the answered rows agree on which
      # document they are quoting, taken as the citation up to the section.
      docs <- unique(sub("[,;].*$", "", trimws(cit[filled & sid == s])))
      docs <- docs[nzchar(docs)]
      if (length(docs) > 1L)
        bad <- c(bad, paste0(s, " quotes more than one document: ",
                             paste(docs, collapse = " | "),
                             ". One slot is one source, or the column is a ",
                             "blend under a single heading."))
    }
  }
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
  cc <- tolower(trimws(ifelse(is.na(df$concordance), "", df$concordance)))
  badc <- filled & !cc %in% okc
  if (any(badc))
    bad <- c(bad, paste0("concordance must be agrees/differs/unclear on row(s): ",
                         paste(which(badc), collapse = ", ")))
  # "differs" is the finding this grid exists to produce, and it is the one
  # verdict that means nothing without HOW. Recorded alone it says the source
  # and the build disagree somewhere, which is not something anyone can act on
  # or check.
  nodiff <- filled & cc == "differs" &
    (is.na(df$notes) | !nzchar(trimws(df$notes)))
  if (any(nodiff))
    bad <- c(bad, paste0("concordance is 'differs' with no note saying how, on ",
                         "row(s): ", paste(which(nodiff), collapse = ", "),
                         ". A disagreement nobody can locate cannot be acted ",
                         "on or checked."))
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
                        retrieved = NA_character_,
                        answer = NA_character_, concordance = "not yet sourced",
                        notes = NA_character_,
                        stringsAsFactors = FALSE))
    data.frame(dimension_id = d$dimension_id, dimension = d$dimension,
               ours = d$ours, source_id = rows$source_id,
               source_type = rows$source_type, citation = rows$citation,
               retrieved = rows$retrieved,
               answer = rows$answer,
               # Three states, not two. "unclear" is a judgement somebody made;
               # a blank cell is nobody having looked. Rendering the second as
               # the first retires the question by calling it answered
               # ambiguously. Neither ever becomes agreement.
               concordance = ifelse(is.na(rows$concordance) |
                                      !nzchar(trimws(rows$concordance)),
                                    "sourced, not judged",
                                    tolower(trimws(rows$concordance))),
               # "differs" is only useful with how. Dropping notes here left the
               # verdict in the rendered file and the explanation in the source
               # CSV, which is the wrong way round for the one a reader opens.
               notes = rows$notes,
               stringsAsFactors = FALSE)
  })
  do.call(rbind, out)
}
