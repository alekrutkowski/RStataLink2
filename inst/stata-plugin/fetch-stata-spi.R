args <- commandArgs(trailingOnly = TRUE)
target <- if (length(args)) args[[1L]] else "."
dir.create(target, recursive = TRUE, showWarnings = FALSE)

needed <- c("stplugin.c", "stplugin.h")
existing <- file.path(target, needed)
if (all(file.exists(existing))) {
  message("Stata plugin interface files already present.")
  quit(status = 0L)
}

spi_dir <- Sys.getenv("RSTATALINK2_SPI_DIR", unset = "")
if (nzchar(spi_dir)) {
  src <- file.path(spi_dir, needed)
  if (!all(file.exists(src))) {
    stop("RSTATALINK2_SPI_DIR is set, but stplugin.c/stplugin.h were not both found in: ", spi_dir,
         call. = FALSE)
  }
  file.copy(src, target, overwrite = TRUE)
  message("Copied Stata plugin interface files from RSTATALINK2_SPI_DIR.")
  quit(status = 0L)
}

urls <- c(
  "stplugin.c" = "https://www.stata.com/plugins/stplugin.c",
  "stplugin.h" = "https://www.stata.com/plugins/stplugin.h"
)

for (nm in names(urls)) {
  dest <- file.path(target, nm)
  if (file.exists(dest)) next
  message("Downloading ", urls[[nm]], " -> ", dest)
  ok <- tryCatch({
    utils::download.file(urls[[nm]], destfile = dest, mode = "wb", quiet = FALSE)
    TRUE
  }, error = function(e) {
    message("Download failed: ", conditionMessage(e))
    FALSE
  })
  if (!ok || !file.exists(dest)) {
    stop(
      "Could not obtain ", nm, ". Either allow access to https://www.stata.com/plugins/ ",
      "during source installation or set RSTATALINK2_SPI_DIR to a directory containing ",
      "stplugin.c and stplugin.h.",
      call. = FALSE
    )
  }
}
