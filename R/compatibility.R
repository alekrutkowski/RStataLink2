`%++%` <- function(x, y) paste0(x, y)

.rsl2_random_id <- function(n = 3L) paste(sample(c(LETTERS, letters, 0:9), n, TRUE), collapse = "")

.rsl2_seconds_to_ms <- function(x) {
  x <- as.numeric(x)[1L]
  if (is.na(x) || x < 0) stop("timeout must be a non-negative numeric value", call. = FALSE)
  if (is.infinite(x)) return(as.integer(.Machine$integer.max))
  as.integer(min(.Machine$integer.max, ceiling(1000 * x)))
}

.rsl2_connection <- function(id) {
  if (!inherits(id, "StataID")) stop("id must be a StataID object", call. = FALSE)
  con <- attr(id, "connection", exact = TRUE)
  if (!inherits(con, "rslng_connection")) stop("StataID has no live RStataLink2 connection", call. = FALSE)
  con
}

.rsl2_set_active_stata <- function(id) {
  if (!inherits(id, "StataID")) return(invisible(NULL))
  options(RStataLink2.active_id = id)
  invisible(id)
}

.rsl2_active_stata <- function() {
  id <- getOption("RStataLink2.active_id")
  if (inherits(id, "StataID")) return(id)
  stop("No active StataID is available. Start Stata with i <- startStata(), then call doInStata(i, code), or call doInStata(code) after startStata().", call. = FALSE)
}

.rsl2_same_connection <- function(x, y) {
  inherits(x, "StataID") && inherits(y, "StataID") &&
    identical(attr(x, "endpoint", exact = TRUE), attr(y, "endpoint", exact = TRUE))
}

.rsl2_resolve_id_code <- function(id, code) {
  if (inherits(id, "StataID")) return(list(id = id, code = code))
  if (is.null(id)) return(list(id = .rsl2_active_stata(), code = code))

  # Convenience extension: after startStata(), doInStata("display 1") uses
  # the most recently started Stata instance. The canonical RStataLink call
  # doInStata(i, "display 1") remains fully supported.
  if (is.character(id) && length(id) >= 1L && identical(code, "")) {
    return(list(id = .rsl2_active_stata(), code = id))
  }

  stop("id must be a StataID object. Use i <- startStata(); doInStata(i, code), or doInStata(code) after startStata().", call. = FALSE)
}

.rsl2_stata_cmd <- function(start_cmd) {
  if (!is.null(start_cmd) && length(start_cmd) == 1L && !is.na(start_cmd) && nzchar(start_cmd)) {
    return(.rsl2_normalize_path_arg(start_cmd))
  }
  stata <- .rslng_find_stata()
  if (is.na(stata) || !nzchar(stata)) {
    stop("Stata executable not found. Set option 'statapath', option 'RStataLink2.stata', or environment variable STATA_BIN.", call. = FALSE)
  }
  .rsl2_normalize_path_arg(stata)
}

.rsl2_endpoint <- function(id, compath) {
  opt <- getOption("RStataLink2.endpoint")
  if (!is.null(opt) && length(opt) == 1L && !is.na(opt) && nzchar(opt)) return(opt)
  if (.Platform$OS.type == "windows") {
    port <- getOption("RStataLink2.port")
    if (is.null(port)) port <- sample(20000:65000, 1L)
    rslng_default_endpoint(port = as.integer(port), compath = compath, id = id)
  } else {
    rslng_default_endpoint(compath = compath, id = id)
  }
}

.rsl2_port_available <- function(port) {
  port <- as.integer(port)[1L]
  if (is.na(port) || port < 1L || port > 65535L) return(FALSE)
  if (!exists("serverSocket", envir = baseenv(), mode = "function")) return(TRUE)
  z <- tryCatch(base::serverSocket(port), error = function(e) NULL)
  if (is.null(z)) return(FALSE)
  try(close(z), silent = TRUE)
  TRUE
}

.rsl2_pick_ports <- function(n, min_port = 20000L, max_port = 65000L) {
  n <- as.integer(n)[1L]
  if (is.na(n) || n < 1L) return(integer())
  min_port <- as.integer(min_port)[1L]
  max_port <- as.integer(max_port)[1L]
  if (is.na(min_port) || is.na(max_port) || min_port >= max_port) {
    min_port <- 20000L
    max_port <- 65000L
  }
  picked <- integer()
  attempts <- 0L
  while (length(picked) < n && attempts < 2000L) {
    attempts <- attempts + 1L
    candidate <- sample.int(max_port - min_port + 1L, 1L) + min_port - 1L
    if (candidate %in% picked) next
    if (.rsl2_port_available(candidate)) picked <- c(picked, candidate)
  }
  if (length(picked) < n) {
    stop("Could not reserve enough distinct local TCP ports for the Stata cluster", call. = FALSE)
  }
  picked
}

