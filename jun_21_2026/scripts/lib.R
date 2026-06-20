# lib.R - shared helpers for the local (Level-1) refactor toolkit.
# Dependency-light: base R + jsonlite + yaml + digest (all present in Domino).
.lotlib <- TRUE

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

# Correct left-ZERO-pad (base formatC(flag="0") space-pads characters).
lpad0 <- function(x, n) {
  x <- as.character(x)
  ifelse(nchar(x) >= n, x, paste0(strrep("0", pmax(0, n - nchar(x))), x))
}

# The documented NDC rule: strip non-digits, left-zero-pad to 11; 10-11 digits
# only, else NA (rejected, never silently matched).
normalize_ndc <- function(code) {
  d <- gsub("[^0-9]", "", as.character(code))
  ifelse(nchar(d) >= 10 & nchar(d) <= 11, lpad0(d, 11), NA_character_)
}
normalize_proc <- function(code) toupper(gsub("[^A-Za-z0-9]", "", as.character(code)))

read_yaml_file <- function(path) suppressWarnings(yaml::read_yaml(path))
read_json_file <- function(path) jsonlite::fromJSON(path, simplifyVector = TRUE,
                                                    simplifyDataFrame = FALSE)

# Stable content hash: canonicalize (sorted keys/rows) then sha256. Reordering
# or whitespace must not change identity.
content_hash <- function(obj) {
  canon <- if (is.data.frame(obj)) {
    obj <- obj[, order(names(obj)), drop = FALSE]
    rows <- do.call(paste, c(lapply(obj, as.character), sep = "\037"))
    sort(rows)
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
