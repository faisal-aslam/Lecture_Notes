#!/bin/bash
# Compiles every lectureN-*.tex file in this folder (auto-discovered,
# no filenames to type), in natural numeric order (lecture2 before
# lecture10), using compile_latex.sh for each one. Then, if all of
# them succeeded, compiles full-course-notes.tex to produce the
# combined PDF.
#
# Usage: ./compile_all.sh [-c]
#   -c    Clean only (removes aux/pdf for every lecture + the combined notes)
#   -h    Show this help message

usage() {
    echo "Usage: $0 [-c]"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPILE_ONE="${SCRIPT_DIR}/compile_latex.sh"

if [ ! -f "$COMPILE_ONE" ]; then
    echo "Error: compile_latex.sh not found next to this script (expected at ${COMPILE_ONE})"
    exit 1
fi

# Auto-discover all lectureN-*.tex files (e.g. lecture1-math-foundations.tex,
# lecture2-lwe-foundations.tex, ...), sorted in natural numeric order so
# lecture2 always comes before lecture10. full-course-notes.tex itself is
# excluded on purpose -- it's handled separately at the end.
LECTURE_FILES=$(ls lecture[0-9]*-*.tex 2>/dev/null | sort -V)

if [ -z "$LECTURE_FILES" ]; then
    echo "Error: no lectureN-*.tex files found in $(pwd)"
    exit 1
fi

echo "Found lecture files:"
echo "$LECTURE_FILES" | sed 's/^/  - /'
echo ""

if [ $CLEAN_ONLY -eq 1 ]; then
    for f in $LECTURE_FILES; do
        bash "$COMPILE_ONE" -c "$f"
    done
    echo "Cleaning full-course-notes.tex auxiliary files too..."
    rm -f full-course-notes.aux full-course-notes.pdf full-course-notes.log \
          full-course-notes.out full-course-notes.synctex.gz
    echo "All clean."
    exit 0
fi

FAILED=()
for f in $LECTURE_FILES; do
    echo "=============================================="
    echo "Processing $f"
    echo "=============================================="
    bash "$COMPILE_ONE" "$f"
    BASENAME=$(basename "$f" .tex)
    if [ ! -f "${BASENAME}.pdf" ]; then
        FAILED+=("$f")
    fi
    echo ""
done

if [ ${#FAILED[@]} -ne 0 ]; then
    echo "=============================================="
    echo "The following lecture(s) failed to produce a PDF, so"
    echo "full-course-notes.tex was NOT compiled:"
    printf '  - %s\n' "${FAILED[@]}"
    echo "=============================================="
    exit 1
fi

if [ -f full-course-notes.tex ]; then
    echo "=============================================="
    echo "All lectures compiled. Building full-course-notes.tex"
    echo "=============================================="
    # Two passes: first pass writes the .toc/.aux (chapter titles,
    # section numbers, labels); second pass reads them back in so
    # the table of contents and any cross-references are correct.
    pdflatex -interaction=nonstopmode full-course-notes.tex
    pdflatex -interaction=nonstopmode full-course-notes.tex
    echo "Done! Combined output: full-course-notes.pdf"
else
    echo "Note: full-course-notes.tex not found in $(pwd), skipping the combined build."
fi
