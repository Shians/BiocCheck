#' @importFrom graph nodes acc
#' @importFrom tools Rd2ex
#' @importFrom utils Stangle
#' @importFrom codetools walkCode findGlobals
NULL

.msg <- function(..., appendLF=TRUE, indent=0, exdent=2)
{
    contents <- list(...)
    txt <- if (length(contents) != 1L) do.call(sprintf, contents) else contents
    message(paste(strwrap(txt, indent=indent, exdent=exdent), collapse="\n"),
        appendLF=appendLF)
}

.stop <- function(...) stop(noquote(sprintf(...)), call.=FALSE)

.verbatim <-
    function(..., appendLF=TRUE, indent=6, exdent=8, width=getOption("width"))
{
    ## don't wrap elements of msg; indent first line by 'indent',
    ## subsequent lines by 'exdent'
    txt <- sprintf(...)
    if (length(txt)) {
        prefix <- paste(rep(" ", indent), collapse="")
        txt[1] <- paste0(prefix, txt[1])
    }
    if (length(txt) > 1L) {
        prefix <- paste(rep(" ", exdent), collapse="")
        txt[-1] <- paste0(prefix, txt[-1])
    }
    txt <- ifelse(
        (!is.na(txt)) & (nchar(txt) > width),
        sprintf("%s...", substr(txt, 1, width - 3)),
        txt)
    message(paste(txt, collapse="\n"), appendLF=appendLF)
}

handleCondition <-
    function(
        ..., condition, help_text = character(0L),
        messages = character(0L), nframe = 2L
    )
{
    msg <- list(paste0(...))
    if (!tolower(condition) %in% c("warning", "error", "note"))
        stop("<Internal> Designate input with 'warning', 'error', or 'note'.")
    cl <- sys.call(sys.parent(n = nframe))[[1L]]
    ml <- structure(msg, .Names = tail(as.character(cl), 1L))
    .BiocCheck$add(
        ml, condition = condition, help_text = help_text, messages = messages
    )
    .BiocCheck$log
}

handleCheck <- function(..., appendLF=TRUE)
{
    msg <- sprintf("* %s", paste0(...))
    .BiocCheck$setCheck(msg)
    .msg(msg, appendLF=appendLF)
}

handleError <- function(...)
{
    handleCondition(..., condition = "error")
}

handleErrorFiles <- function(..., help_text = "Found in files:") {
    handleCondition(..., help_text = help_text, condition = "error")
}

handleWarning <- function(...)
{
    handleCondition(..., condition = "warning")
}

handleWarningFiles <- function(..., help_text = "Found in files:") {
    handleCondition(..., help_text = help_text, condition = "warning")
}

handleNote <- function(...)
{
    handleCondition(..., condition = "note")
}

handleNoteFiles <- function(..., help_text = "Found in files:") {
    handleCondition(..., help_text = help_text, condition = "note")
}

handleMessage <- function(..., indent=4, exdent=6)
{
    msg <- paste0(...)
    .msg("  %s", msg, indent=indent, exdent=exdent)
}

handleVerbatim <- function(msg, indent=4, exdent=6, width=getOption("width"))
{
    .verbatim("%s", msg, indent=indent, exdent=exdent, width=width)
}

.run_r_command <- function(cmd, args, stderr) {
    res <- system2(cmd, args, stdout=NULL, stderr=stderr)
    if (res) {
        message(
            "  cmd: ", cmd,
            "\n  args: ", args,
            "\n  stderr:",
            "\n  ", paste(readLines(stderr), collapse="\n  "), "\n"
        )
    }
    res
}

installAndLoad <- function(pkgpath, install_dir = tempfile())
{
    if (!dir.exists(install_dir))
        dir.create(install_dir)
    dir.create(libdir <- file.path(install_dir, "lib"))
    file.create(stderr <- file.path(install_dir, "install.stderr"))

    r_libs_user_old <- Sys.getenv("R_LIBS_USER")
    on.exit(do.call("Sys.setenv", list(R_LIBS_USER=r_libs_user_old)))
    r_libs_user <- paste(c(libdir, .libPaths()), collapse=.Platform$path.sep)
    Sys.setenv(R_LIBS_USER=r_libs_user)

    rcmd <- file.path(Sys.getenv("R_HOME"), "bin", "R")
    args <- sprintf("--vanilla CMD INSTALL --no-test-load --library=%s %s",
                    libdir, shQuote(pkgpath))
    res <- .run_r_command(cmd = rcmd, args = args, stderr = stderr)
    if (res) {
        handleError(pkgpath, " must be installable.")
    }
    pkgname <- .getPackageName(pkgpath)
    args <- sprintf(
        "--vanilla -e 'library(%s)'", pkgname
    )
    res <- .run_r_command(cmd = rcmd, args = args, stderr = stderr)
    if (res) {
        handleError(pkgpath, " must be loadable.")
    }
    install_dir
}

