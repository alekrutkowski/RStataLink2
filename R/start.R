.rslng_stata_quote <- function(x) {
  x <- enc2utf8(as.character(x)[1L])
  paste0("\"", gsub("\"", "\\\"", x, fixed = TRUE), "\"")
}

.rsl2_unquote_path <- function(x) {
  if (length(x) == 0L || is.na(x[[1L]])) return(NA_character_)
  x <- trimws(as.character(x)[1L])
  if (!nzchar(x)) return(x)
  if ((startsWith(x, '"') && endsWith(x, '"')) ||
      (startsWith(x, "'") && endsWith(x, "'"))) {
    x <- substr(x, 2L, nchar(x) - 1L)
  }
  x
}

.rsl2_normalize_path_arg <- function(x) {
  x <- .rsl2_unquote_path(x)
  if (file.exists(x)) normalizePath(x, winslash = "/", mustWork = FALSE) else x
}

.rsl2_plugin_dir <- function(mustWork = TRUE) {
  system.file("stata-plugin", package = "RStataLink2", mustWork = mustWork)
}

.rsl2_plugin_file <- function(mustWork = TRUE) {
  f <- system.file("stata-plugin", "rslng__plugin.plugin", package = "RStataLink2", mustWork = FALSE)
  if (mustWork && (!nzchar(f) || !file.exists(f))) {
    stop(
      "The compiled Stata plugin was not found in the installed RStataLink2 package. ",
      "Reinstall RStataLink2 from source with Rtools/build tools available, or install ",
      "a binary build that already contains stata-plugin/rslng__plugin.plugin.",
      call. = FALSE
    )
  }
  f
}

.rsl2_check_plugin_installed <- function() {
  invisible(.rsl2_plugin_file(mustWork = TRUE))
}

.rsl2_first_existing <- function(x) {
  x <- unique(x[!is.na(x) & nzchar(x)])
  x <- x[file.exists(x)]
  if (length(x)) normalizePath(x[[1L]], winslash = "/", mustWork = FALSE) else NA_character_
}

.rslng_find_stata <- function() {
  opts <- c(getOption("statapath"), getOption("RStataLink2.stata"))
  opts <- opts[!vapply(opts, is.null, logical(1L))]
  for (opt in opts) {
    if (length(opt) == 1L && !is.na(opt) && nzchar(opt)) {
      opt <- .rsl2_normalize_path_arg(opt)
      if (file.exists(opt)) return(opt)
      return(opt)
    }
  }

  env_names <- c("STATA_BIN", "RSTATAPATH", "STATAPATH", "RSTATALINK2_STATA", "RSTATALINK_STATA")
  env <- Sys.getenv(env_names, unset = "")
  env <- env[nzchar(env)]
  for (v in env) {
    v <- .rsl2_normalize_path_arg(v)
    if (file.exists(v)) return(v)
  }

  candidates <- if (.Platform$OS.type == "windows") {
    c("StataMP-64.exe", "StataSE-64.exe", "StataBE-64.exe", "StataNowMP-64.exe", "StataNowSE-64.exe", "StataNowBE-64.exe", "Stata-64.exe")
  } else {
    c("stata-mp", "stata-se", "stata-be", "stata", "xstata-mp", "xstata-se", "xstata-be", "xstata")
  }
  hit <- Sys.which(candidates)
  hit <- unname(hit[nzchar(hit)][1L])
  if (length(hit) && !is.na(hit) && nzchar(hit)) return(normalizePath(hit, winslash = "/", mustWork = FALSE))

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
    hit <- .rsl2_first_existing(unlist(lapply(pats, Sys.glob), use.names = FALSE))
    if (!is.na(hit) && nzchar(hit)) return(hit)

    roots <- c(
      "C:/ProgramData/Microsoft/AppV/Client/Integration",
      "C:/ProgramData/AppV"
    )
    found <- unlist(lapply(roots[dir.exists(roots)], function(root) {
      list.files(root, pattern = "^Stata.*-64[.]exe$", recursive = TRUE, full.names = TRUE, ignore.case = TRUE)
    }), use.names = FALSE)
    hit <- .rsl2_first_existing(found)
    if (!is.na(hit) && nzchar(hit)) return(hit)
  } else if (Sys.info()[["sysname"]] == "Darwin") {
    pats <- c(
      "/Applications/Stata*/StataMP.app/Contents/MacOS/StataMP",
      "/Applications/Stata*/StataSE.app/Contents/MacOS/StataSE",
      "/Applications/Stata*/StataBE.app/Contents/MacOS/StataBE",
      "/Applications/Stata*/Stata.app/Contents/MacOS/Stata"
    )
    hit <- .rsl2_first_existing(unlist(lapply(pats, Sys.glob), use.names = FALSE))
    if (!is.na(hit) && nzchar(hit)) return(hit)
  }

  NA_character_
}

