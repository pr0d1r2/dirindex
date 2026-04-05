#!/usr/bin/env bash
set -euo pipefail

# dirindex - Video directory indexer with thumbnail navigation
# Scans for videos, generates per-minute thumbnails, creates index.html per directory
# Serves on 0.0.0.0:6969 for LAN access
#
# Requirements: ffmpeg, ffprobe, python3 (all available on macOS)
# Install ffmpeg: brew install ffmpeg

PORT="${DIRINDEX_PORT:-6969}"
THUMB_DIR=".thumbs"
VIDEO_EXTENSIONS="mp4|mkv|avi|mov|webm|m4v|flv|wmv|mpg|mpeg|ts"
THUMB_WIDTH=240

usage() {
    echo "Usage: $0 [OPTIONS] [DIRECTORY]"
    echo ""
    echo "Options:"
    echo "  -g, --generate    Generate thumbnails and index files only (no server)"
    echo "  -s, --serve       Serve only (skip generation)"
    echo "  -p, --port PORT   Server port (default: 6969, or DIRINDEX_PORT env)"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Default: generate + serve"
}

generate=true
serve=true
target_dir=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--generate) generate=true; serve=false; shift ;;
        -s|--serve)    generate=false; serve=true; shift ;;
        -p|--port)     PORT="$2"; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        *)             target_dir="$1"; shift ;;
    esac
done

BASE_DIR="$(cd "${target_dir:-.}" && pwd)"

check_deps() {
    local missing=()
    command -v ffmpeg   >/dev/null 2>&1 || missing+=(ffmpeg)
    command -v ffprobe  >/dev/null 2>&1 || missing+=(ffprobe)
    command -v python3  >/dev/null 2>&1 || missing+=(python3)
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies: ${missing[*]}"
        echo "Install with: brew install ${missing[*]}"
        exit 1
    fi
}

get_duration() {
    local raw
    raw="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null | cut -d. -f1)"
    # Return empty for non-numeric values (corrupt/incomplete files)
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "$raw"
    fi
}

generate_thumbnails() {
    local video="$1"
    local video_dir
    video_dir="$(dirname "$video")"
    local video_name
    video_name="$(basename "$video")"
    local thumb_base="${video_dir}/${THUMB_DIR}/${video_name}"

    local duration
    duration="$(get_duration "$video")"
    if [[ -z "$duration" || "$duration" -eq 0 ]]; then
        echo "  SKIP (cannot read duration): $video_name"
        return
    fi

    mkdir -p "$thumb_base"

    local minutes=$(( duration / 60 ))
    # Always include 0:00, then every minute
    local total=$(( minutes + 1 ))
    local existing
    existing="$(find "$thumb_base" -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')"

    if [[ "$existing" -ge "$total" ]]; then
        echo "  OK (${total} thumbs exist): $video_name"
        return
    fi

    echo "  GENERATING ${total} thumbnails: $video_name"
    local failed=0
    for (( i = 0; i < total; i++ )); do
        local secs=$(( i * 60 ))
        local outfile="${thumb_base}/$(printf '%04d' "$i").jpg"
        if [[ -f "$outfile" ]]; then continue; fi
        local tmpfile="/tmp/dirindex_thumb_$$.jpg"
        if ! ffmpeg -nostdin -v quiet -ss "$secs" -i "$video" \
            -vframes 1 -vf "scale=${THUMB_WIDTH}:-1" \
            -q:v 4 "$tmpfile" 2>/dev/null; then
            rm -f "$tmpfile"
            failed=$(( failed + 1 ))
            # If multiple failures, video is likely incomplete — stop trying
            if [[ "$failed" -ge 3 ]]; then
                echo "  SKIP (too many errors, likely incomplete): $video_name"
                return
            fi
        else
            mv "$tmpfile" "$outfile"
        fi
    done
    if [[ "$failed" -gt 0 ]]; then
        echo "  WARN (${failed} thumbnails failed): $video_name"
    fi
}

make_time_label() {
    local secs="$1"
    printf '%d:%02d' $(( secs / 60 )) $(( secs % 60 ))
}

