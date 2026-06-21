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

# Canonical NDC: the STORED value must itself be exactly 11 digits (no stripping).
# normalize_ndc() strips separators (adapter use); is_ndc11() is the canonical-
# storage check so a dashed or letter-bearing value is rejected, not silently kept.
is_ndc11 <- function(x) grepl("^[0-9]{11}$", as.character(x))

# Shared closed-schema conformance engine (used by study + manifest validators).
# Recursively enforces `required` and (where additionalProperties:false) rejects
# undeclared keys at EVERY object level AND descends into array `items` (so e.g.
# manifest secrets[] cannot carry an undeclared value field). `oneOf` passes if any
# branch validates, reporting the branch matching the value's kind. Leaf
# types/enums/formats and `$ref` bodies remain the full JSON-Schema tool's job.
schema_node_errors <- function(obj, schema, path = NULL) {
  if (!is.null(schema$oneOf)) {
    branches <- lapply(schema$oneOf, function(s) schema_node_errors(obj, s, path))
    if (any(vapply(branches, length, integer(1)) == 0)) return(character(0))
    is_obj  <- vapply(schema$oneOf, function(s) !is.null(s$properties) || identical(s$type, "object"), logical(1))
    is_null <- vapply(schema$oneOf, function(s) identical(s$type, "null"), logical(1))
    pick <- if (is.list(obj) && any(is_obj)) which(is_obj)[1]
            else if (is.null(obj) && any(is_null)) which(is_null)[1]
            else which.min(vapply(branches, length, integer(1)))
    return(branches[[pick]])
  }
  here <- path %||% "(root)"
  if (identical(schema$type, "null"))
    return(if (is.null(obj)) character(0) else sprintf("%s: expected null", here))
  if (identical(schema$type, "array") && !is.null(schema$items)) {
    if (is.null(obj)) return(character(0))
    elems <- if (is.list(obj)) obj else as.list(obj)
    return(unlist(lapply(seq_along(elems), function(i)
      schema_node_errors(elems[[i]], schema$items, sprintf("%s[%d]", here, i)))))
  }
  has_props <- !is.null(schema$properties) || identical(schema$type, "object")
  if (!has_props) return(character(0))
  if (!is.null(obj) && !is.list(obj)) return(sprintf("%s: expected object", here))
  errors <- character(0)
  keys <- names(obj) %||% character(0)
  miss <- setdiff(unlist(schema$required %||% list()), keys)
  if (length(miss)) errors <- c(errors, sprintf("%s: missing required key(s): %s", here, paste(miss, collapse = ", ")))
  declared <- names(schema$properties %||% list())
  if (isFALSE(schema$additionalProperties)) {
    extra <- setdiff(keys, declared)
    if (length(extra)) errors <- c(errors, sprintf("%s: undeclared key(s) (closed schema): %s", here, paste(extra, collapse = ", ")))
  }
  for (k in intersect(keys, declared))
    errors <- c(errors, schema_node_errors(obj[[k]], schema$properties[[k]],
                                           if (is.null(path)) k else paste0(path, ".", k)))
  errors
}
schema_conformance <- function(obj, schema_path) {
  schema <- tryCatch(read_json_file(schema_path), error = function(e) NULL)
  if (is.null(schema)) return(sprintf("could not read schema (%s)", schema_path))
  schema_node_errors(obj, schema, NULL)
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
