#!/usr/bin/env Rscript

# Benchmark RStataLink2 against RStataLink.
#
# Examples:
#   Rscript --vanilla benchmark-rstatalink2-vs-rstatalink.R --quick
#   Rscript benchmark-rstatalink2-vs-rstatalink.R --quick
#   Rscript benchmark-rstatalink2-vs-rstatalink.R --stata "C:/Program Files/Stata18/StataMP-64.exe"
#   Rscript benchmark-rstatalink2-vs-rstatalink.R --packages RStataLink2,RStataLink --reps 5 --sizes 100,10000,100000
#
# The script intentionally does not attach either package, because both expose
# the same public function names. It discovers Stata from --stata, environment
# variables, PATH, common Windows/macOS install locations, and Windows AppV paths.

`%||%` <- function(x, y) if (is.null(x) || !length(x) || is.na(x[[1L]]) || !nzchar(x[[1L]])) y else x

unquote_path <- function(x) {
  if (!length(x) || is.na(x[[1L]])) return("")
  x <- trimws(as.character(x[[1L]]))
  if (!nzchar(x)) return(x)
  repeat {
    n <- nchar(x)
    if (n >= 2L && ((startsWith(x, '"') && endsWith(x, '"')) || (startsWith(x, "'") && endsWith(x, "'")))) {
      x <- trimws(substr(x, 2L, n - 1L))
    } else break
  }
  x
}

clean_path_string <- function(x) {
  x <- path.expand(unquote_path(x))
  if (!nzchar(x)) return(x)
  x <- gsub("\\\\", "/", x)
  if (.Platform$OS.type == "windows") x <- sub("^([A-Za-z]):/+", "\\1:/", x, perl = TRUE)
  x
}

normalise_path <- function(x) {
  x <- clean_path_string(x)
  if (nzchar(x) && file.exists(x)) normalizePath(x, winslash = "/", mustWork = FALSE) else x
}

ensure_dir <- function(path, label = "directory") {
  path <- clean_path_string(path)
  if (!nzchar(path)) stop("Empty ", label, " path", call. = FALSE)
  ok <- dir.exists(path) || suppressWarnings(dir.create(path, recursive = TRUE, showWarnings = FALSE))
  if (!ok || !dir.exists(path)) {
    stop("Could not create ", label, ": ", path, call. = FALSE)
  }
  normalizePath(path, winslash = "/", mustWork = FALSE)
}

first_existing <- function(x) {
  x <- unique(x[!is.na(x) & nzchar(x)])
  x <- x[file.exists(x)]
  if (length(x)) normalizePath(x[[1L]], winslash = "/", mustWork = FALSE) else ""
}