.rsl2_stata_quote <- function(x) {
  x <- enc2utf8(as.character(x)[1L])
  paste0("\"", gsub("\"", "\\\"", x, fixed = TRUE), "\"")
}

.rsl2_bootstrap_file <- function(endpoint, timeout_ms) {
  .rsl2_check_plugin_installed()
  dofile <- tempfile("rstatalink2-start-", fileext = ".do")
  logfile <- tempfile("rstatalink2-start-", fileext = ".log")
  ado_dir <- system.file("stata", package = "RStataLink2", mustWork = TRUE)
  plugin_dir <- .rsl2_plugin_dir(mustWork = TRUE)
  lines <- c(
    "version 16",
    "capture log close _all",
    sprintf("capture noisily log using %s, replace text name(rsl2_startup)", .rsl2_stata_quote(normalizePath(logfile, winslash = "/", mustWork = FALSE))),
    sprintf("adopath ++ %s", .rsl2_stata_quote(normalizePath(ado_dir, winslash = "/", mustWork = FALSE))),
    sprintf("adopath ++ %s", .rsl2_stata_quote(normalizePath(plugin_dir, winslash = "/", mustWork = FALSE))),
    'local __rsl2_oldpwd "`c(pwd)\'"',
    sprintf("capture noisily cd %s", .rsl2_stata_quote(normalizePath(plugin_dir, winslash = "/", mustWork = FALSE))),
    "capture noisily rslng plugincheck",
    "local __rsl2_plugin_rc = _rc",
    'capture noisily cd "`__rsl2_oldpwd\'"',
    "if `__rsl2_plugin_rc' {",
    '    di as err "RStataLink2 plugincheck failed, rc=`__rsl2_plugin_rc\'"',
    "    capture log close rsl2_startup",
    "    exit `__rsl2_plugin_rc'",
    "}",
    "capture log close rsl2_startup",
    sprintf("rslng server, endpoint(%s) timeout(%d) exitstata", .rsl2_stata_quote(endpoint), as.integer(timeout_ms)),
    "exit, STATA clear"
  )
  writeLines(lines, dofile, useBytes = TRUE)
  attr(dofile, "logfile") <- logfile
  dofile
}

.rsl2_startup_log_tail <- function(logfile, n = 80L) {
  if (is.null(logfile) || !nzchar(logfile) || !file.exists(logfile)) return("")
  x <- tryCatch(readLines(logfile, warn = FALSE, encoding = "UTF-8"), error = function(e) character())
  if (!length(x)) return("")
  paste(utils::tail(x, n), collapse = "\n")
}

.rsl2_parse_exec_text <- function(text) {
  lines <- strsplit(text %||% "", "\n", fixed = TRUE)[[1L]]
  rc <- NA_integer_
  if (length(lines) && grepl("^__RSL2_RC__=[0-9]+$", lines[[1L]])) {
    rc <- as.integer(sub("^__RSL2_RC__=", "", lines[[1L]]))
    text <- paste(lines[-1L], collapse = "\n")
  }
  list(rc = rc, log = text)
}

.rsl2_split_lines <- function(text) {
  text <- gsub("\r\n?", "\n", text %||% "", perl = TRUE)
  strsplit(text, "\n", fixed = TRUE)[[1L]]
}

.rsl2_trim_blank_lines <- function(lines) {
  if (!length(lines)) return(lines)
  while (length(lines) && !nzchar(trimws(lines[[1L]]))) lines <- lines[-1L]
  while (length(lines) && !nzchar(trimws(lines[[length(lines)]]))) lines <- lines[-length(lines)]
  lines
}

.rsl2_is_log_header_line <- function(x) {
  y <- trimws(x %||% "")
  grepl("^-{10,}$", y) ||
    grepl("^(name|log|log type|opened on|closed on):", y) ||
    grepl("^\\(file .+ not found\\)$", y)
}

.rsl2_drop_stata_log_header_footer <- function(text) {
  lines <- .rsl2_trim_blank_lines(.rsl2_split_lines(text))
  if (!length(lines)) return("")

  # Stata text logs start with a header such as a line of dashes, name:,
  # log:, log type:, and opened on:.  The header is useful in a file but noisy
  # in R's returned StataLog, so remove only this leading block.
  if (.rsl2_is_log_header_line(lines[[1L]])) {
    while (length(lines) && (.rsl2_is_log_header_line(lines[[1L]]) || !nzchar(trimws(lines[[1L]])))) {
      lines <- lines[-1L]
    }
  }

  # Some Stata versions append a closing block.  Remove a trailing header-like
  # block if it appears after the user's output.
  lines <- .rsl2_trim_blank_lines(lines)
  if (length(lines) && any(grepl("^\\s*closed on:", utils::tail(lines, 8L)))) {
    i <- length(lines)
    while (i >= 1L && (.rsl2_is_log_header_line(lines[[i]]) || !nzchar(trimws(lines[[i]])))) i <- i - 1L
    lines <- if (i >= 1L) lines[seq_len(i)] else character()
  }

  paste(.rsl2_trim_blank_lines(lines), collapse = "\n")
}

