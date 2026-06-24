.rslng_make_stata_names <- function(x) {
  x <- enc2utf8(as.character(x))
  x[is.na(x) | !nzchar(x)] <- "v"
  x <- gsub("[^A-Za-z0-9_]", "_", x, perl = TRUE)
  x <- ifelse(grepl("^[A-Za-z_]", x), x, paste0("v_", x))
  x <- substr(x, 1L, 28L)
  x <- make.unique(x, sep = "_")
  substr(x, 1L, 32L)
}

.rslng_col_type <- function(x) {
  if (is.factor(x) || is.character(x)) return(2L)
  if (is.logical(x) || is.integer(x) || is.numeric(x)) return(1L)
  if (inherits(x, c("Date", "POSIXct", "POSIXlt"))) return(1L)
  stop("unsupported column type: ", paste(class(x), collapse = "/"), call. = FALSE)
}

.rslng_string_prepare <- function(x) {
  x <- enc2utf8(as.character(x))
  is_na <- is.na(x)
  len <- nchar(x, type = "bytes", allowNA = TRUE, keepNA = TRUE)
  len[is_na] <- 0L
  len[!is_na & is.na(len)] <- 0L
  len <- as.integer(pmin(len, 2045L))
  width <- if (length(len)) max(len[!is_na], 1L, na.rm = TRUE) else 1L
  if (!is.finite(width) || is.na(width) || width < 1L) width <- 1L
  list(x = x, is_na = is_na, len = len, width = as.integer(min(width, 2045L)))
}

.rslng_string_raw_prepared <- function(prep) {
  n <- length(prep$x)
  total <- 4 * n + sum(prep$len[!prep$is_na])
  if (total > .Machine$integer.max) stop("string column exceeds 2 GB prototype limit", call. = FALSE)
  out <- raw(as.integer(total))
  pos <- 1L
  for (i in seq_len(n)) {
    if (isTRUE(prep$is_na[[i]])) {
      out[pos:(pos + 3L)] <- .rslng_u32(.rslng_na_strlen)
      pos <- pos + 4L
    } else {
      bytes <- charToRaw(prep$x[[i]])
      if (length(bytes) > 2045L) bytes <- bytes[seq_len(2045L)]
      nb <- length(bytes)
      out[pos:(pos + 3L)] <- .rslng_u32(nb)
      pos <- pos + 4L
      if (nb) {
        out[pos:(pos + nb - 1L)] <- bytes
        pos <- pos + nb
      }
    }
  }
  out
}

.rslng_string_raw <- function(x) .rslng_string_raw_prepared(.rslng_string_prepare(x))


.rslng_encode_df <- function(x) {
  x <- as.data.frame(x, stringsAsFactors = FALSE, optional = TRUE)
  names(x) <- .rslng_make_stata_names(names(x))
  nr <- nrow(x)
  nc <- ncol(x)
  types <- vapply(x, .rslng_col_type, integer(1L))

  string_prepared <- vector("list", nc)
  widths <- integer(nc)
  for (i in seq_len(nc)) {
    if (types[[i]] == 2L) {
      string_prepared[[i]] <- .rslng_string_prepare(x[[i]])
      widths[[i]] <- string_prepared[[i]]$width
    }
  }

  meta <- unlist(lapply(seq_len(nc), function(i) {
    nm <- charToRaw(enc2utf8(names(x)[[i]]))
    c(.rslng_u32(types[[i]]), .rslng_u32(widths[[i]]), .rslng_u32(length(nm)), nm)
  }), recursive = FALSE, use.names = FALSE)

  body <- unlist(lapply(seq_len(nc), function(i) {
    col <- x[[i]]
    if (types[[i]] == 1L) {
      if (inherits(col, "Date")) col <- unclass(col)
      if (inherits(col, "POSIXt")) col <- as.numeric(col)
      col <- as.numeric(col)
      col[is.na(col)] <- NaN
      writeBin(col, raw(), size = 8L, endian = "little")
    } else {
      .rslng_string_raw_prepared(string_prepared[[i]])
    }
  }), recursive = FALSE, use.names = FALSE)

  c(.rslng_df_magic, .rslng_u32(nr), .rslng_u32(nc), meta, body)
}


.rslng_decode_df <- function(x) {
  stopifnot(is.raw(x))
  if (length(x) < 12L || (!identical(x[1:4], .rslng_df_magic) && !identical(x[1:4], .rslng_df_magic_v1))) {
    stop("bad RStataLink2 data-frame payload", call. = FALSE)
  }
  has_widths <- identical(x[1:4], .rslng_df_magic)
  nr <- .rslng_read_u32(x, 5L)
  nc <- .rslng_read_u32(x, 9L)
  pos <- 13L
  types <- integer(nc)
  names <- character(nc)
  for (i in seq_len(nc)) {
    types[[i]] <- .rslng_read_u32(x, pos); pos <- pos + 4L
    if (isTRUE(has_widths)) pos <- pos + 4L
    len <- .rslng_read_u32(x, pos); pos <- pos + 4L
    names[[i]] <- if (len) rawToChar(x[pos:(pos + len - 1L)]) else paste0("v", i)
    pos <- pos + len
  }
  cols <- vector("list", nc)
  for (i in seq_len(nc)) {
    if (types[[i]] == 1L) {
      nbytes <- nr * 8L
      vals <- if (nr) readBin(x[pos:(pos + nbytes - 1L)], "double", n = nr,
                              size = 8L, endian = "little") else numeric()
      vals[is.nan(vals)] <- NA_real_
      cols[[i]] <- vals
      pos <- pos + nbytes
    } else if (types[[i]] == 2L) {
      vals <- character(nr)
      for (j in seq_len(nr)) {
        len <- .rslng_read_u32(x, pos); pos <- pos + 4L
        if (identical(as.integer(len), .rslng_na_strlen)) {
          vals[[j]] <- NA_character_
        } else if (len == 0L) {
          vals[[j]] <- ""
        } else {
          vals[[j]] <- rawToChar(x[pos:(pos + len - 1L)])
          pos <- pos + len
        }
      }
      cols[[i]] <- vals
    } else {
      stop("unknown column type in RStataLink2 payload: ", types[[i]], call. = FALSE)
    }
  }
  stats::setNames(as.data.frame(cols, stringsAsFactors = FALSE, check.names = FALSE), names)
}