# Takes as input the value of an Imports, Depends,
# or LinkingTo field and returns a named character
# vector of Bioconductor dependencies, where the names
# are version specifiers or blank.
cleanupDependency <- function(input, remove.R=TRUE)
{
    if (is.null(input)) return(character(0))
    if (!nchar(input)) return(character(0))
    output <- gsub("\\s", "", input)
    raw_nms <- output
    nms <- strsplit(raw_nms, ",")[[1]]
    namevec <- vector(mode = "character", length(nms))
    output <- gsub("\\([^)]*\\)", "", output)
    res <- strsplit(output, ",")[[1]]
    for (i in seq_along(nms))
    {
        if(grepl(">=", nms[i], fixed=TRUE))
        {
            tmp <- gsub(".*>=", "", nms[i])
            tmp <- gsub(")", "", tmp, fixed=TRUE)
            namevec[i] <- tmp
        } else {
            namevec[i] <- ''
        }
    }
    names(res) <- namevec
    if (remove.R)
        res <- res[which(res != "R")]
    res
}

getAllDependencies <- function(pkgdir)
{
    dcf <- read.dcf(file.path(pkgdir, "DESCRIPTION"))
    fields <- c("Depends", "Imports", "Suggests", "Enhances", "LinkingTo")
    out <- c()
    for (field in fields)
    {
        if (field %in% colnames(dcf))
            out <- append(out, cleanupDependency(dcf[, field]))
    }
    out
}

getAllDeprecatedPkgs <- function()
{
    # our best guess at deprecated packages
    # if write_views wasn't updated to manual add missing package info
    # a more complete would be to scrap the build report
    # html = htmlParse("http://bioconductor.org/checkResults/devel/bioc-LATEST/")
    # depdevel = xpathSApply(html, "//s", xmlValue)

    con <- url("https://bioconductor.org/packages/release/bioc/VIEWS")
    views_release <- read.dcf(con, all=TRUE)
    close(con)
    con <- url("https://bioconductor.org/packages/devel/bioc/VIEWS")
    views_devel <- read.dcf(con, all=TRUE)
    close(con)
    pkgs <- unique(c(
        views_release[["Package"]][which(views_release[["PackageStatus"]]
                                         == "Deprecated")],
        views_devel[["Package"]][which(views_devel[["PackageStatus"]]
                                       == "Deprecated")]
        ))
    pkgs
}

parseFile <- function(infile, pkgdir) {
    dir.create(parse_dir <- tempfile())
    if (grepl("\\.Rnw$|\\.Rmd|\\.Rrst|\\.Rhtml$|\\.Rtex", infile, TRUE)) {
        outfile <- NULL
        desc <- file.path(pkgdir, "DESCRIPTION")
        dcf <- read.dcf(desc)
        if ("VignetteBuilder" %in% colnames(dcf) &&
            dcf[,"VignetteBuilder"] == "knitr") {
            ## parse field in case more than one
            vigBuilder <- unlist(
                strsplit(dcf[, "VignetteBuilder"], ", "), use.names = FALSE
            )
            if ("knitr" %in% vigBuilder) {
                if (!requireNamespace("knitr"))
                    stop("'knitr' required to check 'Rmd' vignettes")
            }
        }
        outfile <- file.path(parse_dir, "parseFile.tmp")
        suppressWarnings(suppressMessages(
            capture.output({
                knitr::purl(
                    input=infile, output=outfile, documentation=0L
                )
            })
        ))
    } else if (grepl("\\.Rd$", infile, TRUE)) {
        rd <- tools::parse_Rd(infile)
        outfile <- file.path(parse_dir, "parseFile.tmp")
        code <- capture.output(tools::Rd2ex(rd))
        writeLines(code, con=outfile, sep="\n")
    } else if (grepl("\\.R$", infile, TRUE)) {
        outfile <- infile
    }
    p <- parse(outfile, keep.source=TRUE)
    getParseData(p)
}