.rsl2_format_logged_command <- function(code) {
  if (!isTRUE(getOption("RStataLink2.log_show_command", TRUE))) return("")
  lines <- .rsl2_trim_blank_lines(.rsl2_split_lines(code))
  lines <- lines[nzchar(trimws(lines))]
  if (!length(lines)) return("")
  paste(paste0(". ", lines), collapse = "\n")
}

.rsl2_log_already_has_command <- function(log, code) {
  log_lines <- .rsl2_trim_blank_lines(.rsl2_split_lines(log))
  code_lines <- .rsl2_trim_blank_lines(.rsl2_split_lines(code))
  code_lines <- code_lines[nzchar(trimws(code_lines))]
  if (!length(log_lines) || !length(code_lines)) return(FALSE)
  first_code <- trimws(code_lines[[1L]])
  probes <- trimws(utils::head(log_lines, 10L))
  any(startsWith(probes, ".") & grepl(first_code, probes, fixed = TRUE))
}

.rsl2_clean_exec_log <- function(log, code) {
  if (!isTRUE(getOption("RStataLink2.clean_log", TRUE))) return(log %||% "")
  body <- .rsl2_drop_stata_log_header_footer(log)
  cmd <- .rsl2_format_logged_command(code)
  if (nzchar(cmd) && !.rsl2_log_already_has_command(body, code)) {
    body <- if (nzchar(body)) paste(cmd, body, sep = "\n") else cmd
  }
  body
}

`%||%` <- function(x, y) if (is.null(x)) y else x

.rsl2_empty_results <- function(results) {
  if (is.null(results)) return(NULL)
  out <- vector("list", length(results))
  names(out) <- paste0(results, "_class")
  out
}

.rsl2_df_results_to_list <- function(df) {
  if (is.null(df) || !nrow(df)) return(structure(list(), class = "StataResults"))
  for (nm in c("type", "name", "txt_value", "rowname", "colname")) {
    if (!nm %in% names(df)) df[[nm]] <- ""
    df[[nm]][is.na(df[[nm]])] <- ""
  }
  if (!"value" %in% names(df)) df$value <- NA_real_
  out <- list()

  scalars <- df[df$type == "scalars", , drop = FALSE]
  if (nrow(scalars)) out$scalars <- as.list(stats::setNames(scalars$value, scalars$name))

  macros <- df[df$type == "macros", , drop = FALSE]
  if (nrow(macros)) out$macros <- as.list(stats::setNames(macros$txt_value, macros$name))

  mdf <- df[df$type == "matrices", , drop = FALSE]
  if (nrow(mdf)) {
    mnames <- unique(mdf$name)
    mats <- lapply(mnames, function(mn) {
      z <- mdf[mdf$name == mn, , drop = FALSE]
      rn <- unique(z$rowname)
      cn <- unique(z$colname)
      M <- matrix(NA_real_, nrow = length(rn), ncol = length(cn), dimnames = list(rn, cn))
      for (i in seq_len(nrow(z))) M[z$rowname[[i]], z$colname[[i]]] <- z$value[[i]]
      class(M) <- c(class(M), "StataMatrix")
      M
    })
    names(mats) <- mnames
    out$matrices <- mats
  }

  bdf <- df[df$type %in% c("_b", "_se"), , drop = FALSE]
  if (nrow(bdf)) {
    rn <- unique(bdf$name)
    b <- bdf[bdf$type == "_b", , drop = FALSE]
    se <- bdf[bdf$type == "_se", , drop = FALSE]
    modeldf <- data.frame(
      coef = b$value[match(rn, b$name)],
      stderr = se$value[match(rn, se$name)],
      row.names = rn,
      check.names = FALSE
    )
    class(modeldf) <- c(class(modeldf), "Stata_b_se")
    out$modeldf <- modeldf
  }
  structure(out, class = "StataResults")
}

.rsl2_get_result_class <- function(id, cls, timeout) {
  ans <- .rslng_request(.rsl2_connection(id), "GET_RESULTS", text = cls, timeout = .rsl2_seconds_to_ms(timeout))
  if (!identical(ans$kind, "DATA")) stop("Stata result extraction failed: ", ans$text, call. = FALSE)
  res <- .rsl2_df_results_to_list(.rslng_decode_df(ans$payload))
  if (length(res) == 0L) NULL else res
}

.rsl2_get_results <- function(id, results, timeout) {
  if (is.null(results)) return(NULL)
  tmp <- list()
  for (cls in c("r", "e")) {
    if (cls %in% results) {
      tmp[[cls]] <- tryCatch(.rsl2_get_result_class(id, cls, timeout), error = function(e) NULL)
    }
  }
  out <- lapply(results, function(cls) tmp[[cls]])
  names(out) <- paste0(results, "_class")
  out
}

