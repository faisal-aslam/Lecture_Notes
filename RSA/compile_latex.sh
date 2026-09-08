#!/bin/bash
# Usage function
usage() {
    echo "Usage: $0 [-c] filename.tex"
    echo "  -c    Clean only (don't compile)"
    echo "  -h    Show this help message"
    exit 1
}
# Parse options
CLEAN_ONLY=0
while getopts "ch" opt; do
    case $opt in
        c) CLEAN_ONLY=1 ;;
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
echo "Cleaning auxiliary files for ${BASENAME}..."
rm -f "${BASENAME}".aux "${BASENAME}".pdf "${BASENAME}".log "${BASENAME}".lof \
      "${BASENAME}".lot "${BASENAME}".toc "${BASENAME}".out "${BASENAME}".synctex.gz \
      "${BASENAME}".bbl "${BASENAME}".blg "${BASENAME}".lol "${BASENAME}".nav \
      "${BASENAME}".snm "${BASENAME}".vrb

# Exit if clean only
if [ $CLEAN_ONLY -eq 1 ]; then
    echo "Clean completed. Exiting."
    exit 0
fi
# Three passes: this project uses xr-hyper for cross-lecture \ref's plus
# ordinary forward/backward \ref's within a single lecture, and on a cold
# build (no .aux yet) that combination can need one pass more than the
# usual LaTeX "compile twice" rule of thumb to fully settle. A 3rd pass
# is cheap and guarantees every \ref/\label is resolved rather than
# leaving an occasional "??" in the PDF after a from-scratch build.
echo "Compiling $1 (pass 1/3)..."
pdflatex -interaction=nonstopmode "$1"
echo "Compiling $1 (pass 2/3)..."
pdflatex -interaction=nonstopmode "$1"
echo "Compiling $1 (pass 3/3)..."
pdflatex -interaction=nonstopmode "$1"
echo "Done! Output file: ${BASENAME}.pdf"