#' Copy Stata ado and plugin files to an ado directory
#'
#' @param dir Destination directory. A personal ado directory is typical.
#' @param plugin Optional path to a compiled `rslng__plugin.plugin`. Defaults
#'   to the plugin installed inside this R package.
#' @param overwrite Overwrite existing files.
#' @return Destination directory, invisibly.
rslng_install_stata_files <- function(dir, plugin = NULL, overwrite = TRUE) {
  if (missing(dir) || !nzchar(dir)) stop("provide a destination directory", call. = FALSE)
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  ado <- system.file("stata", "rslng.ado", package = "RStataLink2", mustWork = TRUE)
  ok <- file.copy(ado, file.path(dir, "rslng.ado"), overwrite = overwrite)
  if (!ok) stop("could not copy rslng.ado", call. = FALSE)
  if (is.null(plugin)) plugin <- .rsl2_plugin_file(mustWork = TRUE)
  if (!file.exists(plugin)) stop("compiled plugin not found: ", plugin, call. = FALSE)
  ok <- file.copy(plugin, file.path(dir, "rslng__plugin.plugin"), overwrite = overwrite)
  if (!ok) stop("could not copy compiled plugin", call. = FALSE)

  plugin_dir <- dirname(plugin)
  dlls <- list.files(plugin_dir, pattern = "\\.dll$", full.names = TRUE, ignore.case = TRUE)
  if (length(dlls)) {
    file.copy(dlls, dir, overwrite = overwrite)
  }
  invisible(normalizePath(dir, mustWork = FALSE))
}

#' Start Stata in batch mode with an RStataLink2 server
#'
#' This writes a tiny bootstrap do-file and starts Stata in batch mode. For
#' interactive development, starting Stata manually and running
#' `rslng server, endpoint(...)` is often easier.
#'
#' @param stata Path to the Stata executable. Defaults to option
#'   `statapath`, option `RStataLink2.stata`, environment variable `STATA_BIN`,
#'   then common names on `PATH`.
#' @param endpoint NNG endpoint URL.
#' @param ado_dir Optional directory to prepend to Stata's ado-path.
#' @param wait Passed to [system2()]. Use `FALSE` to keep R responsive.
#' @return The bootstrap do-file path, invisibly.
rslng_start_stata <- function(stata = .rslng_find_stata(), endpoint = rslng_default_endpoint(),
                              ado_dir = NULL, wait = FALSE) {
  if (is.na(stata) || !nzchar(stata)) {
    stop("Stata executable not found. Set STATA_BIN, option statapath, or option RStataLink2.stata.", call. = FALSE)
  }
  .rsl2_check_plugin_installed()
  dofile <- tempfile("rslng-start-", fileext = ".do")
  plugin_dir <- .rsl2_plugin_dir(mustWork = TRUE)
  lines <- c(
    "version 16",
    if (!is.null(ado_dir)) sprintf("adopath ++ %s", .rslng_stata_quote(normalizePath(ado_dir, winslash = "/", mustWork = FALSE))) else NULL,
    sprintf("adopath ++ %s", .rslng_stata_quote(normalizePath(system.file("stata", package = "RStataLink2", mustWork = TRUE), winslash = "/", mustWork = FALSE))),
    sprintf("adopath ++ %s", .rslng_stata_quote(normalizePath(plugin_dir, winslash = "/", mustWork = FALSE))),
    'local __rsl2_oldpwd "`c(pwd)\'"',
    sprintf("capture noisily cd %s", .rslng_stata_quote(normalizePath(plugin_dir, winslash = "/", mustWork = FALSE))),
    "capture noisily rslng plugincheck",
    "local __rsl2_plugin_rc = _rc",
    'capture noisily cd "`__rsl2_oldpwd\'"',
    "if `__rsl2_plugin_rc' {",
    '    di as err "RStataLink2 plugincheck failed, rc=`__rsl2_plugin_rc\'"',
    "    exit `__rsl2_plugin_rc'",
    "}",
    sprintf("rslng server, endpoint(%s) exitstata", .rslng_stata_quote(endpoint)),
    "exit, STATA clear"
  )
  writeLines(lines, dofile, useBytes = TRUE)
  args <- c("do", normalizePath(dofile, winslash = "\\", mustWork = FALSE))
  system2(.rsl2_normalize_path_arg(stata), args = args, wait = wait)
  invisible(dofile)
}