parseFiles <- function(pkgdir)
{
    parsedCode <- list()
    dir1 <- dir(file.path(pkgdir, "R"), pattern="\\.R$", ignore.case=TRUE,
        full.names=TRUE)
    dir2 <- dir(file.path(pkgdir, "man"), pattern="\\.Rd$", ignore.case=TRUE,
        full.names=TRUE)
    dir3 <- dir(file.path(pkgdir, "vignettes"),
        pattern="\\.Rnw$|\\.Rmd$|\\.Rrst$|\\.Rhtml$|\\.Rtex$",
        ignore.case=TRUE, full.names=TRUE)
    files <- c(dir1, dir2, dir3)
    for (file in files)
    {
        df <- parseFile(file, pkgdir)
        if (nrow(df))
            parsedCode[[file]] <- df
    }
    parsedCode
}

findSymbolInParsedCode <- function(parsedCode, pkgname, symbolName,
    token, silent=FALSE)
{
    matches <- list()
    for (filename in names(parsedCode))
    {
        df <- parsedCode[[filename]]
        matchedrows <- df[which(df$token == token & df$text == symbolName),]
        if (nrow(matchedrows) > 0)
        {
            matches[[filename]] <- matchedrows[, c(1,2)]
        }
    }
    if (token == "SYMBOL_FUNCTION_CALL")
        parens <- "()"
    else
        parens <- ""
    for (name in names(matches))
    {
        x <- matches[[name]]
        for (i in nrow(x))
        {
            if (!silent)
            {
                if (grepl("\\.R$", name, ignore.case=TRUE))
                    handleMessage(sprintf(
                        "Found %s%s in %s (line %s, column %s)", symbolName,
                        parens, getDirFile(name), x[i,1], x[i,2]))
                else
                    handleMessage(sprintf(
                        "Found %s%s in %s", symbolName, parens,
                        getDirFile(name))) # FIXME test this
            }
        }
    }
    length(matches) # for tests
}

getDirFile <- function(fpath) {
    if (!identical(length(fpath), 1L))
        stop("<internal> 'fpath' input must be a scalar character")
    if (nzchar(fpath) && !is.na(fpath))
        fpath <- file.path(basename(dirname(fpath)), basename(fpath))

    fpath
}

.getTokenTextCode <- function(parsedf, token, text, lookback = character(0)) {
    cond <- parsedf$token %in% token & parsedf$text %in% text
    if (length(lookback))
        cond <- cond & parsedf$token[which(cond) - 1] != shQuote(lookback)
    parsedf[
        cond,
        c("line1", "col1", "token", "text"),
        drop = FALSE
    ]
}

.grepTokenTextCode <- function(parsedf, token, text) {
    parsedf[
        parsedf$token %in% token & grepl(text, parsedf$text),
        c("line1", "col1", "token", "text"),
        drop = FALSE
    ]
}

findSymbolsInParsedCode <-
    function(
        parsedCodeList, symbolNames, tokenTypes,
        FUN = .getTokenTextCode, fun = TRUE, ...
    )
{
    matches <- structure(vector("list", length(parsedCodeList)),
        .Names = names(parsedCodeList))
    allcombos <- expand.grid(
        tokenTypes = tokenTypes,
        symbolNames = symbolNames,
        stringsAsFactors = FALSE
    )
    tokenTypes <- allcombos[["tokenTypes"]]
    symbolNames <- allcombos[["symbolNames"]]

    for (filename in names(parsedCodeList)) {
        df <- parsedCodeList[[filename]]
        res <- Map(
            function(x, y) {
                FUN(parsedf = df, token = x, text = y, ...)
            },
            x= tokenTypes, y = symbolNames
        )
        res <- do.call(rbind.data.frame, res)
        matches[[filename]] <- res
    }

    matches <- Filter(nrow, matches)
    matches <- lapply(names(matches), function(nm) {
        dframe <- matches[[nm]]
        dframe[["text"]] <- paste0(dframe$text,
            ifelse(dframe$token == "SYMBOL_FUNCTION_CALL", "()", ""))
        dframe[["filename"]] <- nm
        dframe
    })

    matches <- do.call(
        function(...) rbind.data.frame(..., make.row.names = FALSE),
        matches
    )
    apply(matches, 1L, function(rowdf) {
        fmttxt <- "%s (line %s, column %s)"
        formt <- if (fun) paste0(rowdf["text"], " in ", fmttxt) else fmttxt
        sprintf(formt, getDirFile(rowdf["filename"]),
            rowdf["line1"], rowdf["col1"]
        )
    })
}

