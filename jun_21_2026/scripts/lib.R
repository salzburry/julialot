# lib.R - shared helpers for the local (Level-1) refactor toolkit.
# Dependency-light: base R + jsonlite + yaml + digest (all present in Domino).
.lotlib <- TRUE

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

# Correct left-ZERO-pad (base formatC(flag="0") space-pads characters).
lpad0 <- function(x, n) {
  x <- as.character(x)
  ifelse(nchar(x) >= n, x, paste0(strrep("0", pmax(0, n - nchar(x))), x))
}

# NDC contract: require a validated 11-digit NDC. A bare 10-digit value is
# AMBIGUOUS (which package segment is missing its leading zero depends on the
# source's 4-4-2 / 5-3-2 / 5-4-1 format), so we do NOT guess - segment-aware
# 10->11 conversion is the source adapter's job. Non-11-digit -> NA (rejected).
normalize_ndc <- function(code) {
  d <- gsub("[^0-9]", "", as.character(code))
  ifelse(nchar(d) == 11L, d, NA_character_)
}
normalize_proc <- function(code) toupper(gsub("[^A-Za-z0-9]", "", as.character(code)))

read_yaml_file <- function(path) suppressWarnings(yaml::read_yaml(path))
read_json_file <- function(path) jsonlite::fromJSON(path, simplifyVector = TRUE,
                                                    simplifyDataFrame = FALSE)

# Deterministic serialization: recursively SORT named-list keys (and data-frame
# columns) so structures that are identical up to key/column order serialize
# identically. Unnamed lists (arrays) keep their order. Scalars stringify as-is.
canonical_string <- function(obj) {
  if (is.data.frame(obj)) {
    obj <- obj[, order(names(obj)), drop = FALSE]
    return(paste0("df{", paste(sort(do.call(paste, c(lapply(obj, as.character), sep = "\037"))), collapse = "|"), "}"))
  }
  if (is.list(obj)) {
    nm <- names(obj)
    if (!is.null(nm) && length(nm)) { o <- order(nm); obj <- obj[o]; nm <- nm[o] } else nm <- rep("", length(obj))
    return(paste0("{", paste(vapply(seq_along(obj),
      function(i) paste0(nm[i], ":", canonical_string(obj[[i]])), character(1)), collapse = ","), "}"))
  }
  if (is.null(obj)) return("null")
  paste(as.character(obj), collapse = "|")
}

# Stable content hash: canonicalize (sorted keys/rows, recursively for lists) then
# sha256. Reordering data-frame columns or (nested) list KEYS must not change
# identity. Data frames AND lists are canonicalized; a bare scalar/string hashes
# as-is. (Scalar VALUES, incl. their whitespace, are content and are preserved.)
content_hash <- function(obj) {
  canon <- if (is.data.frame(obj)) {            # unchanged from the original df path
    obj <- obj[, order(names(obj)), drop = FALSE]
    sort(do.call(paste, c(lapply(obj, as.character), sep = "\037")))
  } else if (is.list(obj)) {
    canonical_string(obj)
  } else obj
  digest::digest(canon, algo = "sha256")
}

is_iso_date <- function(x) {
  x <- as.character(x)
  !is.na(x) & nzchar(x) & !is.na(suppressWarnings(as.Date(x, "%Y-%m-%d")))
}

# Resolve scripts/lib.R relative to a script invoked via Rscript --file=...
.find_lib <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) {
    p <- file.path(dirname(sub("^--file=", "", fa[1])), "lib.R")
    if (file.exists(p)) return(p)
  }
  for (p in c("scripts/lib.R", "lib.R", "../scripts/lib.R")) if (file.exists(p)) return(p)
  NULL
}
