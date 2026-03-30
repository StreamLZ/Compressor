#!/bin/bash
# Run each fuzz level in its own process. If one crashes, report which level
# and the watermark file shows the exact iteration.
set -e

cd "$(dirname "$0")"

echo "Building..."
dotnet build src/StreamLZ.Tests -c Release -v quiet 2>&1

WATERMARK="$TEMP/slz-fuzz-watermark.txt"
rm -f "$WATERMARK"

FAILED=0
for LEVEL in 1 5 6 9; do
    echo ""
    echo "========================================="
    echo "  Level $LEVEL — starting $(date +%H:%M:%S)"
    echo "========================================="

    rm -f "$WATERMARK"

    dotnet test src/StreamLZ.Tests -c Release --no-build \
        --filter "FullyQualifiedName~FuzzHarnessTests.FuzzHarness_Level$LEVEL" \
        2>&1
    EXIT_CODE=$?

    if [ $EXIT_CODE -eq 0 ]; then
        echo "  Level $LEVEL: PASSED $(date +%H:%M:%S)"
    else
        echo ""
        echo "  *** Level $LEVEL: CRASHED (exit code $EXIT_CODE) ***"
        if [ -f "$WATERMARK" ]; then
            CRASH_ITER=$(cat "$WATERMARK")
            echo "  Watermark: $CRASH_ITER"
            cp "$WATERMARK" "$CRASH_DIR/L${LEVEL}_crash_watermark.txt" 2>/dev/null
        else
            echo "  No watermark file found"
        fi
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "========================================="
if [ $FAILED -eq 0 ]; then
    echo "  ALL LEVELS PASSED"
else
    echo "  $FAILED LEVEL(S) CRASHED"
fi
echo "========================================="
exit $FAILED
