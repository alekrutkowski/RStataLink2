# Benchmark script

`benchmark-rstatalink2-vs-rstatalink.R` compares installed copies of RStataLink2 and RStataLink using the same Stata executable.

Basic Windows example:

```powershell
Rscript.exe --vanilla "C:/Users/Public/R/R4_libs_x86_64/RStataLink2/benchmark/benchmark-rstatalink2-vs-rstatalink.R" `
  --stata "C:/Program Files/Stata18/StataMP-64.exe" `
  --out "C:/temp/rstatalink-benchmark" `
  --reps 5 `
  --sizes 100,10000,100000
```

Add `--cluster-workers 4` to benchmark fixed-wave cluster execution against load-balanced cluster execution on uneven jobs.

The script writes raw timings, summaries, median-speed ratios, failures, package metadata, session information, notes, and a zipped output archive. Summary and ratio files use successful rows only; failures are written separately. Raw and error CSV files include a `command` column for operations that send Stata code. Numeric and mixed round-trip cases validate returned values, not only row and column counts. Cluster cases validate result counts and per-job Stata error status.

The ratio column is interpreted as `RStataLink median seconds / RStataLink2 median seconds`; values above 1 mean RStataLink2 was faster.

By default the benchmark uses RStataLink2's automatic transfer mode, so numeric-heavy cases use the NNG binary path and large string-heavy cases may use the hybrid DTA path. To force the pure NNG string path before running the benchmark, set `options(RStataLink2.df_transfer = "nng", RStataLink2.df_get_transfer = "nng")` in a wrapper script.

In the repeated 0.0.15.9000 benchmark archives used for the GitHub-publication check, RStataLink2 had zero recorded failures in both runs. The previous transient cluster-startup failure did not recur, and load-balanced uneven cluster jobs completed successfully. The main remaining performance TODO is large mixed data-frame import, where RStataLink2 was slower than RStataLink despite being much faster for numeric-only and string-only imports.
