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
max_size=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) body="$2"; shift 2 ;;
    --max-filesize) max_size="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s' "$body" > "$WORK/call.log"
printf '%s' "$max_size" > "$WORK/max-size.log"
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
grep -q '^2M$' "$work/max-size.log" || { echo "search response size limit missing"; exit 1; }

echo "== oversized search response is rejected by curl limit"
perl -e 'print "x" x (2 * 1024 * 1024 + 1)' > "$work/search.json"
if HOME="$work/home" "$helper" search oversized > "$work/oversized.json"; then
  grep -qx '\[\]' "$work/oversized.json" || { echo "oversized response was parsed"; exit 1; }
fi

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

echo "== preview fetches through the bounded helper and caches privately"
cat > "$work/fake-preview-curl" <<'EOF'
#!/usr/bin/env bash
out=""
all_args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'call\n' >> "$WORK/preview-calls.log"
printf '%s\n' "${all_args[*]}" >> "$WORK/preview-args.log"
if [[ -n "${PREVIEW_BODY:-}" ]]; then
  printf '%s' "$PREVIEW_BODY"
  exit 0
fi
if [[ -n "${PREVIEW_BYTES:-}" ]]; then
  head -c "$PREVIEW_BYTES" /dev/zero
  exit $?
fi
if [[ -n "$out" ]]; then
  cp "$WORK/preview.png" "$out"
else
  cat "$WORK/preview.png"
fi
EOF
chmod +x "$work/fake-preview-curl"
"$tool" -size 128x128 xc:blue png:"$work/preview.png"
export CURL_CMD="$work/fake-preview-curl"

preview_url="https://example.invalid/preview.png"
HOME="$work/home" "$helper" preview "$preview_url" > "$work/preview-path.txt"
preview_path="$(cat "$work/preview-path.txt")"
test -f "$preview_path" || { echo "preview file missing: $preview_path"; exit 1; }
[[ "$preview_path" == "$work/home/.cache/omarchy-dock/previews/"* ]] || { echo "preview outside cache: $preview_path"; exit 1; }
[[ "$(stat -c %a "$(dirname "$preview_path")")" == "700" ]] || { echo "preview dir not private"; exit 1; }
[[ "$(stat -c %a "$preview_path")" == "600" ]] || { echo "preview file not private"; exit 1; }
[[ "$(wc -l < "$work/preview-calls.log")" == "1" ]] || { echo "preview did not fetch exactly once"; exit 1; }
grep -q -- "--max-filesize 2M" "$work/preview-args.log" || { echo "preview transfer is not size-capped"; exit 1; }
grep -q -- "--max-time 15" "$work/preview-args.log" || { echo "preview transfer has no deadline"; exit 1; }

echo "== preview reuses the cached file without downloading again"
HOME="$work/home" "$helper" preview "$preview_url" > "$work/preview-again.txt"
[[ "$(cat "$work/preview-again.txt")" == "$preview_path" ]] || { echo "preview cache miss"; exit 1; }
[[ "$(wc -l < "$work/preview-calls.log")" == "1" ]] || { echo "cached preview downloaded again"; exit 1; }

echo "== preview rejects non-https URLs"
if HOME="$work/home" "$helper" preview "http://example.invalid/a.png" >/dev/null 2>&1; then
  echo "http preview URL accepted"; exit 1
fi

echo "== preview rejects oversized dimensions"
"$tool" -size 1024x1024 xc:red png:"$work/preview.png"
if HOME="$work/home" "$helper" preview "https://example.invalid/huge.png" >/dev/null 2>&1; then
  echo "oversized preview accepted"; exit 1
fi

echo "== preview rejects a body larger than the receive cap"
if PREVIEW_BYTES=3000000 HOME="$work/home" "$helper" preview "https://example.invalid/chunked.png" 2>"$work/big-preview.err"; then
  echo "oversized preview body accepted"; exit 1
fi
grep -q "preview download failed" "$work/big-preview.err" || {
  echo "oversized preview body was not stopped by the transfer cap"; cat "$work/big-preview.err"; exit 1
}

echo "== preview failures clean up their temporary files"
if PREVIEW_BODY="this is not an image" HOME="$work/home" "$helper" preview "https://example.invalid/broken.png" >/dev/null 2>&1; then
  echo "invalid preview accepted"; exit 1
fi
leftover="$(find "$work/home/.cache/omarchy-dock/previews" -maxdepth 1 -name '.?*' -print -quit)"
[[ -z "$leftover" ]] || { echo "preview left a temporary file: $leftover"; exit 1; }

echo "helper tests passed"
