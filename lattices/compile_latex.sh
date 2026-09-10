#!/bin/bash
# Usage function
usage() {
    echo "Usage: $0 [-c] [-1] [-q] filename.tex"
    echo "  -c    Clean only (don't compile)"
    echo "  -1    Single pass only (default: two passes). Intended for callers"
    echo "        (like compile_all.sh) that only need this file's .aux to exist"
    echo "        for xr-hyper cross-referencing, not a polished standalone PDF."
    echo "        With only one pass, this file's own table of contents and any"
    echo "        forward references to sections defined later in the SAME file"
    echo "        may show as '??' -- expected and harmless when the PDF itself"
    echo "        is throwaway."
    echo "  -q    Quiet: suppress pdflatex's console spew. A full log is written"
    echo "        to <filename>.log regardless -- pdflatex always writes that"
    echo "        file on its own; -q only silences the terminal copy of it."
    echo "  -h    Show this help message"
    exit 1
}
# Parse options
CLEAN_ONLY=0
SINGLE_PASS=0
QUIET=0
while getopts "c1qh" opt; do
    case $opt in
        c) CLEAN_ONLY=1 ;;
        1) SINGLE_PASS=1 ;;
        q) QUIET=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))
# Check if filename is provided
if [ -z "$1" ]; then
    echo "Error: No LaTeX file provided"
    usage
fi
# Check if file exists
if [ ! -f "$1" ]; then
    echo "Error: File '$1' not found"
    exit 1
fi
# Get the filename without extension
BASENAME=$(basename "$1" .tex)

# Clean ONLY this file's own auxiliary files/PDF — not every PDF in the
# folder. Files like full-course-notes.tex depend on other lectures'
# already-compiled PDFs (via \includepdf), so a blanket "rm -f *.pdf"
# deletes them out from under it before it can use them.
if [ $QUIET -eq 0 ]; then echo "Cleaning auxiliary files for ${BASENAME}..."; fi
rm -f "${BASENAME}".aux "${BASENAME}".pdf "${BASENAME}".log "${BASENAME}".lof \
      "${BASENAME}".lot "${BASENAME}".toc "${BASENAME}".out "${BASENAME}".synctex.gz \
      "${BASENAME}".bbl "${BASENAME}".blg "${BASENAME}".lol "${BASENAME}".nav \
      "${BASENAME}".snm "${BASENAME}".vrb

# Exit if clean only
if [ $CLEAN_ONLY -eq 1 ]; then
    if [ $QUIET -eq 0 ]; then echo "Clean completed. Exiting."; fi
    exit 0
fi

# pdflatex always writes a complete ${BASENAME}.log file on disk, regardless
# of what happens to its console output -- so redirecting that console copy
# to /dev/null in quiet mode loses nothing; every warning/error is still in
# the .log file afterward, exactly as if -q had not been passed.
run_pass() {
    if [ $QUIET -eq 1 ]; then
        pdflatex -interaction=nonstopmode "$1" > /dev/null
    else
        pdflatex -interaction=nonstopmode "$1"
    fi
}

if [ $SINGLE_PASS -eq 1 ]; then
    if [ $QUIET -eq 0 ]; then echo "Compiling $1 (single pass)..."; fi
    run_pass "$1"
else
    if [ $QUIET -eq 0 ]; then echo "Compiling $1 (first pass)..."; fi
    run_pass "$1"
    if [ $QUIET -eq 0 ]; then echo "Compiling $1 (second pass)..."; fi
    run_pass "$1"
fi

if [ $QUIET -eq 0 ]; then
    if [ -f "${BASENAME}.pdf" ]; then
        echo "Done! Output file: ${BASENAME}.pdf"
    else
        echo "Failed -- no ${BASENAME}.pdf produced. See ${BASENAME}.log for details."
    fi
fi

# Exit non-zero whenever no PDF resulted, in addition to printing the
# message above, so callers (compile_all.sh, or a script of your own)
# can rely on the exit code even when -q suppresses everything else.
[ -f "${BASENAME}.pdf" ] || exit 1
exit 0
