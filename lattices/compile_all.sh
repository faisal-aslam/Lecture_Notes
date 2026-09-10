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
# SPEED: full-course-notes.tex never reads the individual lectures' .aux
# files (its own comments note \ref resolves locally there); the per-lecture
# compiles in this script exist only to (a) catch a lecture that fails to
# compile at all, before wasting time on the combined book, and (b) leave a
# valid .aux behind for xr-hyper, for whichever OTHER lecture cross-references
# it. Neither purpose needs a second pdflatex pass, so by default this script
# runs each per-lecture compile with a single pass (compile_latex.sh -1).
# full-course-notes.tex itself still gets two passes -- its own table of
# contents and page-numbered cross-references genuinely need that.
#
# QUIET BY DEFAULT: pdflatex's console spew is suppressed; every lecture
# still gets its own full <name>.log on disk exactly as before (pdflatex
# writes that file unconditionally). Only short progress/timing lines go to
# the screen, and also to compile_all.log in this folder.
#
# Usage: ./compile_all.sh [-c|-t] [-v]
#   -c    Clean only (don't compile) -- removes aux/pdf/log for everything,
#         including full-course-notes.pdf
#   -t    Tidy only (don't compile) -- removes aux/log/out/toc for everything
#         and every per-lecture .pdf, but KEEPS full-course-notes.pdf
#   -v    Verbose: old behavior -- two full, unredirected pdflatex passes per
#         lecture, printed straight to the screen. Use this when actively
#         debugging a compile failure and you want to watch it happen live
#         instead of opening the relevant .log file.
#   -h    Show this help message

usage() {
    echo "Usage: $0 [-c|-t] [-v]"
    echo "  -c    Clean only (don't compile) -- removes aux/pdf/log for everything,"
    echo "        including full-course-notes.pdf"
    echo "  -t    Tidy only (don't compile) -- removes aux/log/out/toc for everything"
    echo "        and every per-lecture .pdf, but KEEPS full-course-notes.pdf"
    echo "  -v    Verbose -- two unredirected passes per lecture (old default)"
    echo "  -h    Show this help message"
    exit 1
}

MODE="build"
VERBOSE=0
while getopts "ctvh" opt; do
    case $opt in
        c) MODE="clean" ;;
        t) MODE="tidy" ;;
        v) VERBOSE=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND-1))

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPILE_ONE="${SCRIPT_DIR}/compile_latex.sh"
RUN_LOG="compile_all.log"

if [ ! -f "$COMPILE_ONE" ]; then
    echo "Error: compile_latex.sh not found next to this script (expected at ${COMPILE_ONE})"
    exit 1
fi

# Prints to both the screen and compile_all.log, so the overall run's
# narration (what ran, in what order, how long each step took, pass/fail)
# is always available afterward without re-running anything.
log() {
    echo "$@" | tee -a "$RUN_LOG"
}

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

if [ "$MODE" = "clean" ]; then
    echo "Found lecture files:"
    echo "$LECTURE_FILES" | sed 's/^/  - /'
    echo ""
    for f in $LECTURE_FILES; do
        bash "$COMPILE_ONE" -c "$f"
    done
    echo "Cleaning full-course-notes.tex auxiliary files too..."
    rm -f full-course-notes.aux full-course-notes.pdf full-course-notes.log \
          full-course-notes.out full-course-notes.synctex.gz full-course-notes.toc
    rm -f "$RUN_LOG"
    echo "All clean."
    exit 0
fi

if [ "$MODE" = "tidy" ]; then
    echo "Found lecture files:"
    echo "$LECTURE_FILES" | sed 's/^/  - /'
    echo ""
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

# --- Build mode ---
: > "$RUN_LOG"
SECONDS=0
log "=============================================="
log "compile_all.sh run started $(date)"
log "Mode: $([ $VERBOSE -eq 1 ] && echo 'verbose (two passes/lecture)' || echo 'quiet (one pass/lecture)')"
log "=============================================="
log "Found lecture files:"
echo "$LECTURE_FILES" | sed 's/^/  - /' | tee -a "$RUN_LOG"
log ""

TOTAL=$(echo "$LECTURE_FILES" | wc -l)
IDX=0
FAILED=()
for f in $LECTURE_FILES; do
    IDX=$((IDX+1))
    BASENAME=$(basename "$f" .tex)
    STEP_START=$SECONDS
    if [ $VERBOSE -eq 1 ]; then
        echo "=============================================="
        echo "Processing $f"
        echo "=============================================="
        bash "$COMPILE_ONE" "$f"
    else
        bash "$COMPILE_ONE" -1 -q "$f"
    fi
    STEP_TIME=$((SECONDS-STEP_START))
    if [ -f "${BASENAME}.pdf" ]; then
        log "[$IDX/$TOTAL] $f ... OK (${STEP_TIME}s)"
    else
        FAILED+=("$f")
        log "[$IDX/$TOTAL] $f ... FAILED (${STEP_TIME}s) -- see ${BASENAME}.log"
    fi
done
log ""

if [ ${#FAILED[@]} -ne 0 ]; then
    log "=============================================="
    log "The following lecture(s) failed to produce a PDF, so"
    log "full-course-notes.tex was NOT compiled:"
    for f in "${FAILED[@]}"; do log "  - $f"; done
    log "Check each failed lecture's own .log file for the actual LaTeX error,"
    log "or re-run with -v to watch a live, unredirected compile."
    log "=============================================="
    exit 1
fi

if [ -f full-course-notes.tex ]; then
    log "=============================================="
    log "All lectures compiled. Building full-course-notes.tex"
    log "=============================================="
    # Two passes: first pass writes the .toc/.aux (chapter titles,
    # section numbers, labels); second pass reads them back in so
    # the table of contents and any cross-references are correct.
    # This step is NOT shortened to one pass -- unlike the per-lecture
    # throwaway compiles above, this IS the deliverable, and its own
    # ToC/page-numbered refs genuinely need the second pass to be correct.
    FC_START=$SECONDS
    if [ $VERBOSE -eq 1 ]; then
        pdflatex -interaction=nonstopmode full-course-notes.tex
        pdflatex -interaction=nonstopmode full-course-notes.tex
    else
        pdflatex -interaction=nonstopmode full-course-notes.tex > /dev/null
        pdflatex -interaction=nonstopmode full-course-notes.tex > /dev/null
    fi
    FC_TIME=$((SECONDS-FC_START))

    if [ -f full-course-notes.pdf ]; then
        log "Done! Combined output: full-course-notes.pdf (${FC_TIME}s)"
        log "Removing individual lecture PDFs (keeping only full-course-notes.pdf)..."
        for f in $LECTURE_FILES; do
            BASENAME=$(basename "$f" .tex)
            rm -f "${BASENAME}.pdf"
            log "  - removed ${BASENAME}.pdf"
        done
    else
        log "Warning: full-course-notes.pdf was not produced -- check full-course-notes.log."
        log "Individual lecture PDFs were kept so you still have something to inspect."
        exit 1
    fi
else
    log "Note: full-course-notes.tex not found in $(pwd), skipping the combined build."
fi

log "=============================================="
log "Total time: ${SECONDS}s. Full run narration: ${RUN_LOG}"
log "=============================================="
