program define rslng
    version 16.0
    gettoken subcmd 0 : 0, parse(" ,")
    if `"`subcmd'"' == "server" {
        rslng_server `0'
        exit
    }
    if `"`subcmd'"' == "plugincheck" {
        plugin call rslng__plugin, version
        exit
    }
    di as err "unknown rslng subcommand: `subcmd'"
    di as txt "available subcommands: server, plugincheck"
    exit 198
end

program define rslng_server
    version 16.0
    syntax, ENDpoint(string) [TIMEout(integer 1000) Verbose Exitstata]

    local endpoint = trim(`"`endpoint'"')
    while strlen(`"`endpoint'"') >= 2 & substr(`"`endpoint'"', 1, 1) == char(34) & substr(`"`endpoint'"', strlen(`"`endpoint'"'), 1) == char(34) {
        local endpoint = substr(`"`endpoint'"', 2, strlen(`"`endpoint'"') - 2)
        local endpoint = trim(`"`endpoint'"')
    }
    local running 1
    tempfile rslng_r_snapshot rslng_e_snapshot
    local rslng_r_snapshot_ok 0
    local rslng_e_snapshot_ok 0

    plugin call rslng__plugin, open `"`endpoint'"' "pair" "listen" "`timeout'"
    di as txt "RStataLink2 server listening at `endpoint'"

    while `running' {
        local rslng_kind ""
        local rslng_text ""
        local rslng_nrows ""
        local rslng_ncols ""
        local rslng_names ""
        local rslng_types ""
        local rslng_widths ""

        capture plugin call rslng__plugin, recv
        if _rc {
            di as err "RStataLink2 receive failed, rc=" _rc
            continue
        }

        if `"`rslng_kind'"' == "TIMEOUT" {
            continue
        }

        if `"`verbose'"' != "" {
            di as txt "RStataLink2 request: `rslng_kind'"
        }

        if `"`rslng_kind'"' == "PING" {
            plugin call rslng__plugin, reply_text "0" "PONG"
        }
        else if `"`rslng_kind'"' == "STOP" {
            if trim(`"`rslng_text'"') == "clear" {
                capture quietly clear
            }
            plugin call rslng__plugin, reply_text "0" "STOPPING"
            local running 0
        }
        else if inlist(`"`rslng_kind'"', "EXEC", "EXEC_NOLOG", "EXEC_NOSNAP", "EXEC_NOLOG_NOSNAP") {
            local rslng_nolog = inlist(`"`rslng_kind'"', "EXEC_NOLOG", "EXEC_NOLOG_NOSNAP")
            local rslng_snapshot = !inlist(`"`rslng_kind'"', "EXEC_NOSNAP", "EXEC_NOLOG_NOSNAP")
            tempfile rslng_log
            tempname rslng_lognm rslng_fh
            if !`rslng_nolog' {
                capture log close `rslng_lognm'
                capture noisily log using "`rslng_log'", replace text name(`rslng_lognm')
            }

            if `rslng_snapshot' {
                capture quietly return clear
                capture quietly ereturn clear
            }

            local hasnl = (strpos(`"`rslng_text'"', char(10)) > 0) | (strpos(`"`rslng_text'"', char(13)) > 0)
            if `hasnl' {
                tempfile rslng_code
                file open `rslng_fh' using "`rslng_code'", write text replace
                file write `rslng_fh' `"`rslng_text'"' _n
                file close `rslng_fh'
                if `rslng_nolog' {
                    capture quietly do "`rslng_code'"
                }
                else {
                    capture noisily do "`rslng_code'"
                }
            }
            else {
                if `rslng_nolog' {
                    capture quietly `rslng_text'
                }
                else {
                    capture noisily `rslng_text'
                }
            }
            local rc = _rc

            if `rc' == 0 & `rslng_snapshot' {
                capture rslng_save_results r `"`rslng_r_snapshot'"'
                local rslng_r_snapshot_ok = (_rc == 0)
                capture rslng_save_results e `"`rslng_e_snapshot'"'
                local rslng_e_snapshot_ok = (_rc == 0)
            }
            else {
                local rslng_r_snapshot_ok 0
                local rslng_e_snapshot_ok 0
            }

            if `rslng_nolog' {
                capture plugin call rslng__plugin, reply_text "`rc'" "__RSL2_RC__=`rc'"
            }
            else {
                capture log close `rslng_lognm'
                capture plugin call rslng__plugin, reply_file "`rc'" `"`rslng_log'"'
            }
            if _rc {
                di as err "RStataLink2 reply failed, rc=" _rc
            }
        }
        else if `"`rslng_kind'"' == "PUT_DF" {
            capture plugin call rslng__plugin, meta
            if _rc {
                local rc = _rc
                plugin call rslng__plugin, reply_text "`rc'" "metadata parse failed, rc=`rc'"
                continue
            }

            local rc = 0
            quietly clear
            if _rc local rc = _rc
            if `rc' == 0 {
                quietly set obs `rslng_nrows'
                if _rc local rc = _rc
            }
            if `rc' == 0 {
                forvalues i = 1/`rslng_ncols' {
                    local nm : word `i' of `rslng_names'
                    local tp : word `i' of `rslng_types'
                    local wd : word `i' of `rslng_widths'
                    if `"`tp'"' == "str" {
                        local wdnum = real("`wd'")
                        if missing(`wdnum') local wdnum = 1
                        if `wdnum' < 1 local wdnum = 1
                        if `wdnum' > 2045 local wdnum = 2045
                        capture generate str`wdnum' `nm' = ""
                    }
                    else {
                        capture generate double `nm' = .
                    }
                    if _rc {
                        local rc = _rc
                        continue, break
                    }
                }
            }
            if `rc' {
                plugin call rslng__plugin, reply_text "`rc'" "variable creation failed, rc=`rc'"
                continue
            }

            if `rslng_ncols' > 0 {
                capture plugin call rslng__plugin _all, putdf
                local rc = _rc
            }
            else {
                local rc = 0
            }
            if `rc' == 0 {
                plugin call rslng__plugin, reply_text "0" "rows=`rslng_nrows' cols=`rslng_ncols'"
            }
            else {
                plugin call rslng__plugin, reply_text "`rc'" "data import failed, rc=`rc'"
            }
        }
        else if `"`rslng_kind'"' == "GET_RESULTS" {
            local rslng_class = trim(`"`rslng_text'"')
            if !inlist(`"`rslng_class'"', "e", "r") {
                plugin call rslng__plugin, reply_text "198" "GET_RESULTS expects e or r"
                continue
            }
            if `"`rslng_class'"' == "r" {
                local rslng_snapshot `"`rslng_r_snapshot'"'
                local rslng_snapshot_ok `rslng_r_snapshot_ok'
            }
            else {
                local rslng_snapshot `"`rslng_e_snapshot'"'
                local rslng_snapshot_ok `rslng_e_snapshot_ok'
            }
            if !`rslng_snapshot_ok' {
                capture rslng_save_empty_results `"`rslng_snapshot'"'
                if _rc {
                    local rc = _rc
                    plugin call rslng__plugin, reply_text "`rc'" "empty result snapshot failed, rc=`rc'"
                    continue
                }
            }
            capture rslng_send_saved_results `"`rslng_snapshot'"'
            if _rc {
                local rc = _rc
                plugin call rslng__plugin, reply_text "`rc'" "result extraction failed, rc=`rc'"
            }
        }
        else if `"`rslng_kind'"' == "GET_DF" {
            local rslng_vars `"`rslng_text'"'
            if trim(`"`rslng_vars'"') == "" local rslng_vars "_all"
            capture unab rslng_unab : `rslng_vars'
            if _rc {
                local rc = _rc
                plugin call rslng__plugin, reply_text "`rc'" "varlist expansion failed, rc=`rc'"
                continue
            }
            capture plugin call rslng__plugin `rslng_unab', getdf `"`rslng_unab'"'
            if _rc {
                local rc = _rc
                plugin call rslng__plugin, reply_text "`rc'" "data export failed, rc=`rc'"
            }
        }
        else {
            plugin call rslng__plugin, reply_text "198" "unknown message kind: `rslng_kind'"
        }
    }

    capture plugin call rslng__plugin, close
    di as txt "RStataLink2 server stopped"
    if `"`exitstata'"' != "" {
        di as txt "RStataLink2 closing Stata"
        exit, STATA clear
    }