.rsl2_validate_results <- function(results) {
  if (is.null(results)) return(NULL)
  if (!is.character(results) || !all(results %in% c("e", "r"))) {
    stop("results must be NULL or a character vector containing 'e', 'r', or both", call. = FALSE)
  }
  results
}

.rsl2_wrap_code <- function(code, preserve_restore) {
  code <- paste(enc2utf8(code), collapse = "\n")
  if (isTRUE(preserve_restore)) paste("preserve", code, "restore", sep = "\n") else code
}

.rsl2_make_output <- function(ans, future) {
  parsed <- .rsl2_parse_exec_text(ans$text)
  rc <- parsed$rc
  if (is.na(rc)) rc <- if (identical(ans$kind, "OK")) 0L else 459L
  is_error <- !identical(ans$kind, "OK") || (!is.na(rc) && rc != 0L)
  out <- list()
  if (!isTRUE(future$nolog)) {
    out$log <- structure(.rsl2_clean_exec_log(parsed$log, future$code), class = "StataLog")
  }
  if (is_error) {
    out$error <- structure(as.integer(rc), class = "StataErrorNumber")
  }
  if (!is.null(future$results) && !is_error) {
    out$results <- .rsl2_get_results(future$id, future$results, future$timeout)
  }
  if (isTRUE(future$import_df) && !is_error) {
    out$df <- tryCatch(.rsl2_import_df(future), error = function(e) NULL)
  }
  out
}

# S3 display methods --------------------------------------------------------

print.StataLog <- function(log) {
  cat(log, sep = "\n")
  invisible(log)
}

print.StataResults <- function(res) {
  str(res)
  invisible(res)
}

print.StataErrorNumber <- function(res) {
  str(res)
  invisible(res)
}

str.Stata_b_se <- function(res, ...) {
  print(res)
  cat("\n")
}

str.StataMatrix <- function(res, ...) {
  cat("\n")
  print(res)
  cat("\n")
}

print.StataID <- function(id) {
  cat("StataID object:\n")
  cat("\n Stata server id:\n ", names(id), "\n", sep = "")
  cat("\n NNG endpoint:\n ", attr(id, "endpoint", exact = TRUE) %||% unclass(id), "\n", sep = "")
  cat("\n Should Stata close after stopStata():\n yes, for sessions launched by startStata()\n\n", sep = "")
  invisible(id)
}


# Hybrid data-frame transfer helpers ---------------------------------------

.rsl2_df_string_info <- function(x) {
  x <- as.data.frame(x, stringsAsFactors = FALSE, optional = TRUE)
  if (!ncol(x) || !nrow(x)) {
    return(list(cols = integer(), cells = 0, bytes = 0, max_width = 0))
  }
  is_str <- vapply(x, function(z) is.factor(z) || is.character(z), logical(1L))
  idx <- which(is_str)
  if (!length(idx)) {
    return(list(cols = integer(), cells = 0, bytes = 0, max_width = 0))
  }
  prep <- lapply(x[idx], .rslng_string_prepare)
  bytes <- sum(vapply(prep, function(z) sum(z$len[!z$is_na]), numeric(1L)))
  max_width <- max(vapply(prep, function(z) z$width, integer(1L)), 0L)
  list(cols = idx, cells = nrow(x) * length(idx), bytes = bytes, max_width = max_width)
}

.rsl2_prepare_dta_df <- function(x) {
  x <- as.data.frame(x, stringsAsFactors = FALSE, optional = TRUE)
  names(x) <- .rslng_make_stata_names(names(x))
  for (nm in names(x)) {
    z <- x[[nm]]
    if (is.factor(z) || is.character(z)) {
      z <- enc2utf8(as.character(z))
      z[is.na(z)] <- ""
      x[[nm]] <- z
    } else if (inherits(z, "Date")) {
      x[[nm]] <- as.numeric(z)
    } else if (inherits(z, "POSIXt")) {
      x[[nm]] <- as.numeric(z)
    } else if (is.logical(z) || is.integer(z) || is.numeric(z)) {
      x[[nm]] <- as.numeric(z)
    } else {
      stop("unsupported column type for Stata transfer: ", paste(class(z), collapse = "/"), call. = FALSE)
    }
  }
  x
}