isInfrastructurePackage <- function(pkgDir)
{
    if (!file.exists(file.path(pkgDir, "DESCRIPTION")))
        return(FALSE)
    dcf <- read.dcf(file.path(pkgDir, "DESCRIPTION"))
    if (!"biocViews" %in% colnames(dcf))
    {
        return(FALSE)
    }
    biocViews <- dcf[, "biocViews"]
    views <- strsplit(gsub("\\s", "", biocViews), ",")[[1]]
    "Infrastructure" %in% views
}

getMaintainerEmail <- function(pkgdir)
{
    # Eventually update this to just look at Authors@R
    # Since the intention is to possible start running
    # this on the daily builder, leave Maintainer field
    # check. This is used to check for mailing list registration

    dcf <- read.dcf(file.path(pkgdir, "DESCRIPTION"))
    if ("Maintainer" %in% colnames(dcf))
    {
        m <- dcf[, "Maintainer"]
        ret <- regexec("<([^>]*)>", m)[[1]]
        ml <- attr(ret, "match.length")
        email <- substr(m, ret[2], ret[2]+ml[2]-1)
    } else if ("Authors@R" %in% colnames(dcf)) {
        ar <- dcf[, "Authors@R"]
        env <- new.env(parent=emptyenv())
        env[["c"]] <- c
        env[["person"]] <- utils::person
        pp <- parse(text=ar, keep.source=TRUE)
        tryCatch(people <- eval(pp, env),
            error=function(e) {
                # could not parse Authors@R
                return()
            })
        for (person in people)
        {
            if ("cre" %in% person$role)
            {
                email <- person$email
            }
        }
    }
    return(email)
}

docType <- function(rd) {
    tags <- tools:::RdTags(rd)
    if (any(tags == "\\docType"))
        as.character(rd[tags == "\\docType"][[1L]])
}


findLogicalFile <- function(fl) {
    env <- new.env()
    tryCatch(source(fl, local = env),
             error = function(err){
                 return(character())
             })
    objs <- ls(env, all.names=TRUE)
    for (obj in objs){
      if (!is.function(env[[obj]])){
           rm(list = obj, envir = env)
      }
    }
    globals <- eapply(env, safeFindGlobals)
    if (length(globals) != 0) {
        names(which(unlist(lapply(globals, function(x) {
            any(c("T","F") %in% x)
        }))))
    } else {
      character()
    }
}

safeFindGlobals <- function(env, ...) {
    tryCatch({
        findGlobals(env, ...)
    }, error = warning)
}

findLogicalRdir <- function(pkgname, symbol){

    env <- getNamespace(pkgname)
    objs <- ls(env, all.names=TRUE)
    objs <- objs[grep("^.__[CTM]__", objs, invert=TRUE)]
    globals <- lapply(objs, function(obj) {
        value <- env[[obj]]
        if (identical(typeof(value), "closure")) {
            findGlobals(value)
        } else character(0)
    })
    names(globals) <- objs
    if (length(globals) != 0) {
        found <- vapply(
            globals, function(x, symbol) any(symbol %in% x), logical(1), symbol
        )
        funName <- names(globals)[found]
        if (length(funName) > 0) {
            paste0(funName, "()")
        } else character()
    } else {
      character()
    }
}