generate_index() {
    local dir="$1"
    local rel_dir="${dir#"$BASE_DIR"}"
    rel_dir="${rel_dir#/}"
    local dir_name
    dir_name="$(basename "$dir")"
    if [[ -z "$rel_dir" ]]; then dir_name="Videos"; fi

    # Collect videos in this directory (non-recursive)
    local videos=()
    while IFS= read -r -d '' f; do
        videos+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f \( \
        -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' \
        -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.flv' -o -iname '*.wmv' \
        -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' \
    \) -print0 2>/dev/null | sort -z)

    # Collect subdirectories that contain videos (recursively)
    local subdirs=()
    for sub in "$dir"/*/; do
        [[ -d "$sub" ]] || continue
        local subname
        subname="$(basename "$sub")"
        if [[ "$subname" == "$THUMB_DIR" ]]; then continue; fi
        # Check if subdir has any videos recursively
        local count
        count="$(find "$sub" -type f \( \
            -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' \
            -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.flv' -o -iname '*.wmv' \
            -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' \
        \) 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$count" -gt 0 ]] && subdirs+=("$sub")
    done

    [[ ${#videos[@]} -eq 0 && ${#subdirs[@]} -eq 0 ]] && return

    echo "  INDEX: ${dir}/index.html (${#videos[@]} videos, ${#subdirs[@]} subdirs)"

    # Build HTML
    cat > "${dir}/index.html" <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
HTMLHEAD

    cat >> "${dir}/index.html" <<HTMLTITLE
<title>${dir_name}</title>
HTMLTITLE

    cat >> "${dir}/index.html" <<'HTMLSTYLE'
<style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        background: #1a1a2e; color: #e0e0e0; padding: 20px;
    }
    h1 { margin-bottom: 10px; color: #fff; }
    .breadcrumb { margin-bottom: 20px; font-size: 14px; }
    .breadcrumb a { color: #7eb8da; text-decoration: none; }
    .breadcrumb a:hover { text-decoration: underline; }
    .subdirs { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 30px; }
    .subdir-link {
        display: block; padding: 12px 20px; background: #16213e;
        border-radius: 8px; color: #7eb8da; text-decoration: none;
        font-size: 16px; transition: background 0.2s;
    }
    .subdir-link:hover { background: #1a1a4e; }
    .subdir-link::before { content: "📁 "; }
    .video-block { margin-bottom: 40px; background: #16213e; border-radius: 12px; padding: 20px; }
    .video-title { font-size: 18px; margin-bottom: 12px; color: #ccc; word-break: break-all; }
    video {
        width: 100%; max-height: 70vh; background: #000;
        border-radius: 8px; display: block;
    }
    .thumb-strip {
        display: flex; flex-wrap: wrap; gap: 6px;
        margin-top: 12px; padding-top: 12px;
        border-top: 1px solid #2a2a4e;
    }
    .thumb-item {
        cursor: pointer; text-align: center; flex-shrink: 0;
        transition: transform 0.15s;
    }
    .thumb-item:hover { transform: scale(1.08); }
    .thumb-item img {
        display: block; border-radius: 4px;
        border: 2px solid transparent; width: 120px; height: auto;
    }
    .thumb-item:hover img { border-color: #7eb8da; }
    .thumb-item .time {
        font-size: 11px; color: #888; margin-top: 2px;
    }
</style>
</head>
<body>
HTMLSTYLE

    # Breadcrumb
    {
        echo '<div class="breadcrumb">'
        if [[ -n "$rel_dir" ]]; then
            echo '<a href="/">Home</a>'
            local path_acc=""
            IFS='/' read -ra parts <<< "$rel_dir"
            for (( p = 0; p < ${#parts[@]}; p++ )); do
                path_acc="${path_acc}/${parts[$p]}"
                if [[ $p -eq $(( ${#parts[@]} - 1 )) ]]; then
                    echo " / <span>${parts[$p]}</span>"
                else
                    echo " / <a href=\"${path_acc}/\">${parts[$p]}</a>"
                fi
            done
        else
            echo '<span>Home</span>'
        fi
        echo '</div>'
    } >> "${dir}/index.html"

    echo "<h1>${dir_name}</h1>" >> "${dir}/index.html"

    # Subdirectory links
    if [[ ${#subdirs[@]} -gt 0 ]]; then
        echo '<div class="subdirs">' >> "${dir}/index.html"
        for sub in "${subdirs[@]+"${subdirs[@]}"}"; do
            local subname
            subname="$(basename "$sub")"
            local encoded
            encoded="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${subname}'))")"
            echo "<a class=\"subdir-link\" href=\"${encoded}/\">${subname}</a>" >> "${dir}/index.html"
        done
        echo '</div>' >> "${dir}/index.html"
    fi

    # Video blocks
    for video in "${videos[@]+"${videos[@]}"}"; do
        local vname
        vname="$(basename "$video")"
        local encoded_vname
        encoded_vname="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${vname}'))")"
        local vid_id
        vid_id="vid_$(echo "$vname" | md5 -q 2>/dev/null || echo "$vname" | md5sum 2>/dev/null | cut -d' ' -f1)"
        local thumb_dir_abs="${dir}/${THUMB_DIR}/${vname}"
        local total_thumbs
        total_thumbs="$(find "$thumb_dir_abs" -maxdepth 1 -name '*.jpg' 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$total_thumbs" -eq 0 ]]; then continue; fi

        local thumb_base_rel="${THUMB_DIR}/${vname}"
        local encoded_thumb_base
        encoded_thumb_base="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${thumb_base_rel}'))")"

        {
            echo "<div class=\"video-block\">"
            echo "<div class=\"video-title\">${vname}</div>"
            echo "<video id=\"${vid_id}\" controls preload=\"metadata\">"
            echo "  <source src=\"${encoded_vname}\">"
            echo "</video>"
            echo "<div class=\"thumb-strip\">"

            while IFS= read -r thumb_file; do
                local thumb_name
                thumb_name="$(basename "$thumb_file")"
                local minute_num
                minute_num="$(echo "$thumb_name" | sed 's/^0*//' | sed 's/\.jpg$//')"
                minute_num="${minute_num:-0}"
                local secs=$(( minute_num * 60 ))
                local label
                label="$(make_time_label "$secs")"
                echo "<div class=\"thumb-item\" onclick=\"document.getElementById('${vid_id}').currentTime=${secs};document.getElementById('${vid_id}').play()\">"
                echo "  <img src=\"${encoded_thumb_base}/${thumb_name}\" alt=\"${label}\" loading=\"lazy\">"
                echo "  <div class=\"time\">${label}</div>"
                echo "</div>"
            done < <(find "$thumb_dir_abs" -maxdepth 1 -name '*.jpg' 2>/dev/null | sort)

            echo "</div></div>"
        } >> "${dir}/index.html"
    done

    echo '</body></html>' >> "${dir}/index.html"
}