.rsl2_df_transfer_mode <- function(df, import_df = FALSE) {
  mode <- tolower(as.character(getOption("RStataLink2.df_transfer", "auto"))[1L])
  if (!mode %in% c("auto", "nng", "dta")) mode <- "auto"
  if (mode == "nng" || is.null(df)) return("nng")

  info <- .rsl2_df_string_info(df)
  max_width <- as.integer(getOption("RStataLink2.dta_max_string_width", 244L)[1L])
  if (is.na(max_width) || max_width < 1L) max_width <- 244L
  if (info$max_width > max_width) {
    if (mode == "dta") {
      stop("RStataLink2 dta transfer cannot currently handle string columns wider than ", max_width, " bytes; use option RStataLink2.df_transfer = 'nng'.", call. = FALSE)
    }
    return("nng")
  }
  if (!requireNamespace("foreign", quietly = TRUE)) {
    if (mode == "dta") stop("foreign is needed for dta transfer but is not installed", call. = FALSE)
    return("nng")
  }
  if (mode == "dta") return("dta")

  cell_threshold <- as.numeric(getOption("RStataLink2.dta_string_cell_threshold", 2000L)[1L])
  byte_threshold <- as.numeric(getOption("RStataLink2.dta_string_byte_threshold", 50000L)[1L])
  if (is.na(cell_threshold) || cell_threshold < 0) cell_threshold <- 2000
  if (is.na(byte_threshold) || byte_threshold < 0) byte_threshold <- 50000
  if (length(info$cols) && (info$cells >= cell_threshold || info$bytes >= byte_threshold)) "dta" else "nng"
}

.rsl2_exec_internal <- function(id, code, timeout_ms) {
  ans <- .rslng_request(.rsl2_connection(id), "EXEC_NOLOG_NOSNAP", text = code, timeout = timeout_ms)
  parsed <- .rsl2_parse_exec_text(ans$text)
  rc <- parsed$rc
  if (is.na(rc)) rc <- if (identical(ans$kind, "OK")) 0L else 459L
  if (!identical(ans$kind, "OK") || rc != 0L) {
    stop("Stata internal command failed with rc=", rc, ": ", parsed$log, call. = FALSE)
  }
  invisible(ans)
}

.rsl2_put_df_dta <- function(id, df, timeout_ms, fallback = TRUE) {
  file <- tempfile("rstatalink2-put-", fileext = ".dta")
  on.exit(unlink(file, force = TRUE), add = TRUE)
  d <- .rsl2_prepare_dta_df(df)
  w <- tryCatch({
    foreign::write.dta(d, file = file, version = 7L, convert.dates = FALSE)
    TRUE
  }, error = function(e) e)
  if (inherits(w, "error")) {
    if (isTRUE(fallback)) return(FALSE)
    stop("DTA transfer write failed: ", conditionMessage(w), call. = FALSE)
  }
  code <- sprintf("use %s, clear", .rsl2_stata_quote(normalizePath(file, winslash = "/", mustWork = FALSE)))
  z <- tryCatch({ .rsl2_exec_internal(id, code, timeout_ms); TRUE }, error = function(e) e)
  if (inherits(z, "error")) {
    if (isTRUE(fallback)) return(FALSE)
    stop("DTA transfer import failed: ", conditionMessage(z), call. = FALSE)
  }
  TRUE
}

.rsl2_put_df <- function(id, df, timeout_ms, import_df = FALSE) {
  mode <- .rsl2_df_transfer_mode(df, import_df = import_df)
  if (mode == "dta") {
    forced <- identical(tolower(as.character(getOption("RStataLink2.df_transfer", "auto"))[1L]), "dta")
    ok <- .rsl2_put_df_dta(id, df, timeout_ms, fallback = !forced)
    if (isTRUE(ok)) return("dta")
  }
  rslng_put_df(.rsl2_connection(id), df, timeout = timeout_ms)
  "nng"
}

.rsl2_get_df_transfer_mode <- function(future) {
  mode <- tolower(as.character(getOption("RStataLink2.df_get_transfer", "auto"))[1L])
  if (!mode %in% c("auto", "nng", "dta")) mode <- "auto"
  if (mode == "auto") {
    # For round trips that used a large string-heavy DTA import, exporting via
    # Stata's native writer tends to be faster than per-cell string extraction.
    if (identical(future$df_transfer, "dta")) "dta" else "nng"
  } else {
    mode
  }
}

.rsl2_get_df_dta <- function(id, timeout_ms, fallback = TRUE) {
  if (!requireNamespace("foreign", quietly = TRUE)) {
    if (isTRUE(fallback)) return(NULL)
    stop("foreign is needed for dta transfer but is not installed", call. = FALSE)
  }
  file <- tempfile("rstatalink2-get-", fileext = ".dta")
  on.exit(unlink(file, force = TRUE), add = TRUE)
  code <- sprintf("saveold %s, replace version(12)", .rsl2_stata_quote(normalizePath(file, winslash = "/", mustWork = FALSE)))
  z <- tryCatch({ .rsl2_exec_internal(id, code, timeout_ms); TRUE }, error = function(e) e)
  if (inherits(z, "error") || !file.exists(file)) {
    if (isTRUE(fallback)) return(NULL)
    if (inherits(z, "error")) stop("DTA transfer export failed: ", conditionMessage(z), call. = FALSE)
    stop("DTA transfer export failed: Stata did not create the output file", call. = FALSE)
  }
  d <- tryCatch(
    foreign::read.dta(file, convert.factors = FALSE, convert.dates = FALSE,
                      missing.type = FALSE, warn.missing.labels = FALSE),
    error = function(e) e
  )
  if (inherits(d, "error")) {
    if (isTRUE(fallback)) return(NULL)
    stop("DTA transfer read failed: ", conditionMessage(d), call. = FALSE)
  }
  as.data.frame(d, stringsAsFactors = FALSE, optional = TRUE)
}

