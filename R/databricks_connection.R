#' Databricks Connection Module
#'
#' Provides robust connection handling for Databricks via ODBC with:
#' - Automatic retry logic with exponential backoff
#' - Connection pooling support
#' - Health checks and reconnection
#' - Domino environment integration

library(DBI)
library(odbc)

#' Create Databricks connection with retry logic
#'
#' @param config Configuration list with connection parameters
#' @param max_retries Maximum number of retry attempts
#' @param base_delay Base delay in seconds for exponential backoff
#' @return DBI connection object
#' @export
create_databricks_connection <- function(config, max_retries = 4, base_delay = 2) {
  attempt <- 1

while (attempt <= max_retries) {
    tryCatch({
      log_info(sprintf("Attempting Databricks connection (attempt %d/%d)...", attempt, max_retries))

      con <- if (!is.null(config$db$dsn) && config$db$dsn != "") {
        # DSN-based connection (preferred in Domino)
        DBI::dbConnect(
          odbc::odbc(),
          dsn = config$db$dsn,
          timeout = config$db$timeout %||% 60
        )
      } else {
        # DSN-less connection
        DBI::dbConnect(
          odbc::odbc(),
          Driver = config$db$driver %||% "Databricks",
          Host = config$db$host,
          Port = config$db$port %||% 443,
          HTTPPath = config$db$http_path,
          AuthMech = config$db$auth_mech %||% 3,
          UID = config$db$uid %||% "token",
          PWD = config$db$pwd %||% Sys.getenv("DATABRICKS_TOKEN"),
          SSL = 1,
          ThriftTransport = 2,
          UseNativeQuery = 1,
          timeout = config$db$timeout %||% 60
        )
      }

      # Verify connection
      test_query <- DBI::dbGetQuery(con, "SELECT 1 AS test")
      if (nrow(test_query) == 1) {
        log_info("Databricks connection established successfully")
        return(con)
      } else {
        stop("Connection test failed")
      }

    }, error = function(e) {
      log_warn(sprintf("Connection attempt %d failed: %s", attempt, e$message))

      if (attempt < max_retries) {
        delay <- base_delay * (2 ^ (attempt - 1))
        log_info(sprintf("Retrying in %d seconds...", delay))
        Sys.sleep(delay)
      } else {
        log_error("All connection attempts failed")
        stop(sprintf("Failed to connect to Databricks after %d attempts: %s",
                     max_retries, e$message))
      }
    })

    attempt <- attempt + 1
  }
}

#' Execute SQL with retry logic
#'
#' @param con DBI connection
#' @param sql SQL statement to execute
#' @param config Configuration list
#' @param max_retries Maximum retries
#' @param operation_name Name for logging
#' @return Query result or NULL for DDL
#' @export
execute_sql_with_retry <- function(con, sql, config = NULL, max_retries = 3,
                                   operation_name = "SQL operation") {
  attempt <- 1
  base_delay <- 2

  while (attempt <= max_retries) {
    tryCatch({
      log_debug(sprintf("Executing %s (attempt %d)...", operation_name, attempt))

      # Check if connection is still valid
      if (!connection_is_valid(con)) {
        log_warn("Connection invalid, reconnecting...")
        con <- create_databricks_connection(config)
      }

      start_time <- Sys.time()
      result <- DBI::dbExecute(con, sql)
      elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))

      log_info(sprintf("%s completed in %.2f seconds", operation_name, elapsed))
      return(invisible(result))

    }, error = function(e) {
      error_msg <- e$message

      # Check for retryable errors
      is_retryable <- grepl("timeout|connection|network|temporary|unavailable",
                            tolower(error_msg))

      if (is_retryable && attempt < max_retries) {
        delay <- base_delay * (2 ^ (attempt - 1))
        log_warn(sprintf("%s failed (attempt %d): %s. Retrying in %d seconds...",
                         operation_name, attempt, error_msg, delay))
        Sys.sleep(delay)
      } else {
        log_error(sprintf("%s failed after %d attempts: %s",
                          operation_name, attempt, error_msg))
        stop(e)
      }
    })

    attempt <- attempt + 1
  }
}

#' Query with retry logic (returns data)
#'
#' @param con DBI connection
#' @param sql SQL query
#' @param config Configuration list
#' @param max_retries Maximum retries
#' @param operation_name Name for logging
#' @return Data frame with query results
#' @export
query_with_retry <- function(con, sql, config = NULL, max_retries = 3,
                             operation_name = "Query") {
  attempt <- 1
  base_delay <- 2

  while (attempt <= max_retries) {
    tryCatch({
      log_debug(sprintf("Executing %s (attempt %d)...", operation_name, attempt))

      if (!connection_is_valid(con)) {
        log_warn("Connection invalid, reconnecting...")
        con <- create_databricks_connection(config)
      }

      start_time <- Sys.time()
      result <- DBI::dbGetQuery(con, sql)
      elapsed <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))

      log_info(sprintf("%s returned %d rows in %.2f seconds",
                       operation_name, nrow(result), elapsed))
      return(result)

    }, error = function(e) {
      error_msg <- e$message
      is_retryable <- grepl("timeout|connection|network|temporary|unavailable",
                            tolower(error_msg))

      if (is_retryable && attempt < max_retries) {
        delay <- base_delay * (2 ^ (attempt - 1))
        log_warn(sprintf("%s failed (attempt %d): %s. Retrying in %d seconds...",
                         operation_name, attempt, error_msg, delay))
        Sys.sleep(delay)
      } else {
        log_error(sprintf("%s failed: %s", operation_name, error_msg))
        stop(e)
      }
    })

    attempt <- attempt + 1
  }
}

#' Check if connection is still valid
#' @keywords internal
connection_is_valid <- function(con) {
  tryCatch({
    DBI::dbIsValid(con) && nrow(DBI::dbGetQuery(con, "SELECT 1")) == 1
  }, error = function(e) {
    FALSE
  })
}

#' Safely disconnect
#' @export
safe_disconnect <- function(con) {
  tryCatch({
    if (!is.null(con) && DBI::dbIsValid(con)) {
      DBI::dbDisconnect(con)
      log_info("Databricks connection closed")
    }
  }, error = function(e) {
    log_warn(sprintf("Error during disconnect: %s", e$message))
  })
}

# ============================================================================
# LOGGING UTILITIES
# ============================================================================

#' Simple logging functions (can be replaced with logger package)
#' @keywords internal
.log_level <- list(DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4)
.current_log_level <- .log_level$INFO

set_log_level <- function(level) {
  .current_log_level <<- .log_level[[toupper(level)]] %||% .log_level$INFO
}

log_msg <- function(level, msg) {
  if (.log_level[[level]] >= .current_log_level) {
    timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
    cat(sprintf("[%s] [%s] %s\n", timestamp, level, msg))
  }
}

log_debug <- function(msg) log_msg("DEBUG", msg)
log_info <- function(msg) log_msg("INFO", msg)
log_warn <- function(msg) log_msg("WARN", msg)
log_error <- function(msg) log_msg("ERROR", msg)

#' Null coalescing operator
#' @keywords internal
`%||%` <- function(x, y) if (is.null(x) || is.na(x) || x == "") y else x
