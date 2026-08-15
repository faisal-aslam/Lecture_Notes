#!/bin/bash
# Compiles a single .tex file with pdflatex (two passes, so cross-references,
# the table of contents, and running headers all resolve correctly), or
# cleans up that file's build artifacts.
#
# Usage: ./compile_latex.sh [-c] file.tex
#   -c    Clean only (removes .aux/.log/.out/.toc/.synctex.gz/.pdf for this file)
#   -h    Show this help message

usage() {
    echo "Usage: $0 [-c] file.tex"
    echo "  -c    Clean only (don't compile)"
    echo "  -h    Show this help message"
    exit 1
}

CLEAN_ONLY=0
while getopts "ch" opt; do
    case $opt in
        c) CLEAN_ONLY=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

if [ -z "$1" ]; then
    usage
fi

TEXFILE="$1"
DIR="$(cd "$(dirname "$TEXFILE")" && pwd)"
BASENAME="$(basename "$TEXFILE" .tex)"

cd "$DIR" || { echo "Error: cannot cd into $DIR"; exit 1; }

if [ $CLEAN_ONLY -eq 1 ]; then
    rm -f "${BASENAME}.aux" "${BASENAME}.log" "${BASENAME}.out" \
          "${BASENAME}.toc" "${BASENAME}.synctex.gz" "${BASENAME}.pdf" \
          "${BASENAME}.compile.log"
    echo "Cleaned ${BASENAME}.*"
    exit 0
fi

if [ ! -f "${BASENAME}.tex" ]; then
    echo "Error: ${BASENAME}.tex not found in ${DIR}"
    exit 1
fi

LOGFILE="${BASENAME}.compile.log"
rm -f "$LOGFILE"

echo "  [1/2] pdflatex ${BASENAME}.tex ..."
pdflatex -interaction=nonstopmode -halt-on-error "${BASENAME}.tex" >> "$LOGFILE" 2>&1
PASS1_STATUS=$?

if [ $PASS1_STATUS -ne 0 ]; then
    echo "  FAILED on pass 1 -- last 40 lines of ${LOGFILE}:"
    tail -n 40 "$LOGFILE"
    exit 1
fi

echo "  [2/2] pdflatex ${BASENAME}.tex (resolving references) ..."
pdflatex -interaction=nonstopmode -halt-on-error "${BASENAME}.tex" >> "$LOGFILE" 2>&1
PASS2_STATUS=$?

if [ $PASS2_STATUS -ne 0 ] || [ ! -f "${BASENAME}.pdf" ]; then
    echo "  FAILED on pass 2 -- last 40 lines of ${LOGFILE}:"
    tail -n 40 "$LOGFILE"
    exit 1
fi

if grep -qiE "overfull \\\\hbox" "$LOGFILE"; then
    echo "  OK: ${BASENAME}.pdf  (note: overfull hbox warnings in ${LOGFILE}, check layout)"
else
    echo "  OK: ${BASENAME}.pdf"
fi
exit 0