grepPkgDir <- function(pkgdir, greparg, full_path=FALSE){
    args <- sprintf("%s %s*", greparg, pkgdir)
    fnd <- tryCatch(
        system2("grep", args, stdout=TRUE),
        warning=function(w){character()},
        error=function(e){character(0)})
    msg_files <- vapply(fnd,
                        FUN=function(x, pkgdir){
                            vl <- strsplit(x, split=":")
                            filename <-
                                if(full_path){
                                    vl[[1]][1]
                                } else {
                                    sub(vl[[1]][1], pattern=pkgdir,
                                        replacement="", fixed=TRUE)
                                }
                            lineNum <- vl[[1]][2]
                            if (tolower(.Platform$OS.type) == "windows"){
                                filename <-
                                    if(full_path){
                                        paste(vl[[1]][1], vl[[1]][2], sep=":")
                                    }else {
                                        sub(
                                            paste(vl[[1]][1], vl[[1]][2], sep=":"),
                                            pattern=pkgdir, replacement="",
                                            fixed=TRUE)
                                    }
                                lineNum <- vl[[1]][3]
                            }
                            sprintf("%s (line %s)", filename, lineNum)},
                        FUN.VALUE = character(1),
                        c(pkgdir=pkgdir),
                        USE.NAMES=FALSE)
    msg_files
}

getVigSources <- function(dir)
{
    dir(dir,
        pattern="\\.Rmd$|\\.Rnw$|\\.Rrst$|\\.Rhtml$|\\.Rtex$",
        ignore.case=TRUE, full.names=TRUE)
}

getRSources <- function(Rdir) {
    if (!identical(basename(Rdir), "R"))
        Rdir <- file.path(Rdir, "R")
    dir(Rdir, pattern = "\\.[Rr]$", full.names = TRUE)
}

getBadDeps <- function(pkgdir, lib.loc)
{
    cmd <- file.path(Sys.getenv("R_HOME"), "bin", "R")
    oldquotes <- getOption("useFancyQuotes")
    on.exit(options(useFancyQuotes=oldquotes))
    options(useFancyQuotes=FALSE)
    args <- sprintf("-q --vanilla --no-echo -f %s --args %s",
        system.file("script", "checkBadDeps.R", package="BiocCheck"),
        paste(dQuote(pkgdir), dQuote(lib.loc)))
    system2(cmd, args, stdout=TRUE, stderr=FALSE,
        env="R_DEFAULT_PACKAGES=NULL")
}

getVigBuilder <- function(desc)
{
    if (file.exists(desc))
        builder <- read.dcf(desc, fields = "VignetteBuilder")
    else
        builder <- NA
    if (is.na(builder)) NULL else unlist(strsplit(builder, ",\\s+"))
}

getVigEngine <- function(vignetteFile){
    lines <- readLines(vignetteFile, n=100L, warn=FALSE)
    idx <- grep(lines, pattern="VignetteEngine")
    if (length(idx) != 0){
        eng <- gsub("::.*", "", gsub(".*\\{|\\}.*", "", lines[idx]))
        return(eng)
    } else {
        return(NA)
    }
}

vigHelper <- function(vignetteFile, builder){
    eng <- getVigEngine(vignetteFile)
    if (all(is.na(eng))){
        return(NA)
    } else {
        return(all(eng %in% builder))
    }
}

getPkgType <- function(pkgdir)
{
    dcf <- read.dcf(file.path(pkgdir, "DESCRIPTION"))
    if (!"biocViews" %in% colnames(dcf))
    {
        return(NA)
    }
    biocViews <- dcf[, "biocViews"]
    views <- strsplit(gsub("\\s", "", biocViews), ",")[[1]]
    biocViewsVocab <- NULL ## to keep R CMD check happy
    data("biocViewsVocab", package="biocViews", envir=environment())
    if (any(!views %in% nodes(biocViewsVocab)))
        return(NA)
    parents <- c()
    for (view in views)
    {
        parents <- c(parents, getParent(view, biocViewsVocab))
    }
    u <- unique(parents)
    if (length(u)==1) return(u) else return(NA)
}

getParent <- function(view, biocViewsVocab)
{
    topLevel <- c("Software", "ExperimentData", "AnnotationData", "Workflow")
    if (view %in% topLevel)
        return(view)
    for (level in topLevel) {
        if (view %in% names(acc(biocViewsVocab, level)[[level]]))
            return(level)
    }
}

.checkEnv <- function(env, walker) {
    ## look at all closures in 'env' using codetools-derived 'walker'
    for (n in ls(env, all.names = TRUE)) {
        v <- get(n, envir = env)
        if (typeof(v) == "closure")
            walkCode(body(v), walker)
        else if (typeof(v) == "environment" && !walker$is_explored(v)) {
            walker$mark_exploration(v)
            .checkEnv(v, walker)
        }
    }
    walker
}

