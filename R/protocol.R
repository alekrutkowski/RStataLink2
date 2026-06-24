.rslng_magic <- as.raw(c(charToRaw("RSLNG01"), 0L))
.rslng_df_magic <- charToRaw("DF02")
.rslng_df_magic_v1 <- charToRaw("DF01")
.rslng_na_strlen <- 2147483647L

.rslng_kind_codes <- c(
  PING = 1L,
  EXEC = 2L,
  PUT_DF = 3L,
  GET_DF = 4L,
  STOP = 5L,
  GET_RESULTS = 6L,
  EXEC_NOLOG = 7L,
  EXEC_NOSNAP = 8L,
  EXEC_NOLOG_NOSNAP = 9L,
  OK = 100L,
  ERR = 101L,
  DATA = 102L,
  TIMEOUT = 103L
)
.rslng_code_kinds <- stats::setNames(names(.rslng_kind_codes), .rslng_kind_codes)

.rslng_u32 <- function(x) {
  if (length(x) != 1L || is.na(x) || x < 0 || x > .Machine$integer.max) {
    stop("value cannot be encoded as uint32 in this prototype", call. = FALSE)
  }
  writeBin(as.integer(x), raw(), size = 4L, endian = "little")
}

.rslng_read_u32 <- function(x, pos) {
  stopifnot(is.raw(x), length(pos) == 1L)
  pos <- as.integer(pos)[1L]
  if (is.na(pos) || pos < 1L || pos + 3L > length(x)) {
    stop("truncated uint32", call. = FALSE)
  }
  b <- as.integer(x[pos:(pos + 3L)])
  out <- b[[1L]] + 256 * b[[2L]] + 65536 * b[[3L]] + 16777216 * b[[4L]]
  if (out > .Machine$integer.max) {
    stop("uint32 value exceeds RStataLink2 prototype integer range", call. = FALSE)
  }
  as.integer(out)
}

.rslng_kind_code <- function(kind) {
  if (is.numeric(kind)) return(as.integer(kind))
  kind <- toupper(as.character(kind)[1L])
  out <- .rslng_kind_codes[[kind]]
  if (is.null(out)) stop("unknown RStataLink2 message kind: ", kind, call. = FALSE)
  as.integer(out)
}

.rslng_kind_name <- function(code) {
  out <- .rslng_code_kinds[[as.character(as.integer(code))]]
  if (is.null(out)) paste0("UNKNOWN_", code) else out
}

.rslng_pack <- function(kind, text = "", payload = raw()) {
  stopifnot(is.raw(payload))
  text <- enc2utf8(paste(text, collapse = "\n"))
  text_raw <- charToRaw(text)
  if (length(text_raw) > .Machine$integer.max || length(payload) > .Machine$integer.max) {
    stop("messages above 2 GB are not supported in this prototype", call. = FALSE)
  }
  c(
    .rslng_magic,
    .rslng_u32(.rslng_kind_code(kind)),
    .rslng_u32(length(text_raw)),
    .rslng_u32(length(payload)),
    .rslng_u32(0L),
    text_raw,
    payload
  )
}

.rslng_unpack <- function(x) {
  if (!is.raw(x)) stop("received message is not raw", call. = FALSE)
  if (length(x) < 24L) stop("truncated RStataLink2 message", call. = FALSE)
  if (!identical(x[1:8], .rslng_magic)) stop("bad RStataLink2 message magic", call. = FALSE)
  kind_code <- .rslng_read_u32(x, 9L)
  text_len <- .rslng_read_u32(x, 13L)
  payload_len <- .rslng_read_u32(x, 17L)
  start_text <- 25L
  end_text <- start_text + text_len - 1L
  start_payload <- start_text + text_len
  end_payload <- start_payload + payload_len - 1L
  if (end_payload > length(x)) stop("truncated RStataLink2 message body", call. = FALSE)
  text <- if (text_len) rawToChar(x[start_text:end_text]) else ""
  payload <- if (payload_len) x[start_payload:end_payload] else raw()
  list(kind = .rslng_kind_name(kind_code), kind_code = kind_code, text = text, payload = payload)
}
