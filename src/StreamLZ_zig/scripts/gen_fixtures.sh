#!/usr/bin/env bash
# Generate the Phase 8 fixture corpus.
#
# Output: c:/tmp/fixtures/{raw,slz}/<shape>_<size>[_L<level>].{raw,slz}
#
# Matrix:
#   shapes: text, binary, repetitive, mixed       (4)
#   sizes:  4k, 64k, 256k, 1m, 4m                 (5)
#   levels: 1 3 5 6 8 9 11                        (7)
# = 20 raw files, 140 slz files, 160 total.
#
# Re-runnable; skips files that already exist.

set -euo pipefail

FIX="c:/tmp/fixtures"
RAW="$FIX/raw"
SLZ="$FIX/slz"
SLZEXE="c:/Users/james.JAMESWORK2025/Repos/StreamLZ/src/StreamLZ.Cli/bin/Release/net10.0/win-x64/slz.exe"
ENWIK8="c:/Users/james.JAMESWORK2025/Repos/StreamLZ/assets/enwik8.txt"
SILESIA="c:/Users/james.JAMESWORK2025/Repos/StreamLZ/assets/silesia_all.tar"

mkdir -p "$RAW" "$SLZ"

if [[ ! -x "$SLZEXE" ]]; then
    echo "error: StreamLZ.Cli binary not found at $SLZEXE" >&2
    exit 1
fi
if [[ ! -f "$ENWIK8" ]]; then
    echo "error: enwik8.txt not found at $ENWIK8" >&2
    exit 1
fi
if [[ ! -f "$SILESIA" ]]; then
    echo "error: silesia_all.tar not found at $SILESIA" >&2
    exit 1
fi

declare -A SIZES=(
    [4k]=4096
    [64k]=65536
    [256k]=262144
    [1m]=1048576
    [4m]=4194304
)

LEVELS="1 3 5 6 8 9 11"

# -------- raw generators ----------------------------------------------------

gen_text() {
    local out="$1" bytes="$2"
    [[ -f "$out" ]] && return 0
    head -c "$bytes" "$ENWIK8" > "$out"
}

gen_binary() {
    local out="$1" bytes="$2"
    [[ -f "$out" ]] && return 0
    # Use silesia tar as a binary-ish source. Start 1 MiB in to skip the
    # zero-padded tar header region which compresses way too well.
    local skip=1048576
    dd if="$SILESIA" bs=1 skip="$skip" count="$bytes" of="$out" status=none
}

gen_repetitive() {
    local out="$1" bytes="$2"
    [[ -f "$out" ]] && return 0
    # A 38-byte pattern so it's not literally one byte but still very
    # match-heavy. Perl is universally available on Git Bash.
    perl -e '
my $p = "The quick brown fox jumps over a lazy ";
my $n = $ARGV[0];
my $copies = int($n / length($p)) + 1;
my $buf = $p x $copies;
print substr($buf, 0, $n);
' "$bytes" > "$out"
}

gen_mixed() {
    local out="$1" bytes="$2"
    [[ -f "$out" ]] && return 0
    # Half text, half binary — tests codec transition on block boundary.
    local half=$((bytes / 2))
    local rest=$((bytes - half))
    head -c "$half" "$ENWIK8" > "$out"
    dd if="$SILESIA" bs=1 skip=1048576 count="$rest" status=none >> "$out"
}

# -------- generate raws -----------------------------------------------------

echo "== generating raw inputs =="
for size_name in "${!SIZES[@]}"; do
    bytes=${SIZES[$size_name]}
    gen_text        "$RAW/text_${size_name}.raw"        "$bytes"
    gen_binary      "$RAW/binary_${size_name}.raw"      "$bytes"
    gen_repetitive  "$RAW/repetitive_${size_name}.raw"  "$bytes"
    gen_mixed       "$RAW/mixed_${size_name}.raw"       "$bytes"
    echo "  $size_name ($bytes bytes): text / binary / repetitive / mixed"
done

# -------- compress ----------------------------------------------------------

echo "== compressing =="
total=0
skipped=0
for raw in "$RAW"/*.raw; do
    base=$(basename "$raw" .raw)
    for L in $LEVELS; do
        out="$SLZ/${base}_L${L}.slz"
        total=$((total + 1))
        if [[ -f "$out" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        "$SLZEXE" -c -l "$L" -o "$out" "$raw" > /dev/null
    done
done

new=$((total - skipped))
echo "== done =="
echo "  total fixtures: $total"
echo "  newly generated: $new"
echo "  skipped (cached): $skipped"
ls "$SLZ" | wc -l | awk '{print "  files in $SLZ dir: " $1}'
