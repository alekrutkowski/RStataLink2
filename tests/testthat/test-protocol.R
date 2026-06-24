test_that("message pack/unpack roundtrip works", {
  msg <- RStataLink2:::.rslng_pack("EXEC", "display 1", as.raw(1:3))
  out <- RStataLink2:::.rslng_unpack(msg)
  expect_identical(out$kind, "EXEC")
  expect_identical(out$text, "display 1")
  expect_identical(out$payload, as.raw(1:3))
})

test_that("uint32 codec does not use warning-prone readBin signed = FALSE", {
  z <- RStataLink2:::.rslng_u32(102L)
  expect_warning(out <- RStataLink2:::.rslng_read_u32(z, 1L), NA)
  expect_identical(out, 102L)
})

test_that("data-frame codec roundtrip works", {
  x <- data.frame(a = c(1, NA, 3), b = c("x", NA, "z"), stringsAsFactors = FALSE)
  raw <- RStataLink2:::.rslng_encode_df(x)
  y <- RStataLink2:::.rslng_decode_df(raw)
  expect_equal(y$a, x$a)
  expect_equal(y$b, x$b)
})

test_that("code-only doInStata call can be resolved against active StataID", {
  fake <- structure("tcp://127.0.0.1:1", names = "abc", class = "StataID")
  old <- options(RStataLink2.active_id = fake)
  on.exit(options(old), add = TRUE)
  resolved <- RStataLink2:::.rsl2_resolve_id_code("display 1", "")
  expect_identical(resolved$id, fake)
  expect_identical(resolved$code, "display 1")
})

test_that("data-frame codec uses DF02 and remains DF01-compatible", {
  x <- data.frame(a = 1:2, b = c("aa", "bbb"), stringsAsFactors = FALSE)
  raw <- RStataLink2:::.rslng_encode_df(x)
  expect_identical(raw[1:4], charToRaw("DF02"))
  raw_v1 <- raw
  raw_v1[1:4] <- charToRaw("DF01")
  # Remove the width field from each metadata record to emulate the original format.
  # Two columns: type,width,namelen,name -> type,namelen,name.
  pos <- 13L
  out <- raw_v1[1:12]
  for (i in seq_len(2L)) {
    type <- raw_v1[pos:(pos + 3L)]; pos <- pos + 4L
    pos <- pos + 4L
    namelen <- RStataLink2:::.rslng_read_u32(raw_v1, pos)
    name <- raw_v1[pos:(pos + 3L + namelen)]
    out <- c(out, type, name)
    pos <- pos + 4L + namelen
  }
  out <- c(out, raw_v1[pos:length(raw_v1)])
  y <- RStataLink2:::.rslng_decode_df(out)
  expect_equal(y$a, as.numeric(x$a))
  expect_equal(y$b, x$b)
})

test_that("EXEC no-log/no-snapshot message kinds are known", {
  for (kind in c("EXEC_NOLOG", "EXEC_NOSNAP", "EXEC_NOLOG_NOSNAP")) {
    msg <- RStataLink2:::.rslng_pack(kind, "display 1")
    out <- RStataLink2:::.rslng_unpack(msg)
    expect_identical(out$kind, kind)
  }
})

test_that("Stata logs are cleaned before returning to R", {
  raw_log <- paste(
    "---------------------------------------------------------------------",
    "      name:  __000000",
    "       log:  C:/Temp/ST_000001.tmp",
    "  log type:  text",
    " opened on:  24 Jun 2026, 09:53:02",
    "7",
    sep = "\n"
  )
  out <- RStataLink2:::.rsl2_clean_exec_log(raw_log, "display 3 + 4")
  expect_identical(out, ". display 3 + 4\n7")
})
