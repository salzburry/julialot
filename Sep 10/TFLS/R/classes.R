# The regimen classes a shell column may name.
#
# Nothing here classifies a regimen. The study package already did that: its
# SOC module writes one row per patient and line with a SOC_CATEGORY, and the
# values it may take are the protocol's category list. A second classifier over
# the drug list would be a second opinion of the same question, and a column
# heading would then mean one thing here and another on a page.
#
# So shells/regimen_classes.csv is a MAPPING. A class is a column heading and
# the SOC categories it covers, and the cells of that column are the patients
# whose line for that column carries one of them.
#
# A class mapped to no category is legitimate and is not an empty column: it
# says the study's vocabulary cannot separate that heading yet, and every cell
# in it is reported unfilled with that reason. A zero there would be a claim
# that nobody is in the class.

# What the study's SOC module can write. The first two lists are the
# protocol's, by line scope; the last two are what the module names a line that
# is a transplant with no regimen recorded, which no code list produces.
TFLS_SOC_CATEGORIES_1L <- c(
  "Quadruplet with anti-CD38 backbone", "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)", "Doublet/monotherapy", "Other")

TFLS_SOC_CATEGORIES_LATER <- c(
  "Quadruplet with anti-CD38 backbone", "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)", "Other novel agent", "CAR-T",
  "BCMA bispecific", "Non-BCMA bispecific", "Doublet/monotherapy", "Other")

TFLS_SOC_TRANSPLANT_CATEGORIES <- c("Allogeneic SCT (no regimen recorded)",
                                    "Autologous SCT (no regimen recorded)")

TFLS_SOC_CATEGORIES <- unique(c(TFLS_SOC_CATEGORIES_1L,
                                TFLS_SOC_CATEGORIES_LATER,
                                TFLS_SOC_TRANSPLANT_CATEGORIES))

# The column total. Never a rule: every line is in it, whatever it holds, which
# is what makes it the denominator the other columns divide up.
TFLS_OVERALL <- "OVERALL"

class_is_overall <- function(class_id) identical(chr(class_id), TFLS_OVERALL)

# The categories one cell of soc_categories names. Pipe or semicolon separated,
# never comma: a category name may hold a comma and a split on one would cut a
# name in half.
split_soc_categories <- function(x) {
  v <- chr(x)
  if (!nzchar(v)) return(character(0))
  v <- trimws(strsplit(v, "[|;]")[[1]])
  unique(v[nzchar(v)])
}

# Matched on the text as the package writes it, with case and spacing ignored,
# so a heading that says "CAR-T" and a file that says "CAR-t" are the same
# category and a file that says "CAR T" is not.
# The stratifications the package writes into its rate and count tables, and
# the label each puts on the row that is the line as a whole. STRATUM_TOTALS in
# the package's R/registry.R is the authority; it is restated here because a
# snapshot is filled where the package is not installed.
#
# They are MARGINS: a row is cut by regimen category or by age, never by both,
# so a column naming one leaves the other at its total.
TFLS_STRATUM_TOTALS <- c(SOC_CATEGORY = "(all categories)",
                         AGE_BAND = "(all ages)")

soc_key <- function(x) toupper(gsub("[[:space:]]+", " ", trimws(chr(x))))

unknown_soc_categories <- function(x) {
  v <- split_soc_categories(x)
  v[!soc_key(v) %in% soc_key(TFLS_SOC_CATEGORIES)]
}

# The drug a class refines its categories with, where it names one.
#
# This is a refinement of the study's own category, not a second
# classification: the category still decides the class, and the drug narrows it
# to the lines whose regimen holds that agent.
class_requires_drug <- function(class_id, classes) {
  if (!"requires_drug" %in% names(classes)) return("")
  i <- match(chr(class_id), chr(classes$class_id))
  if (is.na(i)) "" else toupper(chr(classes$requires_drug[i]))
}

# Whether a regimen holds an agent, as a whole token. The study writes the
# regimen as a space-separated list of abbreviations, so "POM" must not match
# inside another abbreviation.
regimen_has_drug <- function(regimen, drug) {
  d <- toupper(chr(drug))
  if (!nzchar(d)) return(rep(TRUE, length(regimen)))
  vapply(regimen, function(r) d %in% split_list(r), logical(1), USE.NAMES = FALSE)
}

# The categories a class covers, as the study package writes them.
class_categories <- function(class_id, classes) {
  i <- match(chr(class_id), chr(classes$class_id))
  if (is.na(i)) return(character(0))
  v <- split_soc_categories(classes$soc_categories[i])
  # Returned in the package's own spelling, so a comparison never depends on
  # how the shell happened to capitalise it.
  TFLS_SOC_CATEGORIES[match(soc_key(v), soc_key(TFLS_SOC_CATEGORIES))]
}

# What a column's class cell selects.
#
# It may name a class from regimen_classes.csv, or the study's own category
# straight out, or several of either separated by a pipe. Three answers:
#
#   all         the column total, which every line is in
#   categories  the SOC categories the cells of this column are drawn from
#   unmapped    a class the shell defines but maps to no category yet, so
#               every cell in the column is reported unfilled rather than
#               computed as a zero, which would claim the class is empty
#   unknown     a name that is neither, which is a defect in the shell
class_selection <- function(value, classes) {
  parts <- split_soc_categories(value)
  if (!length(parts)) return(list(kind = "all", categories = character(0),
                                  drug = "", why = ""))
  cats <- character(0); drugs <- character(0)
  for (p in parts) {
    if (class_is_overall(p))
      return(list(kind = "all", categories = character(0), drug = "", why = ""))
    if (chr(p) %in% chr(classes$class_id)) {
      c2 <- class_categories(p, classes)
      if (!length(c2))
        return(list(kind = "unmapped", categories = character(0), drug = "",
                    why = paste0("the shell maps the class ", p,
                      " to no SOC category, so the study's own categories ",
                      "cannot separate this column yet")))
      cats <- c(cats, c2)
      d <- class_requires_drug(p, classes)
      if (nzchar(d)) drugs <- c(drugs, d)
      next
    }
    k <- match(soc_key(p), soc_key(TFLS_SOC_CATEGORIES))
    if (!is.na(k)) { cats <- c(cats, TFLS_SOC_CATEGORIES[k]); next }
    return(list(kind = "unknown", categories = character(0), drug = "",
                why = paste0("'", p, "' is neither a class in ",
                  "regimen_classes.csv nor a SOC category the study writes")))
  }
  drugs <- unique(drugs)
  if (length(drugs) > 1L)
    return(list(kind = "unknown", categories = character(0), drug = "",
                why = paste0("this column joins classes that refine their ",
                  "categories with different drugs (", paste(drugs, collapse = ", "),
                  "), and one column cannot require both")))
  list(kind = "categories", categories = unique(cats),
       drug = if (length(drugs)) drugs else "", why = "")
}

# What a class cell is called in a heading: the class's label where it names
# one, and otherwise what it says.
class_heading <- function(value, classes) {
  v <- chr(value)
  if (v %in% chr(classes$class_id)) class_label(v, classes) else v
}

# Whether a table's SOC_CATEGORY value is one of a class's.
in_class <- function(category, class_id, classes) {
  cats <- class_categories(class_id, classes)
  if (!length(cats)) return(rep(FALSE, length(category)))
  soc_key(category) %in% soc_key(cats)
}

# What a class is called in a table heading.
class_label <- function(class_id, classes) {
  i <- match(chr(class_id), chr(classes$class_id))
  if (is.na(i)) chr(class_id) else chr(classes$label[i])
}
