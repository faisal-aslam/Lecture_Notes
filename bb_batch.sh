#!/bin/bash

# -------------------------------------------------------
# Configuration - Edit these defaults as needed
# -------------------------------------------------------
CROP_FILTER="crop=2880:1619:480:420"           # Crop filter
SCALE_FILTER="scale=3840:2160:flags=bicubic"   # Scale filter
# Set to empty string to disable either filter:
# CROP_FILTER=""
# SCALE_FILTER=""
# -------------------------------------------------------

# Usage:
#   Trim:
#     ./video_tool.sh trim input.mp4 output.mp4 5 3
#     ./video_tool.sh trim input.mp4 output.mp4 00:10 00:05
#
#   Concat:
#     ./video_tool.sh concat output.mp4 file1.mp4 file2.mp4 file3.mp4 ...
# -------------------------------------------------------

if [ "$1" == "trim" ]; then
    if [ $# -ne 5 ]; then
        echo "Usage: $0 trim <input> <output> <cut_start> <cut_end>"
        echo ""
        echo "Examples:"
        echo "  $0 trim input.mp4 output.mp4 5 3"
        echo "  $0 trim input.mp4 output.mp4 00:10 00:05"
        exit 1
    fi
    
    INPUT="$2"
    OUTPUT="$3"
    CUT_START="$4"
    CUT_END="$5"

    # Get duration
    DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT")

    # Convert mm:ss to seconds
    to_seconds() {
        if [[ "$1" =~ ^[0-9]+:[0-9]+$ ]]; then
            IFS=":" read -r m s <<< "$1"
            echo "$((m * 60 + s))"
        else
            echo "$1"
        fi
    }

    CUT_START_S=$(to_seconds "$CUT_START")
    CUT_END_S=$(to_seconds "$CUT_END")

    # Compute final duration
    DUR_FINAL=$(echo "$DURATION - $CUT_START_S - $CUT_END_S" | bc)

    if (( $(echo "$DUR_FINAL <= 0" | bc -l) )); then
        echo "Error: Final duration becomes zero or negative!"
        exit 1
    fi

    echo "Trimming video from ${CUT_START_S}s (removing ${CUT_END_S}s from end)..."
    echo "Final duration: ${DUR_FINAL}s"
    
    # Build the video filter string
    FILTERS=()
    [ -n "$CROP_FILTER" ] && FILTERS+=("$CROP_FILTER")
    [ -n "$SCALE_FILTER" ] && FILTERS+=("$SCALE_FILTER")
    
    if [ ${#FILTERS[@]} -gt 0 ]; then
        VF=$(IFS=,; echo "${FILTERS[*]}")
        echo "Applying filters: $VF"
        ffmpeg -ss "$CUT_START_S" -i "$INPUT" \
            -t "$DUR_FINAL" \
            -vf "$VF" \
            -c:v libx264 -crf 18 -preset fast -profile:v high \
            -c:a copy \
            "$OUTPUT"
    else
        echo "No filters applied"
        ffmpeg -ss "$CUT_START_S" -i "$INPUT" \
            -t "$DUR_FINAL" \
            -c:v libx264 -crf 18 -preset fast -profile:v high \
            -c:a copy \
            "$OUTPUT"
    fi

    if [ $? -eq 0 ]; then
        echo "Done. Output saved to: $OUTPUT"
    else
        echo "Error: Processing failed!"
        exit 1
    fi
    exit 0
fi

# -------------------------
# CONCAT MODE
# -------------------------
if [ "$1" == "concat" ]; then
    if [ $# -lt 4 ]; then
        echo "Usage: $0 concat <output> <file1> <file2> [file3 ...]"
        exit 1
    fi

    OUTPUT="$2"
    shift 2

    # Create a temporary concat file list
    LISTFILE=$(mktemp)

    for f in "$@"; do
        echo "file '$(realpath "$f")'" >> "$LISTFILE"
    done

    echo "Combining videos..."
    ffmpeg -f concat -safe 0 -i "$LISTFILE" -c:v libx264 -crf 18 -preset fast -profile:v high -c:a copy "$OUTPUT"

    rm "$LISTFILE"
    echo "Done."
    exit 0
fi

echo "Unknown mode. Use either:"
echo "  trim    — to cut start/end (always applies crop & scale)"
echo "  concat  — to combine files"
exit 1
