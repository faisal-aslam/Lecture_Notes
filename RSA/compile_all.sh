#!/bin/bash
# Compiles every lectureN-*.tex file in this folder (auto-discovered,
# no filenames to type), in natural numeric order (lecture2 before
# lecture10), using compile_latex.sh for each one. Then, if all of
# them succeeded, compiles full-course-notes.tex to produce the
# combined PDF.
#
# On a normal successful run, the individual lectureN-*.pdf files are
# deleted automatically once full-course-notes.pdf exists -- the combined
# book is the only PDF meant to be kept around (e.g. for a git repo).
# Auxiliary files (.aux/.log/.out/.toc/.synctex.gz) are left in place after
# a normal run, since they're handy for debugging a compile; use -t to
# strip those too, right before a git commit.
#
# Usage: ./compile_all.sh [-c|-t]
#   -c    Clean only (don't compile) -- removes aux/pdf/log for every
#         lecture AND for full-course-notes.tex (nukes every PDF,
#         including the combined one -- use this to force a from-scratch
#         rebuild, not before a commit).
#   -t    Tidy only (don't compile) -- removes .aux/.log/.out/.toc/
#         .synctex.gz for everything, and deletes every per-lecture
#         .pdf, but KEEPS full-course-notes.pdf. Run this right before
#         `git commit` / `git add .` so only source files and the one
#         combined PDF are left in the working tree.
#   -h    Show this help message

usage() {
    echo "Usage: $0 [-c|-t]"
    echo "  -c    Clean only (don't compile) -- removes aux/pdf/log for everything,"
    echo "        including full-course-notes.pdf"
    echo "  -t    Tidy only (don't compile) -- removes aux/log/out/toc for everything"
    echo "        and every per-lecture .pdf, but KEEPS full-course-notes.pdf"
    echo "  -h    Show this help message"
    exit 1
}

MODE="build"
while getopts "cth" opt; do
    case $opt in
        c) MODE="clean" ;;
        t) MODE="tidy" ;;
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
# lecture2 always comes before lecture10. Excludes two kinds of files that
# match the same naming pattern but are NOT standalone compilable documents:
#   - lectureN-*-body.tex: the actual content, \input by both the standalone
#     shell below AND full-course-notes.tex. Living flat (not in a content/
#     subfolder) makes downloading the project as a single zip work without
#     any manual folder reassembly -- but it means this glob must explicitly
#     skip them, since "lectureN-*-body.tex" also matches "lecture[0-9]*-*.tex".
#   - full-course-notes.tex itself -- handled separately at the end.
LECTURE_FILES=$(ls lecture[0-9]*-*.tex 2>/dev/null | grep -v -- '-body\.tex$' | sort -V)

if [ -z "$LECTURE_FILES" ]; then
    echo "Error: no lectureN-*.tex files found in $(pwd)"
    exit 1
fi

echo "Found lecture files:"
echo "$LECTURE_FILES" | sed 's/^/  - /'
echo ""

if [ "$MODE" = "clean" ]; then
    for f in $LECTURE_FILES; do
        bash "$COMPILE_ONE" -c "$f"
    done
    echo "Cleaning full-course-notes.tex auxiliary files too..."
    rm -f full-course-notes.aux full-course-notes.pdf full-course-notes.log \
          full-course-notes.out full-course-notes.synctex.gz
    echo "All clean."
    exit 0
fi

if [ "$MODE" = "tidy" ]; then
    echo "Tidying build artifacts (keeping full-course-notes.pdf and all .tex/.sh sources)..."
    for f in $LECTURE_FILES; do
        BASENAME=$(basename "$f" .tex)
        rm -f "${BASENAME}".aux "${BASENAME}".pdf "${BASENAME}".log "${BASENAME}".lof \
              "${BASENAME}".lot "${BASENAME}".toc "${BASENAME}".out "${BASENAME}".synctex.gz \
              "${BASENAME}".bbl "${BASENAME}".blg "${BASENAME}".lol "${BASENAME}".nav \
              "${BASENAME}".snm "${BASENAME}".vrb
        echo "  - removed ${BASENAME}.pdf and its aux/log files"
    done
    rm -f full-course-notes.aux full-course-notes.log full-course-notes.out \
          full-course-notes.toc full-course-notes.synctex.gz
    echo "  - removed full-course-notes.aux/.log/.out/.toc (kept full-course-notes.pdf)"
    echo "Done. Working tree now has only source files and full-course-notes.pdf."
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

    if [ -f full-course-notes.pdf ]; then
        echo "Done! Combined output: full-course-notes.pdf"
        echo "Removing individual lecture PDFs (keeping only full-course-notes.pdf)..."
        for f in $LECTURE_FILES; do
            BASENAME=$(basename "$f" .tex)
            rm -f "${BASENAME}.pdf"
            echo "  - removed ${BASENAME}.pdf"
        done
    else
        echo "Warning: full-course-notes.pdf was not produced -- check the log above."
        echo "Individual lecture PDFs were kept so you still have something to inspect."
        exit 1
    fi
else
    echo "Note: full-course-notes.tex not found in $(pwd), skipping the combined build."
fi