find_stata <- function(user_path = "") {
  user_path <- normalise_path(user_path)
  if (nzchar(user_path) && file.exists(user_path)) return(user_path)

  env_names <- c("STATA_BIN", "RSTATALINK2_STATA", "RSTATALINK_STATA", "RSTATAPATH", "STATAPATH")
  env <- Sys.getenv(env_names, unset = "")
  env <- env[nzchar(env)]
  for (v in env) {
    v <- normalise_path(v)
    if (nzchar(v) && file.exists(v)) return(v)
  }

  candidates <- if (.Platform$OS.type == "windows") {
    c("StataMP-64.exe", "StataSE-64.exe", "StataBE-64.exe", "StataNowMP-64.exe", "StataNowSE-64.exe", "StataNowBE-64.exe", "Stata-64.exe")
  } else {
    c("stata-mp", "stata-se", "stata-be", "stata", "xstata-mp", "xstata-se", "xstata-be", "xstata")
  }
  hit <- Sys.which(candidates)
  hit <- unname(hit[nzchar(hit)][1L])
  if (length(hit) && !is.na(hit) && nzchar(hit)) return(normalizePath(hit, winslash = "/", mustWork = FALSE))

  if (suppressWarnings(suppressPackageStartupMessages(requireNamespace("RStataLink2", quietly = TRUE)))) {
    helper <- tryCatch(get(".rslng_find_stata", envir = asNamespace("RStataLink2")), error = function(e) NULL)
    if (is.function(helper)) {
      hit2 <- tryCatch(helper(), error = function(e) NA_character_)
      hit2 <- normalise_path(hit2)
      if (!is.na(hit2) && nzchar(hit2) && file.exists(hit2)) return(hit2)
    }
  }

  if (.Platform$OS.type == "windows") {
    pats <- c(
      "C:/Program Files/Stata*/StataMP-64.exe",
      "C:/Program Files/Stata*/StataSE-64.exe",
      "C:/Program Files/Stata*/StataBE-64.exe",
      "C:/Program Files/Stata*/StataNowMP-64.exe",
      "C:/Program Files/Stata*/StataNowSE-64.exe",
      "C:/Program Files/Stata*/StataNowBE-64.exe",
      "C:/Program Files (x86)/Stata*/StataMP-64.exe",
      "C:/Program Files (x86)/Stata*/StataSE-64.exe",
      "C:/Program Files (x86)/Stata*/StataBE-64.exe",
      "C:/ProgramData/Microsoft/AppV/Client/Integration/*/Root/StataMP-64.exe",
      "C:/ProgramData/Microsoft/AppV/Client/Integration/*/Root/StataSE-64.exe",
      "C:/ProgramData/Microsoft/AppV/Client/Integration/*/Root/StataBE-64.exe",
      "C:/ProgramData/AppV/*/*/Root/StataMP-64.exe",
      "C:/ProgramData/AppV/*/*/Root/StataSE-64.exe",
      "C:/ProgramData/AppV/*/*/Root/StataBE-64.exe"
    )
    hit <- first_existing(unlist(lapply(pats, Sys.glob), use.names = FALSE))
    if (nzchar(hit)) return(hit)

    roots <- c(
      "C:/ProgramData/Microsoft/AppV/Client/Integration",
      "C:/ProgramData/AppV"
    )
    found <- unlist(lapply(roots[dir.exists(roots)], function(root) {
      list.files(root, pattern = "^Stata.*-64[.]exe$", recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
    }), use.names = FALSE)
    hit <- first_existing(found)
    if (nzchar(hit)) return(hit)
    return("")
  }

  if (Sys.info()[["sysname"]] == "Darwin") {
    pats <- c(
      "/Applications/Stata*/StataMP.app/Contents/MacOS/StataMP",
      "/Applications/Stata*/StataSE.app/Contents/MacOS/StataSE",
      "/Applications/Stata*/StataBE.app/Contents/MacOS/StataBE",
      "/Applications/Stata*/Stata.app/Contents/MacOS/Stata"
    )
    return(first_existing(unlist(lapply(pats, Sys.glob), use.names = FALSE)))
  }

  ""
}

stata_option_value <- function(path) {
  path <- normalise_path(path)
  if (.Platform$OS.type == "windows" && grepl("[[:space:]]", path)) paste0('"', path, '"') else path
}

split_csv <- function(x) trimws(strsplit(x, ",", fixed = TRUE)[[1L]])

parse_args <- function(args = commandArgs(trailingOnly = TRUE)) {
  cfg <- list(
    stata = "",
    out = file.path(getwd(), paste0("rstatalink-benchmark-", format(Sys.time(), "%Y%m%d-%H%M%S"))),
    packages = c("RStataLink2", "RStataLink"),
    reps = 5L,
    startup_reps = 1L,
    sizes = c(100L, 10000L, 100000L),
    timeout = 120,
    startup_timeout = 120,
    ready_timeout = 1,
    cluster_workers = 0L,
    seed = 20260622L,
    quick = FALSE,
    keep_going = TRUE,
    make_zip = TRUE
  )
  value <- function(i, key) {
    if (grepl("=", key, fixed = TRUE)) return(sub("^[^=]*=", "", key))
    if (i >= length(args)) stop("Missing value after ", key, call. = FALSE)
    args[[i + 1L]]
  }
  advance <- function(key) if (grepl("=", key, fixed = TRUE)) 1L else 2L

  i <- 1L
  while (i <= length(args)) {
    key <- args[[i]]
    name <- sub("=.*$", "", key)
    if (name %in% c("--help", "-h")) {
      cat(paste0(
        "Usage:\n",
        "  Rscript benchmark-rstatalink2-vs-rstatalink.R [options]\n\n",
        "Options:\n",
        "  --stata PATH              Stata executable path. Also read from STATA_BIN, RSTATALINK2_STATA, RSTATALINK_STATA, RSTATAPATH, STATAPATH.\n",
        "                            Tip: use Rscript --vanilla to avoid site-profile network/proxy diagnostics.\n",
        "  --out DIR                 Output directory.\n",
        "  --packages A,B            Default: RStataLink2,RStataLink.\n",
        "  --reps N                  Repetitions per operation. Default: 5.\n",
        "  --startup-reps N          Startup/shutdown repetitions. Default: 1.\n",
        "  --sizes N1,N2,...         Data sizes. Default: 100,10000,100000.\n",
        "  --timeout SECONDS         Per-job timeout. Default: 120.\n",
        "  --startup-timeout SECONDS Startup timeout. Default: 120.\n",
        "  --ready-timeout SECONDS   isStataReady timeout. Default: 1.\n",
        "  --cluster-workers N       Optional static and load-balanced cluster benchmark workers. Default: 0.\n",
        "  --quick                   Use reps=2 and sizes=100,5000.\n",
        "  --no-zip                  Do not create a zip archive of outputs.\n",
        "  --stop-on-error           Stop at first benchmark error.\n"
      ))
      quit(save = "no", status = 0)
    } else if (name == "--stata") {
      cfg$stata <- value(i, key); i <- i + advance(key)
    } else if (name == "--out") {
      cfg$out <- value(i, key); i <- i + advance(key)
    } else if (name == "--packages") {
      cfg$packages <- split_csv(value(i, key)); cfg$packages <- cfg$packages[nzchar(cfg$packages)]; i <- i + advance(key)
    } else if (name == "--reps") {
      cfg$reps <- as.integer(value(i, key)); i <- i + advance(key)
    } else if (name == "--startup-reps") {
      cfg$startup_reps <- as.integer(value(i, key)); i <- i + advance(key)
    } else if (name == "--sizes") {
      cfg$sizes <- as.integer(split_csv(value(i, key))); i <- i + advance(key)
    } else if (name == "--timeout") {
      cfg$timeout <- as.numeric(value(i, key)); i <- i + advance(key)
    } else if (name == "--startup-timeout") {
      cfg$startup_timeout <- as.numeric(value(i, key)); i <- i + advance(key)
    } else if (name == "--ready-timeout") {
      cfg$ready_timeout <- as.numeric(value(i, key)); i <- i + advance(key)
    } else if (name == "--cluster-workers") {
      cfg$cluster_workers <- as.integer(value(i, key)); i <- i + advance(key)
    } else if (name == "--quick") {
      cfg$quick <- TRUE; i <- i + 1L
    } else if (name == "--no-zip") {
      cfg$make_zip <- FALSE; i <- i + 1L
    } else if (name == "--stop-on-error") {
      cfg$keep_going <- FALSE; i <- i + 1L
    } else {
      stop("Unknown argument: ", key, call. = FALSE)
    }
  }
  if (isTRUE(cfg$quick)) {
    cfg$reps <- 2L
    cfg$startup_reps <- 1L
    cfg$sizes <- c(100L, 5000L)
  }
  cfg$stata <- find_stata(cfg$stata)
  cfg$out <- clean_path_string(cfg$out)
  cfg$sizes <- cfg$sizes[!is.na(cfg$sizes) & cfg$sizes >= 0L]
  cfg$packages <- unique(cfg$packages)
  cfg
}

pkgfun <- function(pkg, fun) getExportedValue(pkg, fun)

call_supported <- function(fun, args) {
  fmls <- names(formals(fun))
  if (!"..." %in% fmls) args <- args[names(args) %in% fmls]
  do.call(fun, args)
}

numeric_df <- function(n) {
  i <- seq_len(n)
  data.frame(
    x = as.numeric(i),
    y = sqrt(i),
    z = sin(i / 10),
    w = as.numeric(i %% 17L),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

mixed_df <- function(n) {
  i <- seq_len(n)
  data.frame(
    id = as.numeric(i),
    value = log1p(i),
    group = sprintf("g%03d", i %% 1000L),
    txt = ifelse(i %% 10L == 0L, NA_character_, sprintf("row_%06d", i)),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

string_df <- function(n) {
  i <- seq_len(n)
  data.frame(
    id = as.numeric(i),
    short = sprintf("s%05d", i),
    medium = paste0("medium_text_", sprintf("%06d", i), "_", strrep("x", (i %% 31L) + 1L)),
    stringsAsFactors = FALSE,
    check.names = FALSE
  )
}

row_result <- function(package, operation, variant = "", n = NA_integer_, rep = NA_integer_, elapsed = NA_real_, ok = FALSE, error = "", command = "") {
  data.frame(
    timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    package = package,
    operation = operation,
    variant = variant,
    n = as.integer(n),
    rep = as.integer(rep),
    elapsed_sec = as.numeric(elapsed),
    ok = isTRUE(ok),
    error = as.character(error),
    command = as.character(command),
    stringsAsFactors = FALSE
  )
}

time_call <- function(package, operation, variant = "", n = NA_integer_, rep = NA_integer_, command = "", expr) {
  invisible(gc(FALSE))
  start <- proc.time()[["elapsed"]]
  ok <- TRUE
  err <- ""
  tryCatch(
    force(expr),
    error = function(e) {
      ok <<- FALSE
      err <<- conditionMessage(e)
      NULL
    }
  )
  elapsed <- proc.time()[["elapsed"]] - start
  row_result(package, operation, variant, n, rep, elapsed, ok, err, command)
}

add_row <- function(out, row, cfg) {
  print(row[, c("package", "operation", "variant", "n", "rep", "elapsed_sec", "ok", "error")], row.names = FALSE)
  if (!isTRUE(row$ok) && !isTRUE(cfg$keep_going)) stop(row$error, call. = FALSE)
  c(out, list(row))
}

check_df <- function(x, n, min_cols = 1L) {
  if (!is.list(x) || is.null(x$df) || !is.data.frame(x$df)) stop("No data frame returned", call. = FALSE)
  if (nrow(x$df) != n) stop("Unexpected row count: got ", nrow(x$df), ", expected ", n, call. = FALSE)
  if (ncol(x$df) < min_cols) stop("Unexpected column count", call. = FALSE)
  invisible(TRUE)
}

check_required_cols <- function(d, nm) {
  miss <- setdiff(nm, names(d))
  if (length(miss)) stop("Missing returned column(s): ", paste(miss, collapse = ", "), call. = FALSE)
}

check_num_equal <- function(actual, expected, nm, tol = 1e-9) {
  actual <- as.numeric(actual)
  expected <- as.numeric(expected)
  ok <- isTRUE(all.equal(actual, expected, tolerance = tol, check.attributes = FALSE))
  if (!ok) stop("Round-trip numeric mismatch in column ", nm, call. = FALSE)
}

check_chr_equal <- function(actual, expected, nm) {
  actual <- as.character(actual)
  expected <- as.character(expected)
  ok <- identical(actual, expected)
  if (!ok) stop("Round-trip character mismatch in column ", nm, call. = FALSE)
}

check_roundtrip_numeric <- function(x, source) {
  check_df(x, nrow(source), 5L)
  d <- x$df
  check_required_cols(d, c("x", "y", "z", "w", "sum_xy"))
  check_num_equal(d$x, source$x, "x")
  check_num_equal(d$y, source$y, "y")
  check_num_equal(d$z, source$z, "z")
  check_num_equal(d$w, source$w, "w")
  check_num_equal(d$sum_xy, source$x + source$y, "sum_xy")
  invisible(TRUE)
}

check_roundtrip_mixed <- function(x, source) {
  check_df(x, nrow(source), 5L)
  d <- x$df
  check_required_cols(d, c("id", "value", "group", "txt", "txt_len"))
  check_num_equal(d$id, source$id, "id")
  check_num_equal(d$value, source$value, "value")
  check_chr_equal(as.character(d$group), as.character(source$group), "group")
  txt_expected <- as.character(source$txt)
  txt_returned <- as.character(d$txt)
  non_missing <- !is.na(txt_expected)
  if (!identical(txt_returned[non_missing], txt_expected[non_missing])) {
    stop("Round-trip character mismatch in non-missing txt values", call. = FALSE)
  }
  missing_ok <- is.na(txt_returned[!non_missing]) | txt_returned[!non_missing] == ""
  if (length(missing_ok) && !all(missing_ok)) {
    stop("Round-trip missing string values were not returned as NA or empty Stata strings", call. = FALSE)
  }
  expected_len <- nchar(replace(txt_expected, is.na(txt_expected), ""), type = "chars")
  check_num_equal(d$txt_len, expected_len, "txt_len")
  invisible(TRUE)
}

check_cluster_output <- function(x, expected_jobs) {
  if (!is.list(x)) stop("Cluster result is not a list", call. = FALSE)
  if (length(x) != expected_jobs) {
    stop("Unexpected cluster result count: got ", length(x), ", expected ", expected_jobs, call. = FALSE)
  }
  bad <- vapply(x, function(z) is.list(z) && !is.null(z$error), logical(1L))
  if (any(bad)) stop("Cluster job returned Stata error at position ", which(bad)[[1L]], call. = FALSE)
  invisible(TRUE)
}

extract_stata_error <- function(x) {
  if (!is.list(x) || is.null(x$error)) return(NA_integer_)
  suppressWarnings(as.integer(x$error[[1L]]))
}

run_package <- function(pkg, cfg) {
  out <- list()
  if (!suppressWarnings(suppressPackageStartupMessages(requireNamespace(pkg, quietly = TRUE)))) {
    return(list(row_result(pkg, "package_load", ok = FALSE, error = paste("Package", pkg, "is not installed"))))
  }
  if (is.na(cfg$stata) || !nzchar(cfg$stata)) {
    return(list(row_result(pkg, "stata_discovery", ok = FALSE, error = "Stata executable not found. Use --stata PATH or set STATA_BIN/RSTATALINK2_STATA.")))
  }

  stata_opt <- stata_option_value(cfg$stata)
  old_opt <- options(statapath = stata_opt, RStataLink2.stata = cfg$stata)
  env_names <- c("STATA_BIN", "RSTATALINK2_STATA", "RSTATALINK_STATA", "RSTATAPATH", "STATAPATH")
  old_env <- Sys.getenv(env_names, unset = NA_character_)
  Sys.setenv(STATA_BIN = cfg$stata, RSTATALINK2_STATA = cfg$stata, RSTATALINK_STATA = cfg$stata, RSTATAPATH = cfg$stata, STATAPATH = cfg$stata)
  on.exit({
    do.call(options, old_opt)
    for (nm in names(old_env)) {
      if (is.na(old_env[[nm]])) Sys.unsetenv(nm) else do.call(Sys.setenv, stats::setNames(list(old_env[[nm]]), nm))
    }
  }, add = TRUE)

  startStata <- pkgfun(pkg, "startStata")
  stopStata <- pkgfun(pkg, "stopStata")
  isStataReady <- pkgfun(pkg, "isStataReady")
  doInStata <- pkgfun(pkg, "doInStata")
  getStataFuture <- pkgfun(pkg, "getStataFuture")
  startStataCluster <- pkgfun(pkg, "startStataCluster")
  stopStataCluster <- pkgfun(pkg, "stopStataCluster")
  doInStataCluster <- pkgfun(pkg, "doInStataCluster")
  doInStataClusterLB <- pkgfun(pkg, "doInStataClusterLB")

  start_one <- function() call_supported(startStata, list(timeout = cfg$startup_timeout, start_cmd = stata_opt, verify = TRUE))
  stop_one <- function(id, clear = TRUE) try(call_supported(stopStata, list(id = id, clear = clear)), silent = TRUE)
  ready_one <- function(id) call_supported(isStataReady, list(id = id, timeout = cfg$ready_timeout))
  do_one <- function(id, code, ...) call_supported(doInStata, c(list(id = id, code = code), list(...)))

  if (cfg$startup_reps > 0L) {
    for (r in seq_len(cfg$startup_reps)) {
      row <- time_call(pkg, "startup_shutdown", rep = r, expr = {
        id0 <- start_one()
        on.exit(stop_one(id0, clear = TRUE), add = TRUE)
        if (!isTRUE(ready_one(id0))) stop("Stata not ready", call. = FALSE)
        stop_one(id0, clear = TRUE)
      })
      out <- add_row(out, row, cfg)
    }
  }

  id <- NULL
  row <- time_call(pkg, "startup_main_session", rep = 1L, expr = {
    id <- start_one()
    if (!isTRUE(ready_one(id))) stop("Stata not ready", call. = FALSE)
  })
  out <- add_row(out, row, cfg)
  if (!isTRUE(row$ok)) return(out)
  on.exit(stop_one(id, clear = TRUE), add = TRUE)

  invisible(do_one(id, "display 0", results = NULL, import_df = FALSE, nolog = TRUE, timeout = cfg$timeout))

  for (r in seq_len(cfg$reps)) {
    out <- add_row(out, time_call(pkg, "ready_ping", rep = r, expr = {
      if (!isTRUE(ready_one(id))) stop("Not ready", call. = FALSE)
    }), cfg)
    out <- add_row(out, time_call(pkg, "exec_display_with_log", rep = r, command = "display 3 + 4", expr = {
      z <- do_one(id, "display 3 + 4", results = NULL, import_df = FALSE, nolog = FALSE, timeout = cfg$timeout)
      if (is.null(z$log)) stop("No log returned", call. = FALSE)
      if (!any(grepl("7", as.character(z$log), fixed = TRUE))) stop("Expected output not found in log", call. = FALSE)
    }), cfg)
    out <- add_row(out, time_call(pkg, "exec_display_no_log", rep = r, command = "display 3 + 4", expr = {
      z <- do_one(id, "display 3 + 4", results = NULL, import_df = FALSE, nolog = TRUE, timeout = cfg$timeout)
      if (!is.null(z$log)) stop("Log was returned despite nolog=TRUE", call. = FALSE)
    }), cfg)
    out <- add_row(out, time_call(pkg, "exec_multiline", rep = r, command = paste(c("display 10", "display 20", "display 30"), collapse = "\n"), expr = {
      do_one(id, c("display 10", "display 20", "display 30"), results = NULL, import_df = FALSE, nolog = TRUE, timeout = cfg$timeout)
    }), cfg)
    out <- add_row(out, time_call(pkg, "exec_error_capture", rep = r, command = "this_is_not_a_stata_command", expr = {
      z <- do_one(id, "this_is_not_a_stata_command", results = NULL, import_df = FALSE, nolog = TRUE, timeout = cfg$timeout)
      if (is.na(extract_stata_error(z))) stop("Expected a Stata error code", call. = FALSE)
    }), cfg)
    out <- add_row(out, time_call(pkg, "stata_sysuse_summarize_r", rep = r, command = "sysuse auto, clear\nsummarize price\nreturn list", expr = {
      z <- do_one(id, "sysuse auto, clear\nsummarize price\nreturn list", results = "r", import_df = FALSE, nolog = TRUE, timeout = cfg$timeout)
      if (is.null(z$results$r_class)) stop("No r-class results", call. = FALSE)
    }), cfg)
    out <- add_row(out, time_call(pkg, "stata_regress_e", rep = r, command = "sysuse auto, clear\nregress price weight trunk, robust", expr = {
      z <- do_one(id, "sysuse auto, clear\nregress price weight trunk, robust", results = "e", import_df = FALSE, nolog = TRUE, timeout = cfg$timeout)
      if (is.null(z$results$e_class)) stop("No e-class results", call. = FALSE)
    }), cfg)
    out <- add_row(out, time_call(pkg, "future_sleep_get", rep = r, command = "sleep 100\ndisplay 123", expr = {
      f <- do_one(id, "sleep 100\ndisplay 123", results = NULL, import_df = FALSE, nolog = TRUE, timeout = cfg$timeout, future = TRUE)
      getStataFuture(f)
    }), cfg)
  }

  for (n in cfg$sizes) {
    dnum <- numeric_df(n)
    dmix <- mixed_df(n)
    dstr <- string_df(n)
    for (r in seq_len(cfg$reps)) {
      out <- add_row(out, time_call(pkg, "r_to_stata_numeric", "put_only", n, r, command = "count", expr = {
        do_one(id, "count", df = dnum, import_df = FALSE, results = NULL, nolog = TRUE, timeout = cfg$timeout)
      }), cfg)
      out <- add_row(out, time_call(pkg, "r_to_stata_mixed", "put_only", n, r, command = "count", expr = {
        do_one(id, "count", df = dmix, import_df = FALSE, results = NULL, nolog = TRUE, timeout = cfg$timeout)
      }), cfg)
      out <- add_row(out, time_call(pkg, "r_to_stata_string", "put_only", n, r, command = "count", expr = {
        do_one(id, "count", df = dstr, import_df = FALSE, results = NULL, nolog = TRUE, timeout = cfg$timeout)
      }), cfg)
      out <- add_row(out, time_call(pkg, "roundtrip_numeric", "put_exec_get", n, r, command = "generate double sum_xy = x + y", expr = {
        z <- do_one(id, "generate double sum_xy = x + y", df = dnum, import_df = TRUE, results = NULL, nolog = TRUE, timeout = cfg$timeout)
        check_roundtrip_numeric(z, dnum)
      }), cfg)
      out <- add_row(out, time_call(pkg, "roundtrip_mixed", "put_exec_get", n, r, command = "generate double txt_len = length(txt)", expr = {
        z <- do_one(id, "generate double txt_len = length(txt)", df = dmix, import_df = TRUE, results = NULL, nolog = TRUE, timeout = cfg$timeout)
        check_roundtrip_mixed(z, dmix)
      }), cfg)
      out <- add_row(out, time_call(pkg, "stata_to_r_generated", "get_only", n, r, command = "clear\nset obs <n>\ngenerate double id = _n\ngenerate double z = sqrt(_n)\ngenerate str8 grp = cond(mod(_n, 2), \"odd\", \"even\")", expr = {
        code <- sprintf(paste("clear", "set obs %d", "generate double id = _n", "generate double z = sqrt(_n)", "generate str8 grp = cond(mod(_n, 2), \"odd\", \"even\")", sep = "\n"), n)
        z <- do_one(id, code, import_df = TRUE, results = NULL, nolog = TRUE, timeout = cfg$timeout)
        check_df(z, n, 3L)
      }), cfg)
    }
  }

  if (cfg$cluster_workers >= 2L) {
    # Avoid benchmarking n cluster workers while an extra main benchmark session
    # is still open.  This matters on installations with strict Stata process or
    # license limits, and makes cluster_startup timings easier to interpret.
    if (!is.null(id)) {
      stop_one(id, clear = TRUE)
      id <- NULL
      Sys.sleep(0.25)
    }
    cl <- NULL
    cluster_row <- time_call(pkg, "cluster_startup", paste0(cfg$cluster_workers, "_workers"), rep = 1L, expr = {
      cl <- call_supported(startStataCluster, list(n = cfg$cluster_workers, timeout = cfg$startup_timeout, start_cmd = stata_opt, verify = TRUE))
      if (!is.list(cl) || length(cl) < cfg$cluster_workers) stop("Cluster startup returned too few workers", call. = FALSE)
    })
    out <- add_row(out, cluster_row, cfg)
    if (isTRUE(cluster_row$ok)) {
      on.exit(try(call_supported(stopStataCluster, list(cl = cl, clear = TRUE)), silent = TRUE), add = TRUE)
      for (r in seq_len(cfg$reps)) {
        jobs_equal <- rep("sleep 250\ndisplay 1", cfg$cluster_workers * 4L)
        uneven_ms <- rep(c(900L, 75L, 450L, 75L, 300L, 75L), length.out = cfg$cluster_workers * 4L)
        jobs_uneven <- sprintf("sleep %d\ndisplay %d", uneven_ms, seq_along(uneven_ms))
        out <- add_row(out, time_call(pkg, "cluster_static_equal", paste0(cfg$cluster_workers, "_workers"), rep = r, expr = {
          z <- call_supported(doInStataCluster, list(cl = cl, X = jobs_equal, results = NULL, import_df = FALSE, nolog = TRUE, timeout = cfg$timeout))
          check_cluster_output(z, length(jobs_equal))
        }), cfg)
        out <- add_row(out, time_call(pkg, "cluster_static_uneven", paste0(cfg$cluster_workers, "_workers"), rep = r, expr = {
          z <- call_supported(doInStataCluster, list(cl = cl, X = jobs_uneven, results = NULL, import_df = FALSE, nolog = TRUE, timeout = cfg$timeout))
          check_cluster_output(z, length(jobs_uneven))
        }), cfg)
        out <- add_row(out, time_call(pkg, "cluster_lb_uneven", paste0(cfg$cluster_workers, "_workers"), rep = r, expr = {
          z <- call_supported(doInStataClusterLB, list(cl = cl, X = jobs_uneven, results = NULL, import_df = FALSE, nolog = TRUE, timeout = cfg$timeout))
          check_cluster_output(z, length(jobs_uneven))
        }), cfg)
      }
      stop_row <- time_call(pkg, "cluster_shutdown", paste0(cfg$cluster_workers, "_workers"), rep = 1L, expr = {
        call_supported(stopStataCluster, list(cl = cl, clear = TRUE))
        cl <- NULL
      })
      out <- add_row(out, stop_row, cfg)
    }
  }

  out
}

empty_summary <- function() {
  data.frame(
    package = character(), operation = character(), variant = character(), n = integer(), reps = integer(),
    median_sec = double(), mean_sec = double(), min_sec = double(), max_sec = double(),
    stringsAsFactors = FALSE
  )
}

empty_ratios <- function() {
  data.frame(
    operation = character(), variant = character(), n = integer(),
    rstatalink_median_sec = double(), rstatalink2_median_sec = double(), speedup_old_over_new = double(),
    stringsAsFactors = FALSE
  )
}

key_value <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- "<NA>"
  x
}


benchmark_ok <- function(x) {
  if (is.logical(x)) return(!is.na(x) & x)
  if (is.factor(x)) x <- as.character(x)
  tolower(trimws(as.character(x))) %in% c("true", "t", "1", "yes")
}

summarise_results <- function(raw) {
  ok <- raw[benchmark_ok(raw$ok), , drop = FALSE]
  if (!nrow(ok)) return(empty_summary())
  keys <- c("package", "operation", "variant", "n")
  key <- do.call(paste, c(lapply(ok[keys], key_value), sep = "\r"))
  pieces <- lapply(split(ok, key, drop = TRUE), function(z) {
    data.frame(
      package = z$package[[1L]], operation = z$operation[[1L]], variant = z$variant[[1L]], n = z$n[[1L]], reps = nrow(z),
      median_sec = median(z$elapsed_sec), mean_sec = mean(z$elapsed_sec), min_sec = min(z$elapsed_sec), max_sec = max(z$elapsed_sec),
      stringsAsFactors = FALSE
    )
  })
  pieces <- pieces[lengths(pieces) > 0L]
  if (!length(pieces)) return(empty_summary())
  out <- do.call(rbind, pieces)
  row.names(out) <- NULL
  out[order(out$operation, out$variant, out$n, out$package, na.last = TRUE), , drop = FALSE]
}

ratio_table <- function(summary) {
  if (!nrow(summary) || !all(c("RStataLink", "RStataLink2") %in% summary$package)) return(empty_ratios())
  key_cols <- c("operation", "variant", "n")
  key <- do.call(paste, c(lapply(summary[key_cols], key_value), sep = "\r"))
  pieces <- lapply(split(summary, key, drop = TRUE), function(z) {
    old <- z[z$package == "RStataLink", , drop = FALSE]
    new <- z[z$package == "RStataLink2", , drop = FALSE]
    if (!nrow(old) || !nrow(new)) return(NULL)
    data.frame(
      operation = new$operation[[1L]], variant = new$variant[[1L]], n = new$n[[1L]],
      rstatalink_median_sec = old$median_sec[[1L]], rstatalink2_median_sec = new$median_sec[[1L]],
      speedup_old_over_new = old$median_sec[[1L]] / new$median_sec[[1L]],
      stringsAsFactors = FALSE
    )
  })
  pieces <- pieces[!vapply(pieces, is.null, logical(1L))]
  if (!length(pieces)) return(empty_ratios())
  out <- do.call(rbind, pieces)
  row.names(out) <- NULL
  out[order(out$operation, out$variant, out$n, na.last = TRUE), , drop = FALSE]
}

write_metadata <- function(cfg, outdir) {
  cfg_df <- data.frame(name = names(cfg), value = vapply(cfg, function(x) paste(x, collapse = ","), character(1L)), stringsAsFactors = FALSE)
  write.csv(cfg_df, file.path(outdir, "rstatalink-benchmark-config.csv"), row.names = FALSE)
  writeLines(capture.output(sessionInfo()), file.path(outdir, "rstatalink-benchmark-session-info.txt"))
  pkg_info <- do.call(rbind, lapply(cfg$packages, function(pkg) {
    data.frame(
      package = pkg,
      installed = suppressWarnings(suppressPackageStartupMessages(requireNamespace(pkg, quietly = TRUE))),
      version = if (suppressWarnings(suppressPackageStartupMessages(requireNamespace(pkg, quietly = TRUE)))) as.character(utils::packageVersion(pkg)) else NA_character_,
      libpath = if (suppressWarnings(suppressPackageStartupMessages(requireNamespace(pkg, quietly = TRUE)))) dirname(system.file(package = pkg)) else NA_character_,
      stringsAsFactors = FALSE
    )
  }))
  write.csv(pkg_info, file.path(outdir, "rstatalink-benchmark-packages.csv"), row.names = FALSE)
}

zip_outputs <- function(outdir) {
  old <- setwd(dirname(outdir)); on.exit(setwd(old), add = TRUE)
  files <- list.files(basename(outdir), recursive = TRUE, full.names = TRUE)
  if (length(files) && nzchar(Sys.which("zip"))) {
    zipfile <- paste0(normalizePath(outdir, winslash = "/", mustWork = FALSE), ".zip")
    utils::zip(zipfile, files = files)
  } else if (length(files)) {
    zipfile <- paste0(normalizePath(outdir, winslash = "/", mustWork = FALSE), ".tar.gz")
    utils::tar(zipfile, files = basename(outdir), compression = "gzip", tar = "internal")
  } else {
    zipfile <- ""
  }
  zipfile
}

run_benchmark <- function(cfg = parse_args()) {
  set.seed(cfg$seed)
  cfg$out <- ensure_dir(cfg$out, "benchmark output directory")
  cat("Benchmark configuration:\n")
  print(cfg)
  if (is.na(cfg$stata) || !nzchar(cfg$stata)) {
    cat("\nStata executable not found. Re-run with --stata PATH or set STATA_BIN/RSTATALINK2_STATA.\n")
  } else {
    cat("\nUsing Stata executable:\n", cfg$stata, "\n", sep = "")
  }
  write_metadata(cfg, cfg$out)

  rows <- unlist(lapply(cfg$packages, run_package, cfg = cfg), recursive = FALSE)
  raw <- if (length(rows)) do.call(rbind, rows) else row_result("", "no_packages", ok = FALSE, error = "No packages selected")
  row.names(raw) <- NULL
  summary <- summarise_results(raw)
  ratios <- ratio_table(summary)
  errors <- raw[!benchmark_ok(raw$ok), , drop = FALSE]

  raw_file <- file.path(cfg$out, "rstatalink-benchmark-raw.csv")
  summary_file <- file.path(cfg$out, "rstatalink-benchmark-summary.csv")
  ratio_file <- file.path(cfg$out, "rstatalink-benchmark-ratios.csv")
  error_file <- file.path(cfg$out, "rstatalink-benchmark-errors.csv")
  write.csv(raw, raw_file, row.names = FALSE)
  write.csv(summary, summary_file, row.names = FALSE)
  write.csv(ratios, ratio_file, row.names = FALSE)
  write.csv(errors, error_file, row.names = FALSE)

  notes <- c(
    "RStataLink benchmark notes",
    "",
    "speedup_old_over_new = RStataLink median seconds / RStataLink2 median seconds.",
    "Values above 1 mean RStataLink2 was faster for that operation.",
    "Only successful runs are included in summary and ratio tables; failures are in rstatalink-benchmark-errors.csv.",
    "The raw and error CSVs include a command column for operations that sent Stata code.",
    "Round-trip benchmarks check returned numeric/string values, not only row and column counts.",
    "Cluster benchmarks check that the expected number of job results is returned and that no job returns a Stata error.",
    "For fair results, close unrelated heavy applications and use the same Stata executable for both packages.",
    "When --cluster-workers is at least 2, cluster_static_uneven uses fixed waves and cluster_lb_uneven dispatches the next job to the first worker that replies."
  )
  writeLines(notes, file.path(cfg$out, "rstatalink-benchmark-notes.txt"))

  cat("\nWrote:\n", raw_file, "\n", summary_file, "\n", ratio_file, "\n", error_file, "\n", sep = "")
  if (nrow(summary)) print(summary, row.names = FALSE)
  if (nrow(ratios)) print(ratios, row.names = FALSE)
  if (nrow(errors)) {
    cat("\nFailures were recorded in:\n", error_file, "\n", sep = "")
    print(errors[, intersect(c("package", "operation", "variant", "n", "rep", "error", "command"), names(errors)), drop = FALSE], row.names = FALSE)
  }
  zipfile <- ""
  if (isTRUE(cfg$make_zip)) {
    zipfile <- tryCatch(zip_outputs(cfg$out), error = function(e) "")
    if (nzchar(zipfile)) cat("\nZipped outputs:\n", zipfile, "\n", sep = "")
  }
  invisible(list(raw = raw, summary = summary, ratios = ratios, errors = errors, config = cfg, zipfile = zipfile))
}

if (sys.nframe() == 0L && !interactive()) {
  run_benchmark(parse_args())
}