.rsl2_import_df <- function(future) {
  mode <- .rsl2_get_df_transfer_mode(future)
  timeout_ms <- .rsl2_seconds_to_ms(future$timeout)
  if (mode == "dta") {
    forced <- identical(tolower(as.character(getOption("RStataLink2.df_get_transfer", "auto"))[1L]), "dta")
    d <- .rsl2_get_df_dta(future$id, timeout_ms, fallback = !forced)
    if (is.data.frame(d)) return(d)
  }
  rslng_get_df(.rsl2_connection(future$id), timeout = timeout_ms)
}

# Public RStataLink-compatible API -----------------------------------------

startStata <- function(timeout = 60, start_cmd = getOption("statapath"), compath = tempdir(),
                       exit_on_error601 = FALSE, verify = TRUE) {
  stopifnot(is.numeric(timeout), timeout >= 0,
            is.character(compath), length(compath) == 1L,
            is.logical(exit_on_error601), length(exit_on_error601) == 1L,
            is.logical(verify), length(verify) == 1L)
  dir.create(compath, recursive = TRUE, showWarnings = FALSE)
  id <- .rsl2_random_id()
  endpoint <- .rsl2_endpoint(id, compath)
  timeout_ms <- .rsl2_seconds_to_ms(timeout)
  cmd <- .rsl2_stata_cmd(start_cmd)
  dofile <- .rsl2_bootstrap_file(endpoint, min(timeout_ms, 60000L))
  logfile <- attr(dofile, "logfile", exact = TRUE)
  launch <- tryCatch(
    system2(cmd, args = c("do", normalizePath(dofile, winslash = "\\", mustWork = FALSE)),
            wait = FALSE, stdout = FALSE, stderr = FALSE),
    error = function(e) e
  )
  if (inherits(launch, "error")) {
    stop("Starting Stata failed before the server bootstrap ran: ", conditionMessage(launch), call. = FALSE)
  }
  con <- rslng_connect(endpoint = endpoint, timeout = min(timeout_ms, 60000L), dial = TRUE)
  ID <- structure(endpoint, names = id, class = "StataID")
  attr(ID, "exit_on_error601") <- exit_on_error601
  attr(ID, "connection") <- con
  attr(ID, "endpoint") <- endpoint
  attr(ID, "compath") <- normalizePath(compath, mustWork = FALSE)
  attr(ID, "bootstrap") <- dofile
  attr(ID, "start_cmd") <- cmd
  if (isTRUE(verify)) {
    t0 <- Sys.time()
    ok <- FALSE
    repeat {
      ok <- isTRUE(tryCatch(isStataReady(ID, timeout = min(1, timeout)), error = function(e) FALSE))
      if (ok || as.numeric(difftime(Sys.time(), t0, units = "secs")) >= timeout) break
      Sys.sleep(0.05)
    }
    if (!ok) {
      try(rslng_stop(con, close = TRUE, timeout = 1000L), silent = TRUE)
      try(rslng_close(con), silent = TRUE)
      log_tail <- .rsl2_startup_log_tail(logfile)
      msg <- "Starting Stata failed."
      if (nzchar(log_tail)) msg <- paste0(msg, "\n\nStata startup log tail:\n", log_tail)
      stop(msg, call. = FALSE)
    }
    message("Stata server started successfully.")
  }
  .rsl2_set_active_stata(ID)
  ID
}

isStataReady <- function(id = .rsl2_active_stata(), timeout = 1) {
  if (!inherits(id, "StataID")) stop("id must be a StataID object", call. = FALSE)
  stopifnot(is.numeric(timeout), timeout >= 0)
  con <- .rsl2_connection(id)
  tryCatch({
    rslng_ping(con, timeout = .rsl2_seconds_to_ms(timeout))
    TRUE
  }, error = function(e) FALSE)
}

