# RStataLink2

**`RStataLink2` is an experimental successor to [`RStataLink`](https://github.com/alekrutkowski/RStataLink): an [R](https://www.r-project.org/) package for calling [Stata](https://www.stata.com/) from R interactively, but efficiently.** It keeps the same exported R function names, but replaces the disk-polling internals with a persistent Stata server, an [NNG](https://nng.nanomsg.org/) socket connection, and a [Stata C plugin](https://www.stata.com/plugins/).

> [!TIP]
> For the reverse usage, Stata calling R interactively and efficiently, see https://github.com/alekrutkowski/StataRLink and https://github.com/alekrutkowski/stata-rbridge

The public API is intentionally familiar:

```r
startStata()
stopStata()
isStataReady()
doInStata()
getStataFuture()
deleteStataFuture()
startStataCluster()
stopStataCluster()
doInStataCluster()
doInStataClusterLB()
```

## What is different from RStataLink?

`RStataLink2` keeps Stata alive as a server, but R and Stata communicate through `nanonext`/NNG rather than through repeated file polling. Numeric-heavy data frames use a compact binary column protocol. Large string-heavy transfers can use a hybrid temporary `.dta` path when that is faster or safer.

The package is still experimental, but has gone through basic tests and seems to work. The current focus is fast control messages, fast numeric data exchange, clean logs, basic `r()`/`e()` result extraction, futures, and multi-Stata cluster scheduling.

## Installation

### Install/compile from source:

```r
# Requires Rtools on Windows:
remotes::install_github("alekrutkowski/RStataLink2")
```

Source installation builds the Stata plugin automatically. During installation, `configure` or `configure.win`:

1. obtains StataCorp's `stplugin.c` and `stplugin.h`, unless they are already present;
2. finds NNG through `pkg-config`, `NNG_PREFIX`, or common system prefixes;
3. otherwise builds bundled NNG with `cmake`;
4. compiles `inst/stata-plugin/rslng_plugin.c` into `rslng__plugin.plugin`;
5. installs the ado file and compiled plugin under the installed R package directory.

### Install the compiled Windows (x86_64) package:

- Go to https://github.com/alekrutkowski/RStataLink2/releases
- Download `RStataLink2_0.0.16.9000.zip`
- run in R `install.packages(file.choose(), repos=NULL)` and selecte the just downloaded file.

Binary package installation does not compile anything so it doesn't need Rtools on Windows.

A binary package already contains:

```text
stata/rslng.ado
stata-plugin/rslng__plugin.plugin
```

At runtime, `startStata()` adds both installed directories to Stata's `adopath`, so Stata can find the ado file and plugin.

## Build requirements

### Windows 11

Use Rtools for source installation. If NNG is already available in MSYS2 UCRT64, this is often enough:

```sh
set NNG_PREFIX=/ucrt64
```

Useful optional environment variables:

```sh
set RSTATALINK2_SPI_DIR=C:/path/with/stplugin-files
set NNG_PREFIX=/ucrt64
set RSTATALINK2_NNG_VERSION=1.11
set RSTATALINK2_NNG_URL=https://github.com/nanomsg/nng/archive/refs/tags/v1.11.tar.gz
set RSTATALINK2_NNG_ARCHIVE=C:/path/to/nng-1.11.tar.gz
set RSTATALINK2_NNG_SOURCE_DIR=C:/path/to/unpacked/nng-1.11
set RSTATALINK2_KEEP_BUILD=1
```

### Linux

Prefer a system NNG installation:

```sh
sudo apt install libnng-dev pkg-config
```

Without system NNG, the installer tries to build bundled NNG with `cmake`.

### macOS

Prefer a system NNG installation:

```sh
brew install nng pkg-config
```

Without system NNG, the installer tries to build bundled NNG with `cmake`.

## Basic use

Set the path to Stata. Quoting is not needed for paths containing spaces:

```r
library(RStataLink2)

options(statapath = "C:/Program Files/Stata18/StataMP-64.exe")
```

Start Stata, run a command, and stop Stata:

```r
i <- startStata()

ans <- doInStata(i, "display 3 + 4", results = NULL)
ans$log

stopStata(i)
```

The returned log contains the command and the command's Stata output:

```text
. display 3 + 4
7
```

To keep the output but suppress command echoing, use:

```r
options(RStataLink2.log_show_command = FALSE)
```

After `startStata()`, code-only calls use the most recently started Stata session:

```r
doInStata("display sqrt(144)", results = NULL)
```

The canonical call remains explicit:

```r
doInStata(i, "display sqrt(144)", results = NULL)
```

## Sending data from R to Stata

Pass a data frame through `df`:

```r
d <- data.frame(
  id = 1:5,
  x = c(2, 4, 6, 8, 10),
  group = c("a", "a", "b", "b", "b"),
  stringsAsFactors = FALSE
)

out <- doInStata(
  i,
  code = "summarize x",
  df = d,
  import_df = FALSE,
  results = "r"
)

out$results$r_class$scalars
```

## Round trips

Set `import_df = TRUE` to bring the active Stata dataset back to R:

```r
out <- doInStata(
  i,
  code = "generate double x2 = x^2",
  df = d,
  import_df = TRUE,
  results = NULL
)

out$df
```

## Extracting Stata results

Use `results = "r"`, `results = "e"`, or `results = c("e", "r")`:

```r
r <- doInStata(
  i,
  code = "summarize x",
  df = d,
  import_df = FALSE,
  results = "r"
)

r$results$r_class
```

For estimation results:

```r
e <- doInStata(
  i,
  code = "sysuse auto, clear\nregress price weight mpg",
  import_df = FALSE,
  results = "e"
)

e$results$e_class$modeldf
```

## Futures

A future sends the job immediately and receives the result later:

```r
f <- doInStata(i, "sleep 1000\ndisplay 42", future = TRUE, results = NULL)
# do other R work here
getStataFuture(f)
```

A sent job cannot be cancelled safely. `deleteStataFuture()` is retained for API compatibility and warns if used.

## Transfer modes

The default transfer mode is automatic:

```r
options(RStataLink2.df_transfer = "auto")
options(RStataLink2.df_get_transfer = "auto")
```

In automatic mode:

- numeric-heavy data frames use the NNG binary path;
- large string-heavy imports may use a temporary Stata `.dta` file through `foreign::write.dta()` and Stata `use`;
- round trips that used the `.dta` import path can also use `.dta` export;
- unsupported cases fall back to the NNG path.

You can force a mode for debugging or benchmarking:

```r
options(RStataLink2.df_transfer = "nng")
options(RStataLink2.df_transfer = "dta")
```

Tuning options:

```r
options(RStataLink2.dta_string_cell_threshold = 2000)
options(RStataLink2.dta_string_byte_threshold = 50000)
options(RStataLink2.dta_max_string_width = 244)
```

## Clusters and load balancing

Start a cluster of Stata servers:

```r
cl <- startStataCluster(4)
```

Fixed-wave scheduling sends one job to each worker, waits for the whole wave, then sends the next wave:

```r
jobs <- c(
  "sleep 100\ndisplay 1",
  "sleep 1000\ndisplay 2",
  "sleep 200\ndisplay 3",
  "sleep 1500\ndisplay 4",
  "sleep 100\ndisplay 5"
)

static <- doInStataCluster(cl, jobs, results = NULL)
```

Load-balanced scheduling sends the next job to the first worker that replies:

```r
lb <- doInStataClusterLB(cl, jobs, results = NULL)
```

Tune the polling interval if needed:

```r
options(RStataLink2.lb_poll_interval = 0.01)
```

Stop all workers:

```r
stopStataCluster(cl)
```

## Manual Stata server startup for debugging

In Stata:

```stata
adopath ++ "path/to/installed/RStataLink2/stata"
adopath ++ "path/to/installed/RStataLink2/stata-plugin"
cd "path/to/installed/RStataLink2/stata-plugin"
rslng plugincheck
rslng server, endpoint("tcp://127.0.0.1:5759")
```

Then connect from R with the internal low-level helpers for debugging.

## Benchmarking

The package installs a benchmark script, here is it's location:

```r
system.file(
  "benchmark",
  "benchmark-rstatalink2-vs-rstatalink.R",
  package = "RStataLink2",
  mustWork = TRUE
)
```

From PowerShell, you can run the benchmarks with:

```powershell
Rscript.exe -e 'source(system.file("benchmark","benchmark-rstatalink2-vs-rstatalink.R",package="RStataLink2",mustWork=TRUE),chdir=TRUE)' `
  --stata "C:/Program Files/Stata18/StataMP-64.exe" `
  --out "C:/temp/rstatalink-benchmark" `
  --reps 5 `
  --sizes 100,10000,100000 `
  --cluster-workers 4
```

The script writes:

```text
rstatalink-benchmark-raw.csv
rstatalink-benchmark-summary.csv
rstatalink-benchmark-ratios.csv
rstatalink-benchmark-errors.csv
rstatalink-benchmark-config.csv
rstatalink-benchmark-packages.csv
rstatalink-benchmark-session-info.txt
rstatalink-benchmark-notes.txt
```

The raw and error CSV files include a `command` column. Round-trip benchmarks validate returned values, not only row/column counts. Cluster benchmarks validate the number of returned job results and per-job Stata error status.

## Benchmark conclusions from the repeated runs

Two full benchmark runs were checked before this publication update. Both used RStataLink2 0.0.15.9000 and RStataLink 1.4 on Windows/AppV Stata, with five repetitions, row sizes 100, 10,000, and 100,000, and four cluster workers.

Reliability looked good for RStataLink2:

- RStataLink2 had zero recorded failures in both benchmark archives.
- RStataLink2 `cluster_lb_uneven` completed successfully in both runs.

Median timings were stable enough to support the main performance claims below. Values are shown as run 1 / run 2.

| Operation | RStataLink median | RStataLink2 median | Interpretation |
|---|---:|---:|---|
| `ready_ping` | 0.05 / 0.05 s | 0.00 / 0.00 s | Socket pings are effectively instantaneous at this resolution. |
| `exec_display_with_log` | 0.06 / 0.06 s | 0.02 / 0.03 s | RStataLink2 is faster for tiny logged commands. |
| `exec_multiline` | 0.05 / 0.06 s | 0.00 / 0.02 s | The no-log/no-snapshot path helps small multiline jobs. |
| `exec_error_capture` | 0.12 / 0.22 s | 0.05 / 0.09 s | Intentional Stata errors are captured faster. |
| `r_to_stata_numeric`, 100,000 rows | 3.00 / 2.86 s | 0.08 / 0.07 s | Numeric import is about 38x to 41x faster. |
| `r_to_stata_string`, 100,000 rows | 1.63 / 1.72 s | 0.25 / 0.25 s | The hybrid string-heavy path is now clearly faster. |
| `r_to_stata_mixed`, 100,000 rows | 2.01 / 2.25 s | 3.60 / 3.44 s | Mixed numeric-plus-string import remains the main performance TODO. |
| `roundtrip_numeric`, 100,000 rows | failed correctness checks | 0.22 / 0.20 s | RStataLink2 completed the checked numeric round trip. |
| `roundtrip_mixed`, 100,000 rows | failed correctness checks | 7.59 / 6.98 s | RStataLink2 completed the checked mixed round trip, but this path still needs optimization. |
| `stata_to_r_generated`, 100,000 rows | 2.19 / 2.58 s | 1.83 / 1.70 s | RStataLink2 is moderately faster for generated data export. |
| `cluster_startup`, 4 workers | 5.72 / 10.40 s | 8.22 / 7.06 s | Startup is variable, but RStataLink2 started all workers in both runs. |
| `cluster_lb_uneven`, 4 workers | 9.47 / 10.19 s | 2.41 / 2.33 s | The load-balanced scheduler is about 4x faster on uneven jobs. |
| `cluster_shutdown`, 4 workers | 12.13 / 12.16 s | 0.92 / 1.27 s | RStataLink2 shuts down worker clusters much faster. |

The current conclusion is that RStataLink2 is stable enough for broader GitHub testing and already strong for command dispatch, numeric import, string-only import, checked numeric round trips, generated-data export, and uneven cluster workloads. The main optimization target left is mixed data frames with both many numeric cells and many string cells. A future optimization could split large mixed imports so numeric columns use the NNG binary path while string columns use a native Stata import path, rather than forcing the whole mixed frame through one transfer strategy.

## Build-log notes

During bundled NNG compilation, CMake feature probes such as:

```text
-- Looking for strlcpy - not found
```

are normal. They mean NNG will use another implementation path. Windows/Rtools builds may also show warnings from third-party NNG source. These are not emitted by `rslng_plugin.c` and are not fatal if the build reaches `rslng__plugin.plugin`.

The plugin explicitly registers NNG TCP, IPC, and inproc transports before opening sockets. This avoids static-link builds where the plugin loads successfully but `nng_listen()` reports `Not supported` for `tcp://` endpoints.

## Current limitations

Implemented:

- persistent Stata server startup and shutdown;
- readiness pings;
- Stata code execution;
- cleaned returned logs;
- optional no-log/no-results fast path;
- data-frame transfer in both directions;
- basic `r()` and `e()` extraction;
- futures;
- fixed-wave and load-balanced Stata clusters;
- source-package plugin compilation on Windows, Linux, and macOS.

Not implemented:

- variable labels, value labels, formats, notes, characteristics, and R attributes;
- extended Stata missing values;
- full `strL` import/export;
- matrix transfer as a first-class R API;
- true cancellation of jobs already sent to Stata.

## Protocol sketch

Every NNG message uses:

```text
8 bytes   magic: RSLNG01\0
4 bytes   message kind, little-endian uint32
4 bytes   text length, little-endian uint32
4 bytes   payload length, little-endian uint32
4 bytes   reserved
N bytes   UTF-8 text
M bytes   binary payload
```

Data frames normally use a compact column-oriented payload. Current R-to-Stata NNG transfers use DF02, which includes precomputed Stata string widths.

```text
4 bytes   magic: DF02
4 bytes   row count
4 bytes   column count
metadata  repeated type, string width, name length, name bytes
columns   double vectors or length-prefixed UTF-8 strings
```

## Roadmap

1. Preserve labels, formats, and Stata date/time metadata.
2. Add `strL` import and UTF-8-safe string truncation.
3. Add matrix transfer.
4. Continue improving string-heavy transfer performance.
