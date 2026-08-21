#!/usr/bin/env bash
# Offline smoke tests for scripts/omarchy-dock-icon. Network access is faked
# through CURL_CMD; HOME is redirected so nothing touches the real config.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$root/scripts/omarchy-dock-icon"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/home"

# Fake curl: records the POST body and serves canned search JSON.
cat > "$work/fake-curl" <<'EOF'
#!/usr/bin/env bash
body=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) body="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$body" > "$WORK/call.log"
cat "$WORK/search.json"
EOF
chmod +x "$work/fake-curl"
export CURL_CMD="$work/fake-curl"
export WORK="$work"

cat > "$work/search.json" <<'EOF'
{"hits":[
  {"appName":"Figma","appSlug":"figma","objectID":"i3FsrkYvf6",
   "iOSUrl":"https://s3-new.macosicons.com/macosicons/parse/Figma_i3FsrkYvf6_iOS.png",
   "lowResPngUrl":"https://s3-new.macosicons.com/macosicons/parse/low_res_Figma_i3FsrkYvf6.png",
   "downloads":18},
  {"appName":"Orphan","appSlug":"orphan","objectID":"x","downloads":1}
]}
EOF

echo "== search filters hits and prints JSON"
HOME="$work/home" "$helper" search figma > "$work/out.json"
python3 - "$work/out.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert len(data) == 1, f"expected 1 hit with iOSUrl, got {data}"
hit = data[0]
assert hit["appName"] == "Figma", hit
assert hit["objectID"] == "i3FsrkYvf6", hit
assert hit["iOSUrl"].startswith("https://"), hit
assert hit["lowResPngUrl"], hit
PY
grep -q '"query": "figma"' "$work/call.log" || { echo "search body missing query"; exit 1; }

echo "== set --file downloads nothing but maps and rounds the icon"
if command -v magick >/dev/null; then tool="magick"; else tool="convert"; fi
"$tool" -size 64x64 xc:red png:"$work/icon.png"
HOME="$work/home" "$helper" set code --file "$work/icon.png"
test -f "$work/home/.config/omarchy/icons/code.png" || { echo "icon file missing"; exit 1; }
grep -q '"code"' "$work/home/.config/omarchy/dock-icons.json" || { echo "mapping missing"; exit 1; }

echo "== list reports the mapped icon"
cat > "$work/home/.config/omarchy/dock-pinned-macos.json" <<'EOF'
{"version":1,"pinned":["code"],"order":["code"]}
EOF
HOME="$work/home" "$helper" list | grep -q "^code: code.png$" || { echo "list output wrong"; exit 1; }

echo "== clear removes the mapping and the file"
HOME="$work/home" "$helper" clear code
! grep -q '"code"' "$work/home/.config/omarchy/dock-icons.json" || { echo "mapping not cleared"; exit 1; }
! test -f "$work/home/.config/omarchy/icons/code.png" || { echo "icon file not removed"; exit 1; }

echo "helper tests passed"