do_generate() {
    echo "=== Scanning for videos in: ${BASE_DIR} ==="
    echo ""

    # Find all directories containing videos
    local dirs_with_videos=()
    while IFS= read -r -d '' vfile; do
        local vdir
        vdir="$(dirname "$vfile")"
        # Deduplicate
        local found=false
        for d in "${dirs_with_videos[@]+"${dirs_with_videos[@]}"}"; do
            if [[ "$d" == "$vdir" ]]; then found=true; break; fi
        done
        $found || dirs_with_videos+=("$vdir")
    done < <(find "$BASE_DIR" -type f \( \
        -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' \
        -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.flv' -o -iname '*.wmv' \
        -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' \
    \) -print0 2>/dev/null | sort -z)

    if [[ ${#dirs_with_videos[@]} -eq 0 ]]; then
        echo "No video files found."
        return
    fi

    local total_videos
    total_videos="$(find "$BASE_DIR" -type f \( \
        -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' \
        -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.flv' -o -iname '*.wmv' \
        -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' \
    \) 2>/dev/null | wc -l | tr -d ' ')"
    echo "Found ${total_videos} videos in ${#dirs_with_videos[@]} directories"
    echo ""

    # Generate thumbnails
    echo "--- Thumbnails ---"
    local current=0
    while IFS= read -r -d '' video; do
        current=$(( current + 1 ))
        echo "${current}/${total_videos} $(basename "$video")"
        generate_thumbnails "$video"
    done < <(find "$BASE_DIR" -type f \( \
        -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' \
        -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.flv' -o -iname '*.wmv' \
        -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' \
    \) -print0 2>/dev/null | sort -z)
    echo ""

    # Generate index.html files
    echo "--- Index files ---"
    # Generate for base dir and all dirs with videos
    # Also generate for parent dirs that have subdirs with videos
    local all_index_dirs=("$BASE_DIR")
    for d in "${dirs_with_videos[@]+"${dirs_with_videos[@]}"}"; do
        # Add the dir itself
        local found=false
        for existing in "${all_index_dirs[@]}"; do
            if [[ "$existing" == "$d" ]]; then found=true; break; fi
        done
        $found || all_index_dirs+=("$d")

        # Add all parent dirs up to BASE_DIR
        local parent="$d"
        while true; do
            parent="$(dirname "$parent")"
            if [[ "$parent" == "$BASE_DIR" || ${#parent} -lt ${#BASE_DIR} ]]; then break; fi
            found=false
            for existing in "${all_index_dirs[@]}"; do
                if [[ "$existing" == "$parent" ]]; then found=true; break; fi
            done
            $found || all_index_dirs+=("$parent")
        done
    done

    for d in "${all_index_dirs[@]}"; do
        if ! generate_index "$d"; then
            echo "  ERROR: Failed to generate index for ${d}, skipping"
        fi
    done
    echo ""
    echo "=== Generation complete ==="
}

generate_password() {
    python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(8)))"
}

setup_auth() {
    local pass_file="${BASE_DIR}/.dirindex_pass"
    local password=""

    if [[ -f "$pass_file" ]]; then
        local saved_pass
        saved_pass="$(cat "$pass_file")"
        echo "Saved password found for user 'x'."
        echo "  [r] Reuse saved password (default)"
        echo "  [n] Enter new password"
        echo "  [g] Generate new random password"
        echo -n "Choice [r/n/g]: "
        read -r choice
        case "$choice" in
            n|N)
                echo -n "Enter new password: "
                read -r -s password
                echo
                ;;
            g|G)
                password="$(generate_password)"
                echo "Generated password: ${password}"
                ;;
            *)
                password="$saved_pass"
                ;;
        esac
    else
        echo -n "Set password for user 'x' (leave empty for random): "
        read -r -s password
        echo
        if [[ -z "$password" ]]; then
            password="$(generate_password)"
            echo "Generated password: ${password}"
        fi
    fi

    echo "$password" > "$pass_file"
    chmod 600 "$pass_file"
    AUTH_PASSWORD="$password"
}

do_serve() {
    setup_auth
    echo ""
    echo "=== Serving ${BASE_DIR} on http://0.0.0.0:${PORT} ==="
    local ip
    ip="$(ipconfig getifaddr en0 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo '?')"
    echo "    LAN URL: http://x:${AUTH_PASSWORD}@${ip}:${PORT}"
    echo "    User: x  Password: ${AUTH_PASSWORD}"
    echo "    Press Ctrl+C to stop"
    echo ""
    cd "$BASE_DIR"
    python3 -c "
import http.server, socketserver, urllib.parse, os, base64

AUTH_USER = 'x'
AUTH_PASS = '${AUTH_PASSWORD}'
AUTH_EXPECTED = base64.b64encode(f'{AUTH_USER}:{AUTH_PASS}'.encode()).decode()

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_AUTHCHECK(self):
        auth = self.headers.get('Authorization', '')
        if not auth.startswith('Basic ') or auth[6:] != AUTH_EXPECTED:
            self.send_response(401)
            self.send_header('WWW-Authenticate', 'Basic realm=\"dirindex\"')
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'Unauthorized')
            return False
        return True

    def translate_path(self, path):
        path = urllib.parse.unquote(path)
        return super().translate_path(path)

    def do_GET(self):
        if not self.do_AUTHCHECK():
            return
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            index = os.path.join(path, 'index.html')
            if os.path.exists(index):
                if not self.path.endswith('/'):
                    self.send_response(301)
                    self.send_header('Location', self.path + '/')
                    self.end_headers()
                    return
        super().do_GET()

    def do_HEAD(self):
        if not self.do_AUTHCHECK():
            return
        super().do_HEAD()

    def end_headers(self):
        self.send_header('Accept-Ranges', 'bytes')
        super().end_headers()

with socketserver.TCPServer(('0.0.0.0', ${PORT}), Handler) as httpd:
    httpd.serve_forever()
"
}

# Main
check_deps

if $generate; then
    do_generate
fi

if $serve; then
    do_serve
fi
