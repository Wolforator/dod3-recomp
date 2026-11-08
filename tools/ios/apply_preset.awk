# apply_preset.awk -v preset=<preset.ini> <dod3.ini>: dod3.ini with the
# preset's KEY = VALUE lines set -- in place where the file sets the key,
# else added at the end with the preset's comments (tools/ios/package_ipa.sh;
# the app does the same for an older install, src/os/ios/setup_ios.mm).
function key(l,   k) { if (l ~ /^[ \t]*[#;]/ || l !~ /=/) return ""; k = l; sub(/=.*/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", k); return k }
BEGIN { while ((getline l < preset) > 0) { pl[++np] = l; k = key(l); if (k != "") val[k] = l } }
{ k = key($0); if (k in val) { if (!(k in done)) print val[k]; done[k] = 1; next } print }
END { print ""; for (i = 1; i <= np; i++) { k = key(pl[i]); if (k == "" || !(k in done)) print pl[i] } }