end


program define rslng_init_results_dataset
    version 16.0
    clear
    generate str20 type = ""
    generate str244 name = ""
    generate double value = .
    generate strL txt_value = ""
    generate str244 rowname = ""
    generate str244 colname = ""
end

program define rslng_save_empty_results
    version 16.0
    args rslng_saving
    preserve
    rslng_init_results_dataset
    quietly save `"`rslng_saving'"', replace
    restore
end

program define rslng_save_results
    version 16.0
    args rslng_class rslng_saving

    local rslng_class = trim(`"`rslng_class'"')
    if !inlist(`"`rslng_class'"', "e", "r") exit 198
    if trim(`"`rslng_saving'"') == "" exit 198

    local rslng_scalars : `rslng_class'(scalars)
    local rslng_macros : `rslng_class'(macros)
    local rslng_matrices : `rslng_class'(matrices)

    local rslng_ns 0
    foreach v of local rslng_scalars {
        local ++rslng_ns
        local rslng_scalar_name_`rslng_ns' `"`v'"'
        local rslng_scalar_value_`rslng_ns' = `rslng_class'(`v')
    }

    local rslng_nmac 0
    foreach v of local rslng_macros {
        local ++rslng_nmac
        local rslng_macro_name_`rslng_nmac' `"`v'"'
        local rslng_macro_value_`rslng_nmac' `"``rslng_class'(`v')'"'
    }

    local rslng_nmat 0
    foreach m of local rslng_matrices {
        local ++rslng_nmat
        tempname rslng_M
        matrix `rslng_M' = `rslng_class'(`m')
        local rslng_matrix_name_`rslng_nmat' `"`m'"'
        local rslng_matrix_handle_`rslng_nmat' `"`rslng_M'"'
    }

    local rslng_has_b 0
    local rslng_has_v 0
    if `"`rslng_class'"' == "e" {
        tempname rslng_B rslng_V
        capture matrix `rslng_B' = e(b)
        if !_rc {
            local rslng_has_b 1
            local rslng_b_names : colfullnames `rslng_B'
            capture matrix `rslng_V' = e(V)
            if !_rc local rslng_has_v 1
        }
    }

    preserve
    rslng_init_results_dataset
    local n 0

    if `rslng_ns' > 0 {
        forvalues i = 1/`rslng_ns' {
            local ++n
            quietly set obs `=_N + 1'
            quietly replace type = "scalars" in `n'
            quietly replace name = `"`rslng_scalar_name_`i''"' in `n'
            quietly replace value = `rslng_scalar_value_`i'' in `n'
        }
    }

    if `rslng_nmac' > 0 {
        forvalues i = 1/`rslng_nmac' {
            local ++n
            quietly set obs `=_N + 1'
            quietly replace type = "macros" in `n'
            quietly replace name = `"`rslng_macro_name_`i''"' in `n'
            quietly replace txt_value = `"`rslng_macro_value_`i''"' in `n'
        }
    }

    if `rslng_nmat' > 0 {
        forvalues i = 1/`rslng_nmat' {
            local mname `"`rslng_matrix_name_`i''"'
            local M `"`rslng_matrix_handle_`i''"'
            local rnames : rowfullnames `M'
            local cnames : colfullnames `M'
            foreach c of local cnames {
                foreach r of local rnames {
                    local ++n
                    quietly set obs `=_N + 1'
                    quietly replace type = "matrices" in `n'
                    quietly replace name = `"`mname'"' in `n'
                    quietly replace colname = `"`c'"' in `n'
                    quietly replace rowname = `"`r'"' in `n'
                    quietly replace value = el(`M', rownumb(`M', `"`r'"'), colnumb(`M', `"`c'"')) in `n'
                }
            }
        }
    }

    if `rslng_has_b' {
        local j 0
        foreach v of local rslng_b_names {
            local ++j
            local ++n
            quietly set obs `=_N + 1'
            quietly replace type = "_b" in `n'
            quietly replace name = `"`v'"' in `n'
            quietly replace value = el(`rslng_B', 1, `j') in `n'

            local ++n
            quietly set obs `=_N + 1'
            quietly replace type = "_se" in `n'
            quietly replace name = `"`v'"' in `n'
            if `rslng_has_v' {
                quietly replace value = sqrt(el(`rslng_V', `j', `j')) in `n'
            }
        }
    }

    quietly save `"`rslng_saving'"', replace
    restore
end

program define rslng_send_saved_results
    version 16.0
    args rslng_saving

    preserve
    capture use `"`rslng_saving'"', clear
    if _rc {
        local rc = _rc
        restore
        exit `rc'
    }
    unab rslng_unab : _all
    plugin call rslng__plugin `rslng_unab', getdf `"`rslng_unab'"'
    local rc = _rc
    restore
    exit `rc'
end

program rslng__plugin, plugin
