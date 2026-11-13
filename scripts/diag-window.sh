#!/bin/bash
# Bounded diagnosis of "Wine runs but shows no window" on the Mac.
# Starts one Wine program through the launcher with a trace, and for up to
# SECS seconds records every 10 s which Wine processes exist and which windows
# they own (on any Space, on screen or not). Then stops Wine and prints a summary.
# Usage: bash diag-window.sh [program] [secs]      (default: notepad 150)
set -uo pipefail
PROG="${1:-notepad}"
SECS="${2:-150}"
SKYH="${SKYWALKER_HOME:-$HOME/Games/skywalker}"
SKY="$SKYH/skywalker.sh"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$SKYH/logs/diag-$STAMP"
mkdir -p "$OUT"
REPORT="$OUT/report.txt"
WINES="$SKYH/wine/"

procs() {
  /bin/ps -x -o pid=,etime=,%cpu=,command= | /usr/bin/awk -v w="$WINES" '{
    line = $0; rest = $0; sub(/^ *[0-9]+ +[^ ]+ +[^ ]+ +/, "", rest)
    if (rest ~ /^[A-Za-z]:\\/ || index(rest, w) == 1) print line }'
}

cat > "$OUT/windows.js" <<'JS'
function run(argv) {
  ObjC.import('CoreGraphics');
  var want = {};
  argv[0].split(',').forEach(function (p) { if (p) want[p] = true; });
  var ref = $.CGWindowListCopyWindowInfo(0, 0);   // all windows, any Space
  var list = ObjC.deepUnwrap(ObjC.castRefToObject(ref)) || [];
  var out = [];
  list.forEach(function (w) {
    if (!want[String(w.kCGWindowOwnerPID)]) return;
    var b = w.kCGWindowBounds || {};
    out.push(['pid ' + w.kCGWindowOwnerPID, Math.round(b.X) + ',' + Math.round(b.Y),
      Math.round(b.Width) + 'x' + Math.round(b.Height), 'layer ' + w.kCGWindowLayer,
      'onscreen ' + (w.kCGWindowIsOnscreen ? 1 : 0), 'alpha ' + w.kCGWindowAlpha,
      w.kCGWindowOwnerName || '?', w.kCGWindowName || ''].join('  '));
  });
  return out.join('\n');
}
JS

{
  echo "diag $STAMP: $PROG for up to ${SECS}s"
  sw_vers 2>/dev/null | tr '\n' ' '; echo
  bash "$SKY" doctor 2>&1 | grep -E 'Build in use|Graphics|Wine running|Processes'
} > "$REPORT"

if [ -n "$(procs)" ]; then
  echo "Wine is already running; stopping it first" | tee -a "$REPORT"
  bash "$SKY" stop >/dev/null 2>&1
fi

# The launcher's "wine" command applies its settings, watchdog and process limit.
WINEDEBUG="err+all,warn+macdrv,warn+winediag,fixme-all" \
  bash "$SKY" wine "$PROG" > "$OUT/wine.log" 2>&1 &
wpid=$!

seen=""
t=0
while [ "$t" -lt "$SECS" ]; do
  sleep 10; t=$((t + 10))
  p="$(procs)"
  pids="$(echo "$p" | awk '{print $1}' | tr '\n' ',')"
  w=""
  [ -n "$pids" ] && w="$(/usr/bin/osascript -l JavaScript "$OUT/windows.js" "$pids" 2>&1)"
  {
    echo "--- ${t}s: $(echo "$p" | grep -c . ) Wine processes"
    echo "$p" | sed 's/^/  /'
    echo "  windows:"
    echo "${w:-  (none)}" | sed 's/^/    /'
  } >> "$REPORT"
  if [ -z "$seen" ] && echo "$w" | grep -q 'onscreen 1'; then seen="$t"; fi
  if [ -n "$seen" ] && [ "$t" -ge $((seen + 20)) ]; then break; fi
  if ! kill -0 "$wpid" 2>/dev/null && [ -z "$p" ]; then echo "Wine exited by itself at ${t}s" >> "$REPORT"; break; fi
done

bash "$SKY" stop >/dev/null 2>&1
kill "$wpid" 2>/dev/null
sleep 3
{
  echo "--- after stop: $(procs | grep -c .) Wine processes"
  echo "--- first on-screen window at: ${seen:-never}s"
  echo "--- last 40 lines of Wine's log:"
  tail -n 40 "$OUT/wine.log"
} >> "$REPORT"

echo
echo "First window on screen: ${seen:-never}"
echo "Full report: $REPORT"
if /usr/bin/pbcopy < "$REPORT" 2>/dev/null; then echo "The report is on your clipboard: paste it into the chat."; fi