doInStata <- function(id = NULL, code = "", df = NULL, import_df = !is.null(df), results = c("e", "r"),
                      timeout = Inf, preserve_restore = FALSE, cleanup = TRUE,
                      nolog = FALSE, future = FALSE) {
  resolved <- .rsl2_resolve_id_code(id, code)
  id <- resolved$id
  code <- resolved$code
  stopifnot(is.character(code), is.data.frame(df) || is.null(df),
            is.logical(import_df), length(import_df) == 1L,
            is.numeric(timeout), timeout >= 0,
            is.logical(preserve_restore), length(preserve_restore) == 1L,
            is.logical(cleanup), length(cleanup) == 1L,
            is.logical(nolog), length(nolog) == 1L,
            is.logical(future), length(future) == 1L)
  results <- .rsl2_validate_results(results)
  con <- .rsl2_connection(id)
  timeout_ms <- .rsl2_seconds_to_ms(timeout)
  df_transfer <- "nng"
  if (!is.null(df)) df_transfer <- .rsl2_put_df(id, df, timeout_ms, import_df = import_df)
  exec_code <- .rsl2_wrap_code(code, preserve_restore)
  # Avoid Stata-side log capture and result snapshotting when the caller does
  # not request them.  This cuts overhead for tiny commands and data-transfer
  # jobs while preserving the public API and the result-capable path.
  exec_kind <- if (is.null(results)) {
    if (isTRUE(nolog)) "EXEC_NOLOG_NOSNAP" else "EXEC_NOSNAP"
  } else {
    if (isTRUE(nolog)) "EXEC_NOLOG" else "EXEC"
  }
  .rslng_send_request(con, exec_kind, text = exec_code, timeout = timeout_ms)
  fut <- structure(list(
    id = id,
    code = exec_code,
    import_df = import_df,
    results = results,
    timeout = timeout,
    cleanup = cleanup,
    nolog = nolog,
    df_transfer = df_transfer,
    sent = TRUE,
    created = Sys.time()
  ), class = "StataFuture")
  if (isTRUE(future)) fut else getStataFuture(fut)
}

getStataFuture <- function(StataFuture) {
  stopifnot(inherits(StataFuture, "StataFuture"))
  ans <- .rslng_recv_response(.rsl2_connection(StataFuture$id), timeout = .rsl2_seconds_to_ms(StataFuture$timeout))
  .rsl2_make_output(ans, StataFuture)
}

deleteStataFuture <- function(StataFuture) {
  stopifnot(inherits(StataFuture, "StataFuture"))
  warning("NNG-backed jobs are sent immediately and cannot be deleted after dispatch; receive the result with getStataFuture() before reusing this StataID.", call. = FALSE)
  invisible(NULL)
}

stopStata <- function(id = .rsl2_active_stata(), clear = FALSE) {
  if (!inherits(id, "StataID")) stop("id must be a StataID object", call. = FALSE)
  stopifnot(is.logical(clear), length(clear) == 1L)
  con <- .rsl2_connection(id)
  if (isTRUE(clear)) {
    try(doInStata(id, "clear", import_df = FALSE, results = NULL, timeout = 3, nolog = TRUE), silent = TRUE)
  }
  tryCatch(rslng_stop(con, close = TRUE, timeout = 3000L), error = function(e) NULL)
  active <- getOption("RStataLink2.active_id")
  if (.rsl2_same_connection(active, id)) options(RStataLink2.active_id = NULL)
  invisible(NULL)
}

startStataCluster <- function(n = parallel::detectCores(), ...) {
  n <- as.integer(n)[1L]
  if (is.na(n) || n < 1L) stop("n must be a positive integer", call. = FALSE)
  retries <- as.integer(getOption("RStataLink2.cluster_start_retries", 4L))[1L]
  if (is.na(retries) || retries < 0L) retries <- 0L
  pause <- as.numeric(getOption("RStataLink2.cluster_start_pause", 0.25))[1L]
  if (is.na(pause) || pause < 0) pause <- 0
  old_port <- getOption("RStataLink2.port", NULL)
  on.exit(options(RStataLink2.port = old_port), add = TRUE)
  fixed_ports <- !is.null(old_port) && length(old_port) >= n
  port_pool <- NULL
  if (.Platform$OS.type == "windows") {
    if (!is.null(old_port) && length(old_port) == 1L && n > 1L) {
      warning("Ignoring scalar option('RStataLink2.port') while starting a cluster; each worker needs a distinct endpoint.", call. = FALSE)
      options(RStataLink2.port = NULL)
      fixed_ports <- FALSE
    }
    if (!isTRUE(fixed_ports)) {
      port_pool <- .rsl2_pick_ports(n)
    }
  }
  out <- vector("list", n)
  for (i in seq_len(n)) {
    last_error <- NULL
    for (attempt in seq_len(retries + 1L)) {
      if (.Platform$OS.type == "windows") {
        if (isTRUE(fixed_ports)) {
          options(RStataLink2.port = as.integer(old_port[[i]]))
        } else {
          # Re-pick a port on each retry.  If a late-starting failed attempt
          # eventually binds its original port, the retry will not collide with it.
          options(RStataLink2.port = if (attempt == 1L) port_pool[[i]] else .rsl2_pick_ports(1L)[[1L]])
        }
      }
      z <- tryCatch(startStata(...), error = function(e) e)
      if (inherits(z, "StataID")) {
        out[[i]] <- z
        last_error <- NULL
        break
      }
      last_error <- z
      if (attempt <= retries) Sys.sleep(pause * attempt)
    }
    if (inherits(last_error, "error")) {
      invisible(lapply(out[!vapply(out, is.null, logical(1L))], function(id) try(stopStata(id, clear = TRUE), silent = TRUE)))
      stop("Starting Stata cluster failed at worker ", i, " after ", retries + 1L,
           " attempt(s): ", conditionMessage(last_error), call. = FALSE)
    }
    if (pause > 0 && i < n) Sys.sleep(pause)
  }
  out
}


