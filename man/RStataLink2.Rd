\name{RStataLink2}
\alias{RStataLink2}
\alias{startStata}
\alias{stopStata}
\alias{isStataReady}
\alias{doInStata}
\alias{getStataFuture}
\alias{deleteStataFuture}
\alias{startStataCluster}
\alias{stopStataCluster}
\alias{doInStataCluster}
\alias{doInStataClusterLB}
\title{RStataLink-compatible API backed by NNG}
\usage{
startStata(timeout = 60, start_cmd = getOption("statapath"),
  compath = tempdir(), exit_on_error601 = FALSE, verify = TRUE)

stopStata(id, clear = FALSE)

isStataReady(id, timeout = 1)

doInStata(id = NULL, code = "", df = NULL, import_df = !is.null(df),
  results = c("e", "r"), timeout = Inf, preserve_restore = FALSE,
  cleanup = TRUE, nolog = FALSE, future = FALSE)

getStataFuture(StataFuture)

deleteStataFuture(StataFuture)

startStataCluster(n = parallel::detectCores(), ...)

stopStataCluster(cl, ...)

doInStataCluster(cl, X, isStataReadyTimeout = 1, ...)

doInStataClusterLB(cl, X, isStataReadyTimeout = 1, ...)
}
\arguments{
\item{timeout}{Seconds to wait for Stata startup, readiness, or job completion.}
\item{start_cmd}{Command used to launch Stata, for example a quoted path to a Stata executable. Defaults to option \code{statapath}.}
\item{compath}{Directory used for local bootstrap artifacts and, on Unix-like systems, IPC socket paths.}
\item{exit_on_error601}{Compatibility argument retained from \pkg{RStataLink}.}
\item{verify}{Logical. Should R wait until the Stata server answers a ping?}
\item{id}{A \code{StataID} object returned by \code{startStata()}. In \code{doInStata()}, \code{id = NULL} uses the most recently started Stata session; if the first positional argument is character and \code{code} is left at its default, that argument is treated as Stata code.}
\item{clear}{Logical. Should Stata data in memory be cleared before stopping the server?}
\item{code}{Stata code as a character scalar or character vector.}
\item{df}{Optional data frame to transfer to Stata before running \code{code}.}
\item{import_df}{Logical. Should the current Stata data set be returned as \code{$df}?}
\item{results}{\code{NULL}, \code{"e"}, \code{"r"}, or \code{c("e", "r")}. Basic result extraction is implemented for scalars, macros, matrices, coefficients, and standard errors.}
\item{preserve_restore}{Logical. Wrap the Stata code in \code{preserve} and \code{restore}.}
\item{cleanup}{Compatibility argument. The NNG path does not create per-job TSV files.}
\item{nolog}{Logical. Drop the Stata log from the returned list.}
\item{future}{Logical. Send the job and return a \code{StataFuture} without waiting for the reply.}
\item{StataFuture}{A \code{StataFuture} object returned by \code{doInStata(..., future = TRUE)}.}
\item{n}{Number of Stata instances.}
\item{cl}{A list of \code{StataID} objects.}
\item{X}{A character vector or list of character vectors containing Stata jobs.}
\item{isStataReadyTimeout}{Seconds passed to \code{isStataReady()} when checking worker availability.}
\item{...}{Additional arguments passed to the underlying function.}
}
\description{
\pkg{RStataLink2} keeps the public function names and call signatures of \pkg{RStataLink}, while replacing the internal file-polling transport with an NNG \code{pair} channel, binary data-frame transfer, and an automatic hybrid DTA path for large string-heavy imports.
}
\details{
The current prototype supports starting and stopping a persistent Stata server, pinging readiness, executing Stata code, transferring data frames into Stata, retrieving the active Stata data set, futures over an already-sent request, and fixed-wave and load-balanced multi-instance cluster execution. Returned Stata logs are cleaned by default: Stata text-log headers and footers are removed, and the submitted command is echoed when available. This can be changed with \code{options(RStataLink2.clean_log = FALSE)} or \code{options(RStataLink2.log_show_command = FALSE)}. Calls with \code{nolog = TRUE} and \code{results = NULL} use a no-log/no-snapshot execution path to reduce small-command overhead. Numeric-heavy data frames normally use the NNG binary transfer path. With \code{options(RStataLink2.df_transfer = "auto")}, large string-heavy data frames may use a temporary native Stata \code{.dta} file through \pkg{foreign}; this can be forced with \code{"dta"} or disabled with \code{"nng"}. Round-trip exports following a DTA import can similarly use \code{options(RStataLink2.df_get_transfer = "auto")}. After \code{startStata()}, the most recently started session is stored as the active session, so \code{doInStata("display 1")} is accepted as a convenience extension while \code{doInStata(i, "display 1")} remains the canonical call. Labels, formats, and full Stata missing-value fidelity are planned but not implemented yet.

When installed from a source package, \code{configure} or \code{configure.win} builds the Stata plugin \code{rslng__plugin.plugin} and installs it under \code{system.file("stata-plugin", package = "RStataLink2")}. Binary package installation performs no compilation; \code{startStata()} only prepends the installed ado and plugin directories to Stata's \code{adopath}.

The repeated 0.0.15.9000 benchmark archives checked before publication showed zero recorded RStataLink2 failures in two full runs with four cluster workers. The same runs showed strong speedups for numeric import, string-only import, checked numeric round trips, generated-data export, and load-balanced uneven cluster jobs. Large mixed numeric-plus-string imports remain the main performance optimization target.

The installed package includes a benchmark script at:
\preformatted{
system.file("benchmark", "benchmark-rstatalink2-vs-rstatalink.R", package = "RStataLink2")
}
The script accepts a \code{--stata} argument and also tries environment variables, \code{PATH}, common installation folders, and Windows AppV integration paths. It writes raw timings, summaries, ratios, failure logs, the Stata command for each timed operation when applicable, package metadata, session information, and an output archive. Numeric and mixed round-trip cases validate returned values. With \code{--cluster-workers >= 2}, it also compares fixed-wave cluster execution with true load-balanced execution on uneven jobs and checks that cluster calls return the expected number of job results.

\code{doInStataClusterLB()} keeps all ready workers busy, polls their NNG sockets non-blockingly, records results in the original order of \code{X}, and dispatches the next queued job to the first worker that replies. The polling delay is controlled by option \code{RStataLink2.lb_poll_interval}.
}
\value{
The return shapes follow \pkg{RStataLink}: \code{startStata()} returns a \code{StataID}; \code{doInStata()} returns a list with elements such as \code{log}, \code{error}, \code{df}, and \code{results}; \code{future = TRUE} returns a \code{StataFuture}; cluster helpers return lists.
}
\examples{
\dontrun{
options(statapath = "C:/Program Files/Stata18/StataMP-64.exe")
i <- startStata()
doInStata(i, 'display 100 + 15.7', results = NULL)
doInStata('display 3 + 4', results = NULL)
doInStata(i, 'describe', df = data.frame(x = 1:3, y = letters[1:3]), import_df = TRUE)
stopStata(i, clear = TRUE)
}
}
