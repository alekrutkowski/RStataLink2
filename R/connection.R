# Low-level NNG client helpers. These are intentionally not exported; the
# public surface is the RStataLink-compatible API in compatibility.R.

rslng_default_endpoint <- function(port = 5759L, compath = tempdir(), id = NULL) {
  port <- as.integer(port)[1L]
  if (.Platform$OS.type == "windows") {
    sprintf("tcp://127.0.0.1:%d", port)
  } else {
    if (is.null(id) || !nzchar(id)) id <- sprintf("%s", Sys.getpid())
    path <- file.path(compath, sprintf("rstatalink2-%s.sock", id))
    paste0("ipc://", normalizePath(dirname(path), mustWork = FALSE), "/", basename(path))
  }
}

rslng_connect <- function(endpoint = rslng_default_endpoint(), timeout = 60000L, dial = TRUE,
                          protocol = getOption("RStataLink2.nng_protocol", "pair")) {
  timeout <- as.integer(timeout)[1L]
  protocol <- tolower(as.character(protocol)[1L])
  if (!protocol %in% c("pair", "req")) {
    stop("protocol must be 'pair' or 'req'", call. = FALSE)
  }
  sock <- if (isTRUE(dial)) {
    nanonext::socket(protocol, dial = endpoint)
  } else {
    nanonext::socket(protocol, listen = endpoint)
  }
  sock <- nanonext::`opt<-`(sock, "send-timeout", value = timeout)
  sock <- nanonext::`opt<-`(sock, "recv-timeout", value = timeout)
  structure(list(socket = sock, endpoint = endpoint, timeout = timeout, protocol = protocol), class = "rslng_connection")
}

print.rslng_connection <- function(x, ...) {
  cat("<RStataLink2 internal connection>\n")
  cat("  endpoint: ", x$endpoint, "\n", sep = "")
  cat("  timeout:  ", x$timeout, " ms\n", sep = "")
  cat("  protocol: ", x$protocol %||% "pair", "\n", sep = "")
  invisible(x)
}

.rslng_timeout_ms <- function(timeout, default = 60000L) {
  if (missing(timeout) || length(timeout) == 0L || is.null(timeout)) return(as.integer(default))
  timeout <- as.numeric(timeout)[1L]
  if (is.na(timeout)) stop("timeout must be numeric", call. = FALSE)
  if (is.infinite(timeout)) return(as.integer(.Machine$integer.max))
  if (timeout < 0) stop("timeout must be non-negative", call. = FALSE)
  as.integer(min(.Machine$integer.max, ceiling(timeout)))
}

.rslng_send_request <- function(con, kind, text = "", payload = raw(), timeout = con$timeout) {
  if (!inherits(con, "rslng_connection")) stop("not an rslng_connection", call. = FALSE)
  msg <- .rslng_pack(kind, text = text, payload = payload)
  rc <- nanonext::send(con$socket, msg, mode = "raw", block = .rslng_timeout_ms(timeout, con$timeout))
  if (!identical(as.integer(rc), 0L)) {
    stop("NNG send failed: ", nanonext::nng_error(rc), call. = FALSE)
  }
  invisible(list(kind = kind, text = text, payload_len = length(payload)))
}

.rslng_recv_response <- function(con, timeout = con$timeout) {
  if (!inherits(con, "rslng_connection")) stop("not an rslng_connection", call. = FALSE)
  ans <- nanonext::recv(con$socket, mode = "raw", block = .rslng_timeout_ms(timeout, con$timeout))
  if (is.raw(ans)) {
    return(.rslng_unpack(ans))
  }
  if (isTRUE(tryCatch(nanonext::is_error_value(ans), error = function(e) FALSE))) {
    msg <- tryCatch(nanonext::nng_error(ans), error = function(e) "unknown NNG error")
    stop("NNG receive failed: ", msg, call. = FALSE)
  }
  stop("NNG receive did not return a raw message", call. = FALSE)
}

.rslng_try_recv_response <- function(con) {
  if (!inherits(con, "rslng_connection")) stop("not an rslng_connection", call. = FALSE)
  ans <- nanonext::recv(con$socket, mode = "raw", block = FALSE)
  if (is.raw(ans)) {
    return(.rslng_unpack(ans))
  }
  if (isTRUE(tryCatch(nanonext::is_error_value(ans), error = function(e) FALSE))) {
    msg <- tryCatch(nanonext::nng_error(ans), error = function(e) "unknown NNG error")
    # With block = FALSE, "no message yet" is expected while a worker is busy.
    # Treat common non-ready/timeout cases as an empty poll, but surface other
    # socket failures to callers.
    if (grepl("timed out|try again|again|would block|no message|not ready|resource temporarily unavailable",
              msg, ignore.case = TRUE)) {
      return(NULL)
    }
    return(structure(list(message = msg), class = "rslng_recv_error"))
  }
  NULL
}

.rslng_request <- function(con, kind, text = "", payload = raw(), timeout = con$timeout) {
  .rslng_send_request(con, kind, text = text, payload = payload, timeout = timeout)
  .rslng_recv_response(con, timeout = timeout)
}

.rslng_check_ok <- function(ans, context = "request") {
  if (!identical(ans$kind, "OK")) {
    stop(context, " failed: ", ans$text, call. = FALSE)
  }
  invisible(ans)
}

rslng_ping <- function(con, timeout = con$timeout) {
  ans <- .rslng_request(con, "PING", timeout = timeout)
  .rslng_check_ok(ans, "ping")
  invisible(ans$text)
}

rslng_exec <- function(con, code, error = TRUE, timeout = con$timeout) {
  code <- paste(enc2utf8(code), collapse = "\n")
  ans <- .rslng_request(con, "EXEC", text = code, timeout = timeout)
  out <- list(ok = identical(ans$kind, "OK"), kind = ans$kind, text = ans$text)
  if (isTRUE(error) && !out$ok) stop("Stata execution failed: ", ans$text, call. = FALSE)
  out
}

rslng_put_df <- function(con, x, timeout = con$timeout) {
  payload <- .rslng_encode_df(x)
  ans <- .rslng_request(con, "PUT_DF", payload = payload, timeout = timeout)
  .rslng_check_ok(ans, "put_df")
}

rslng_get_df <- function(con, varlist = "_all", timeout = con$timeout) {
  ans <- .rslng_request(con, "GET_DF", text = paste(varlist, collapse = " "), timeout = timeout)
  if (!identical(ans$kind, "DATA")) {
    stop("get_df failed: ", ans$text, call. = FALSE)
  }
  .rslng_decode_df(ans$payload)
}

rslng_stop <- function(con, close = TRUE, timeout = con$timeout) {
  ans <- .rslng_request(con, "STOP", timeout = timeout)
  if (isTRUE(close)) rslng_close(con)
  invisible(ans)
}

rslng_close <- function(con) {
  if (inherits(con, "rslng_connection")) close(con$socket)
  invisible(NULL)
}