.colonWalker <- function() {
    ## record all pkg used as pkg::foo or pkg:::bar
    PKGS <- character()
    EXPLORED_ENVIRS <- character()
    collector <- function(e, w)
        PKGS <<- append(PKGS, as.character(e[[2]]))
    mark_exploration <- function(env)
        EXPLORED_ENVIRS <<- append(EXPLORED_ENVIRS, format(env))
    list(handler=function(v, w) {
        switch(v, "::"=collector, ":::"=collector, NULL)
    }, call=function(e, w) {
        for (ee in as.list(e)) if (!missing(ee)) walkCode(ee, w)
    }, leaf = function(e, w) {
        NULL
    }, done = function() {
        sort(unique(PKGS))
    }, is_explored = function(env) {
       format(env) %in% EXPLORED_ENVIRS
    }, mark_exploration = mark_exploration
    )
}

getFunctionLengths <- function(df)
{
    df <- df[df$terminal & df$parent > -1,]
    rownames(df) <- NULL
    max <- nrow(df)
    res <- list()
    funcRows <- df[df$token == "FUNCTION",]
    lst <- lapply(split(df, rownames(df)), as.list)
    if (nrow(funcRows))
    {
        for (i in seq_len(nrow(funcRows)))
        {
            funcRowId <- as.integer(rownames(funcRows)[i])
            funcRow <- funcRows[as.character(funcRowId),]
            funcStartLine <- funcRow$line1 # this might get updated later
            funcLines <- NULL
            funcName <- "_anonymous_"
            # attempt to get function name
            if (funcRowId >= 3)
            {
                up1 <- lst[[as.character(funcRowId -1)]]
                #up1 <- df[as.character(funcRowId - 1),]
                #up2 <- df[as.character(funcRowId - 2),]
                up2 <- lst[[as.character(funcRowId -2)]]
                if (up1$token %in% c("EQ_ASSIGN", "LEFT_ASSIGN") &&
                    up2$token == "SYMBOL")
                {
                    funcName <- up2$text
                    funcStartLine <- up2$line1
                }
            }
            j <- funcRowId + 1
            saveme <- NULL
            while (TRUE)
            {
                #thisRowId <- as.integer(rownames(df)[j])
                thisRowId <- j
                #thisRow <- df[thisRowId,]
                thisRow <- lst[[as.character(thisRowId)]]
                if (thisRowId == max || thisRow$parent > funcRow$parent)
                {
                    lineToExamine <- ifelse(thisRowId == max, max, saveme)

                    endLine <- lst[[as.character(lineToExamine)]]$line2
                    funcLines <- endLine - (funcStartLine -1)
                    if(funcName == "_anonymous_")
                        funcName <- paste0(funcName, ".", funcStartLine)
                    res[[funcName]] <- c(length=funcLines,
                        startLine=funcStartLine, endLine=endLine)
                    break
                } else {
                    if (thisRow$parent > 0)
                    {
                        saveme <- thisRowId
                    }
                }
                j <- j + 1
            }

        }
    } else {
       res <- list(as.data.frame(list(
           length = integer(0), startLine = integer(0), endLine = integer(0)
       )))
    }
    res
}

doesManPageHaveRunnableExample <- function(rd)
{
    hasExamples <- any(unlist(lapply(rd,
        function(x) attr(x, "Rd_tag") == "\\examples")))
    if (!hasExamples) return(FALSE)

    ex <- character()
    tc <- textConnection("ex", "w", local=TRUE)
    tools::Rd2ex(rd, commentDontrun = TRUE, commentDonttest = TRUE, out = tc)
    close(tc)

    if(!length(ex))
        return(FALSE)

    parsed <- try(parse(text = ex), silent = TRUE)

    # if code contains only comments the length with be 0
    length(parsed) && !inherits(parsed, "try-error")
}

selectSome <- function(obj, maxToShow = 5) {
    stopifnot(is.character(obj))
    if (!maxToShow %% 2)
        stop("'maxToShow' should be an odd value")
    edge <- (maxToShow - 1) / 2
    if (length(obj) > maxToShow)
        c(head(obj, edge), "...", tail(obj, edge))
    else
        obj
}
