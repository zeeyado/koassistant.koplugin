#!/bin/bash
# Translation Progress Monitor for KOAssistant
# Run: watch -n 2 ./monitor_translations.sh
# Or:  while true; do clear; ./monitor_translations.sh; sleep 2; done

cd "$(dirname "$0")"
POT_STRINGS=$(grep -c '^msgid "' locale/koassistant.pot 2>/dev/null || echo 782)

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        KOAssistant Translation Progress Monitor              ║"
echo "║                    $(date '+%Y-%m-%d %H:%M:%S')                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║ %-8s │ %-10s │ %-8s │ %-8s │ %-10s ║\n" "Lang" "Status" "Fuzzy" "Trans" "Progress"
echo "╠══════════════════════════════════════════════════════════════╣"

for lang in ru ja pl tr ko_KR vi; do
  file="locale/$lang/LC_MESSAGES/koassistant.po"
  if [ -f "$file" ]; then
    # Get stats
    stats=$(msgfmt --statistics "$file" 2>&1)
    fuzzy=$(echo "$stats" | grep -oE '[0-9]+ fuzzy' | grep -oE '[0-9]+' || echo "0")
    trans=$(echo "$stats" | grep -oE '[0-9]+ translated' | grep -oE '[0-9]+' || echo "0")
    untrans=$(echo "$stats" | grep -oE '[0-9]+ untranslated' | grep -oE '[0-9]+' || echo "0")
    
    # Determine status
    if [ "$fuzzy" -gt 0 ] || [ "$trans" -gt 0 ]; then
      status="✅ Done"
      pct=$((100 * (fuzzy + trans) / POT_STRINGS))
    else
      status="⏳ Empty"
      pct=0
    fi
    
    # Progress bar
    filled=$((pct / 5))
    empty=$((20 - filled))
    bar=$(printf '%*s' "$filled" '' | tr ' ' '█')$(printf '%*s' "$empty" '' | tr ' ' '░')
    
    printf "║ %-8s │ %-10s │ %8s │ %8s │ %s %3d%% ║\n" "$lang" "$status" "$fuzzy" "$trans" "$bar" "$pct"
  else
    printf "║ %-8s │ %-10s │ %8s │ %8s │ %-15s ║\n" "$lang" "❌ Missing" "-" "-" "-"
  fi
done

echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Commands:"
echo "  watch -n 2 ./monitor_translations.sh    # Auto-refresh every 2s"
echo "  msgfmt -c locale/XX/LC_MESSAGES/koassistant.po  # Validate syntax"