stopStataCluster <- function(cl, ...) {
  stopifnot(is.list(cl), all(vapply(cl, inherits, logical(1L), what = "StataID")))
  invisible(lapply(cl, stopStata, ...))
}

.rsl2_only_ready <- function(cl, ...) {
  ready <- vapply(cl, isStataReady, logical(1L), ...)
  if (!any(ready)) stop("No Stata instance is available/ready!", call. = FALSE)
  if (sum(ready) < length(cl)) {
    warning("Using only ", sum(ready), " of ", length(cl), " Stata instances, those that are available/ready!", call. = FALSE)
  }
  cl[ready]
}

.rsl2_code_list <- function(X) {
  if (is.character(X)) X <- as.list(X)
  if (!is.list(X) || !all(vapply(X, is.character, logical(1L)))) {
    stop("X must be a character vector or a list of character vectors", call. = FALSE)
  }
  X
}

doInStataCluster <- function(cl, X, isStataReadyTimeout = 1, ...) {
  stopifnot(is.list(cl), all(vapply(cl, inherits, logical(1L), what = "StataID")),
            is.numeric(isStataReadyTimeout), isStataReadyTimeout >= 0)
  X <- .rsl2_code_list(X)
  if (!length(X)) return(list())
  cl <- .rsl2_only_ready(cl, timeout = isStataReadyTimeout)
  args <- list(...)
  args$future <- NULL
  out <- vector("list", length(X))
  starts <- seq.int(1L, length(X), by = length(cl))
  for (s in starts) {
    idx <- s:min(length(X), s + length(cl) - 1L)
    futs <- Map(function(id, code) do.call(doInStata, c(list(id = id, code = code, future = TRUE), args)),
                cl[seq_along(idx)], X[idx])
    out[idx] <- lapply(futs, getStataFuture)
  }
  out
}

doInStataClusterLB <- function(cl, X, isStataReadyTimeout = 1, ...) {
  stopifnot(is.list(cl), all(vapply(cl, inherits, logical(1L), what = "StataID")),
            is.numeric(isStataReadyTimeout), isStataReadyTimeout >= 0)
  X <- .rsl2_code_list(X)
  if (!length(X)) return(list())
  cl <- .rsl2_only_ready(cl, timeout = isStataReadyTimeout)

  # Real load balancing: keep every ready worker busy.  As soon as one worker
  # replies, store its result in the original X order and immediately dispatch
  # the next waiting job to that freed worker.  This differs from
  # doInStataCluster(), which dispatches fixed-size waves and waits for the
  # slowest worker in each wave before starting the next wave.
  args <- list(...)
  args$future <- NULL
  n_workers <- min(length(cl), length(X))
  out <- vector("list", length(X))
  inflight <- vector("list", n_workers)
  inflight_index <- rep(NA_integer_, n_workers)
  next_job <- 1L
  completed <- 0L
  poll_interval <- as.numeric(getOption("RStataLink2.lb_poll_interval", 0.01))[1L]
  if (is.na(poll_interval) || poll_interval < 0) poll_interval <- 0.01

  submit <- function(worker) {
    job <- next_job
    next_job <<- next_job + 1L
    inflight[worker] <<- list(do.call(
      doInStata,
      c(list(id = cl[[worker]], code = X[[job]], future = TRUE), args)
    ))
    inflight_index[worker] <<- job
    invisible(NULL)
  }

  for (worker in seq_len(n_workers)) submit(worker)

  while (completed < length(X)) {
    progressed <- FALSE
    for (worker in seq_len(n_workers)) {
      fut <- inflight[[worker]]
      if (is.null(fut)) next
      if (is.finite(fut$timeout) &&
          as.numeric(difftime(Sys.time(), fut$created, units = "secs")) > fut$timeout) {
        stop("Timed out while load-balancing Stata cluster job ", inflight_index[[worker]], call. = FALSE)
      }
      ans <- .rslng_try_recv_response(.rsl2_connection(fut$id))
      if (inherits(ans, "rslng_recv_error")) {
        stop("NNG receive failed while load-balancing Stata cluster jobs: ", ans$message, call. = FALSE)
      }
      if (is.null(ans)) next
      job <- inflight_index[[worker]]
      out[job] <- list(.rsl2_make_output(ans, fut))
      inflight[worker] <- list(NULL)
      inflight_index[worker] <- NA_integer_
      completed <- completed + 1L
      progressed <- TRUE
      if (next_job <= length(X)) submit(worker)
    }
    if (!progressed) Sys.sleep(poll_interval)
  }

  out
}
