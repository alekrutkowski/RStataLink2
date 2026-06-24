args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2L) {
  stop("usage: fetch-nng.R <build-dir> <version-or-tag> [path-output-file]", call. = FALSE)
}

build_dir <- normalizePath(args[[1L]], winslash = "/", mustWork = FALSE)
version <- trimws(args[[2L]])
outfile <- if (length(args) >= 3L) args[[3L]] else ""
dir.create(build_dir, recursive = TRUE, showWarnings = FALSE)

msg <- function(...) message("RStataLink2: ", ...)

write_result <- function(path) {
  path <- normalizePath(path, winslash = "/", mustWork = TRUE)
  if (nzchar(outfile)) writeLines(path, outfile, useBytes = TRUE) else cat(path, "\n", sep = "")
  invisible(path)
}

looks_like_nng_source <- function(path) {
  dir.exists(path) &&
    file.exists(file.path(path, "CMakeLists.txt")) &&
    file.exists(file.path(path, "include", "nng", "nng.h"))
}

find_source_dir <- function(where) {
  candidates <- list.dirs(where, recursive = FALSE, full.names = TRUE)
  candidates <- candidates[vapply(candidates, looks_like_nng_source, logical(1L))]
  if (length(candidates)) normalizePath(candidates[[1L]], winslash = "/", mustWork = TRUE) else ""
}

source_dir <- Sys.getenv("RSTATALINK2_NNG_SOURCE_DIR", unset = "")
if (nzchar(source_dir)) {
  source_dir <- normalizePath(source_dir, winslash = "/", mustWork = TRUE)
  if (!looks_like_nng_source(source_dir)) {
    stop("RSTATALINK2_NNG_SOURCE_DIR does not look like an unpacked NNG source tree: ", source_dir,
         call. = FALSE)
  }
  write_result(source_dir)
  quit(status = 0L)
}

existing <- find_source_dir(build_dir)
if (nzchar(existing)) {
  write_result(existing)
  quit(status = 0L)
}

extract_archive <- function(archive) {
  before <- list.dirs(build_dir, recursive = FALSE, full.names = TRUE)
  utils::untar(archive, exdir = build_dir)
  after <- list.dirs(build_dir, recursive = FALSE, full.names = TRUE)
  src <- find_source_dir(build_dir)
  if (!nzchar(src)) {
    new_dirs <- setdiff(after, before)
    if (length(new_dirs)) {
      candidates <- new_dirs[vapply(new_dirs, looks_like_nng_source, logical(1L))]
      if (length(candidates)) src <- normalizePath(candidates[[1L]], winslash = "/", mustWork = TRUE)
    }
  }
  if (!nzchar(src)) stop("NNG source extraction failed", call. = FALSE)
  src
}

local_archive <- Sys.getenv("RSTATALINK2_NNG_ARCHIVE", unset = "")
if (nzchar(local_archive)) {
  local_archive <- normalizePath(local_archive, winslash = "/", mustWork = TRUE)
  msg("using local NNG archive: ", local_archive)
  write_result(extract_archive(local_archive))
  quit(status = 0L)
}

as_tag <- function(x) {
  x <- sub("^v", "", trimws(x))
  if (!nzchar(x)) x <- "1.11"
  paste0("v", x)
}
strip_patch_zero <- function(tag) sub("\\.0$", "", tag)
sanitize <- function(x) gsub("[^A-Za-z0-9._-]", "_", x)

explicit_url <- Sys.getenv("RSTATALINK2_NNG_URL", unset = "")
if (nzchar(explicit_url)) {
  urls <- explicit_url
  tags <- as_tag(version)
} else {
  requested <- as_tag(version)
  tag_candidates <- unique(c(
    requested,
    strip_patch_zero(requested),
    "v1.11",
    "v1.10.1",
    "v1.10",
    "v1.9.0"
  ))
  tag_candidates <- tag_candidates[nzchar(tag_candidates)]
  tags <- rep(tag_candidates, each = 2L)
  urls <- unlist(lapply(tag_candidates, function(tag) c(
    sprintf("https://github.com/nanomsg/nng/archive/refs/tags/%s.tar.gz", tag),
    sprintf("https://codeload.github.com/nanomsg/nng/tar.gz/refs/tags/%s", tag)
  )), use.names = FALSE)
}

success <- FALSE
last_error <- ""
source_dir <- ""

for (i in seq_along(urls)) {
  url <- urls[[i]]
  tag <- tags[[min(i, length(tags))]]
  archive <- file.path(build_dir, paste0("nng-", sanitize(tag), ".tar.gz"))

  if (!file.exists(archive)) {
    msg("downloading NNG source: ", url)
    ok <- tryCatch({
      status <- utils::download.file(url, destfile = archive, mode = "wb", quiet = FALSE)
      identical(status, 0L) || identical(status, 0) || file.exists(archive)
    }, warning = function(w) {
      last_error <<- conditionMessage(w)
      msg("download warning: ", last_error)
      FALSE
    }, error = function(e) {
      last_error <<- conditionMessage(e)
      msg("download failed: ", last_error)
      FALSE
    })
    if (!ok || !file.exists(archive) || file.info(archive)$size <= 0) {
      unlink(archive, force = TRUE)
      next
    }
  } else {
    msg("using cached NNG archive: ", archive)
  }

  msg("extracting NNG archive")
  ok <- tryCatch({
    source_dir <- extract_archive(archive)
    TRUE
  }, error = function(e) {
    last_error <<- conditionMessage(e)
    msg("extraction failed: ", last_error)
    FALSE
  })
  if (ok && nzchar(source_dir)) {
    success <- TRUE
    break
  }
}

if (!success) {
  stop(
    "Could not obtain NNG source. Install libnng development files, set NNG_PREFIX, ",
    "set RSTATALINK2_NNG_SOURCE_DIR/RSTATALINK2_NNG_ARCHIVE, or set RSTATALINK2_NNG_URL ",
    "to a reachable NNG source tarball. Last download error: ", last_error,
    call. = FALSE
  )
}

write_result(source_dir)
