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
SPRITE_COLS=10
VIDEOS_PER_PAGE=1

usage() {
    echo "Usage: $0 [OPTIONS] [DIRECTORY]"
    echo ""
    echo "Options:"
    echo "  -g, --generate    Generate thumbnails and index files only (no server)"
    echo "  -s, --serve       Serve only (skip generation)"
    echo "  -T, --no-thumbs   Skip thumbnail generation, only regenerate index pages"
    echo "  -p, --port PORT   Server port (default: 6969, or DIRINDEX_PORT env)"
    echo "  -h, --help        Show this help"
    echo ""
    echo "Default: generate + serve"
}

generate=true
serve=true
skip_thumbs=false
target_dir=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -g|--generate)  generate=true; serve=false; shift ;;
        -s|--serve)     generate=false; serve=true; shift ;;
        -T|--no-thumbs) skip_thumbs=true; shift ;;
        -p|--port)      PORT="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *)              target_dir="$1"; shift ;;
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

CACHE_FILE=""
CACHE_DIRTY=false

load_cache() {
    CACHE_FILE="${BASE_DIR}/.dirindex_cache"
    if [[ ! -f "$CACHE_FILE" ]]; then
        touch "$CACHE_FILE"
    fi
}

save_cache() {
    if $CACHE_DIRTY; then
        sort -t$'\t' -k3 "$CACHE_FILE" > "/tmp/dirindex_cache_$$.tmp"
        mv "/tmp/dirindex_cache_$$.tmp" "$CACHE_FILE"
    fi
}

get_duration() {
    local file="$1"
    local file_mtime
    file_mtime="$(stat -f '%m' "$file" 2>/dev/null || stat -c '%Y' "$file" 2>/dev/null)"

    # Check cache — grep for exact filepath match (tab-terminated fields)
    local cached_line
    cached_line="$(grep -F "$file" "$CACHE_FILE" | grep -m1 "	${file}$")" || true
    if [[ -n "$cached_line" ]]; then
        local cached_mtime cached_duration
        cached_mtime="$(printf '%s' "$cached_line" | cut -f1)"
        cached_duration="$(printf '%s' "$cached_line" | cut -f2)"
        if [[ "$cached_mtime" == "$file_mtime" ]]; then
            echo "$cached_duration"
            return
        fi
        # mtime changed — remove old entry
        grep -v "	${file}$" "$CACHE_FILE" > "/tmp/dirindex_cache_$$.tmp" || true
        mv "/tmp/dirindex_cache_$$.tmp" "$CACHE_FILE"
    fi

    # Cache miss — call ffprobe
    local raw
    raw="$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null | cut -d. -f1)"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        printf '%s\t%s\t%s\n' "$file_mtime" "$raw" "$file" >> "$CACHE_FILE"
        CACHE_DIRTY=true
        echo "$raw"
    else
        printf '%s\t\t%s\n' "$file_mtime" "$file" >> "$CACHE_FILE"
        CACHE_DIRTY=true
    fi
}

generate_thumbnails() {
    local video="$1"
    local video_dir
    video_dir="$(dirname "$video")"
    local video_name
    video_name="$(basename "$video")"
    local thumb_dir="${video_dir}/${THUMB_DIR}"
    local sprite_file="${thumb_dir}/${video_name}.jpg"
    local meta_file="${thumb_dir}/${video_name}.meta"

    local duration
    duration="$(get_duration "$video")"
    if [[ -z "$duration" || "$duration" -eq 0 ]]; then
        echo "  SKIP (cannot read duration): $video_name"
        return
    fi

    local minutes=$(( duration / 60 ))
    local total=$(( minutes + 1 ))
    local rows=$(( (total + SPRITE_COLS - 1) / SPRITE_COLS ))

    # Check if sprite already exists with correct frame count
    if [[ -f "$sprite_file" && -f "$meta_file" ]]; then
        local cached_total
        cached_total="$(cat "$meta_file")"
        if [[ "$cached_total" == "$total" ]]; then
            echo "  OK (sprite ${total} frames): $video_name"
            return
        fi
    fi

    mkdir -p "$thumb_dir"

    echo "  GENERATING sprite (${total} frames, ${SPRITE_COLS}x${rows}): $video_name"
    local tmpfile="/tmp/dirindex_sprite_$$.jpg"
    if ffmpeg -nostdin -v quiet -i "$video" \
        -vf "fps=1/60,scale=${THUMB_WIDTH}:-1,tile=${SPRITE_COLS}x${rows}" \
        -q:v 4 "$tmpfile" 2>/dev/null; then
        mv "$tmpfile" "$sprite_file"
        echo "$total" > "$meta_file"
    else
        rm -f "$tmpfile"
        echo "  SKIP (sprite generation failed): $video_name"
    fi
}

make_time_label() {
    local secs="$1"
    printf '%d:%02d' $(( secs / 60 )) $(( secs % 60 ))
}

page_filename() {
    local page="$1"
    if [[ "$page" -eq 1 ]]; then
        echo "index.html"
    else
        echo "page${page}.html"
    fi
}

write_page_header() {
    local outfile="$1"
    local dir_name="$2"
    local rel_dir="$3"
    local page="$4"
    local total_pages="$5"

    local title="$dir_name"
    if [[ "$total_pages" -gt 1 ]]; then
        title="${dir_name} (page ${page}/${total_pages})"
    fi

    cat > "$outfile" <<'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
HTMLHEAD

    cat >> "$outfile" <<HTMLTITLE
<title>${title}</title>
HTMLTITLE

    cat >> "$outfile" <<'HTMLSTYLE'
<style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        background: #1a1a2e; color: #e0e0e0; padding: 20px;
        max-width: 100vw; overflow-x: hidden;
    }
    h1 { margin-bottom: 10px; color: #fff; }
    .breadcrumb { margin-bottom: 20px; font-size: 14px; }
    .breadcrumb a { color: #7eb8da; text-decoration: none; }
    .breadcrumb a:hover { text-decoration: underline; }
    .subdirs { display: flex; flex-wrap: wrap; gap: 10px; margin-bottom: 30px; max-width: 100%; overflow: hidden; }
    .subdir-link {
        display: block; padding: 12px 20px; background: #16213e;
        border-radius: 8px; color: #7eb8da; text-decoration: none;
        font-size: 16px; transition: background 0.2s;
        word-break: break-all; overflow-wrap: anywhere; max-width: 100%;
    }
    .subdir-link:hover { background: #1a1a4e; }
    .subdir-link::before { content: "📁 "; }
    .video-block { margin-bottom: 40px; background: #16213e; border-radius: 12px; padding: 20px; }
    .video-title { font-size: 18px; margin-bottom: 12px; color: #ccc; word-break: break-all; overflow-wrap: anywhere; }
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
    .thumb-frame {
        display: block; border-radius: 4px;
        border: 2px solid transparent;
        width: 120px; height: 68px;
        background-size: cover;
        background-repeat: no-repeat;
    }
    .thumb-item:hover .thumb-frame { border-color: #7eb8da; }
    .thumb-item .time {
        font-size: 11px; color: #888; margin-top: 2px;
    }
    .pagination {
        display: flex; gap: 8px; margin: 20px 0; flex-wrap: wrap; align-items: center;
    }
    .pagination a, .pagination span {
        display: inline-block; padding: 8px 14px; border-radius: 6px;
        text-decoration: none; font-size: 14px;
    }
    .pagination a { background: #16213e; color: #7eb8da; }
    .pagination a:hover { background: #1a1a4e; }
    .pagination .current { background: #7eb8da; color: #1a1a2e; font-weight: bold; }
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
    } >> "$outfile"

    echo "<h1>${dir_name}</h1>" >> "$outfile"
}

write_pagination() {
    local outfile="$1"
    local page="$2"
    local total_pages="$3"

    if [[ "$total_pages" -le 1 ]]; then return; fi

    echo '<div class="pagination">' >> "$outfile"
    if [[ "$page" -gt 1 ]]; then
        echo "<a href=\"$(page_filename $(( page - 1 )))\">Prev</a>" >> "$outfile"
    fi
    for (( pg = 1; pg <= total_pages; pg++ )); do
        if [[ "$pg" -eq "$page" ]]; then
            echo "<span class=\"current\">${pg}</span>" >> "$outfile"
        else
            echo "<a href=\"$(page_filename "$pg")\">${pg}</a>" >> "$outfile"
        fi
    done
    if [[ "$page" -lt "$total_pages" ]]; then
        echo "<a href=\"$(page_filename $(( page + 1 )))\">Next</a>" >> "$outfile"
    fi
    echo '</div>' >> "$outfile"
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
        local count
        count="$(find "$sub" -type f \( \
            -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' \
            -o -iname '*.webm' -o -iname '*.m4v' -o -iname '*.flv' -o -iname '*.wmv' \
            -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.ts' \
        \) 2>/dev/null | wc -l | tr -d ' ')"
        [[ "$count" -gt 0 ]] && subdirs+=("$sub")
    done

    [[ ${#videos[@]} -eq 0 && ${#subdirs[@]} -eq 0 ]] && return

    local num_videos=${#videos[@]}
    local total_pages=$(( (num_videos + VIDEOS_PER_PAGE - 1) / VIDEOS_PER_PAGE ))
    if [[ "$total_pages" -eq 0 ]]; then total_pages=1; fi

    echo "  INDEX: ${dir}/ (${num_videos} videos, ${#subdirs[@]} subdirs, ${total_pages} pages)"

    # Remove old page files
    rm -f "${dir}"/page[0-9]*.html

    for (( page = 1; page <= total_pages; page++ )); do
        local outfile="${dir}/$(page_filename "$page")"
        local start_idx=$(( (page - 1) * VIDEOS_PER_PAGE ))

        write_page_header "$outfile" "$dir_name" "$rel_dir" "$page" "$total_pages"

        # Subdirectory links (only on page 1)
        if [[ "$page" -eq 1 && ${#subdirs[@]} -gt 0 ]]; then
            echo '<div class="subdirs">' >> "$outfile"
            for sub in "${subdirs[@]+"${subdirs[@]}"}"; do
                local subname
                subname="$(basename "$sub")"
                local encoded
                encoded="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${subname}'))")"
                echo "<a class=\"subdir-link\" href=\"${encoded}/\">${subname}</a>" >> "$outfile"
            done
            echo '</div>' >> "$outfile"
        fi

        write_pagination "$outfile" "$page" "$total_pages"

        # Video blocks for this page
        for (( vi = start_idx; vi < start_idx + VIDEOS_PER_PAGE && vi < num_videos; vi++ )); do
            local video="${videos[$vi]}"
            local vname
            vname="$(basename "$video")"
            local encoded_vname
            encoded_vname="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${vname}'))")"
            local vid_id
            vid_id="vid_$(echo "$vname" | md5 -q 2>/dev/null || echo "$vname" | md5sum 2>/dev/null | cut -d' ' -f1)"
            local sprite_file="${dir}/${THUMB_DIR}/${vname}.jpg"
            local meta_file="${dir}/${THUMB_DIR}/${vname}.meta"
            if [[ ! -f "$sprite_file" || ! -f "$meta_file" ]]; then continue; fi
            local total_thumbs
            total_thumbs="$(cat "$meta_file")"
            if [[ "$total_thumbs" -eq 0 ]]; then continue; fi

            local sprite_rel="${THUMB_DIR}/${vname}.jpg"
            local encoded_sprite
            encoded_sprite="$(python3 -c "import urllib.parse; print(urllib.parse.quote('${sprite_rel}'))")"

            # Get sprite actual dimensions for background-size calc
            local sprite_rows=$(( (total_thumbs + SPRITE_COLS - 1) / SPRITE_COLS ))
            local bg_width=$(( SPRITE_COLS * 120 ))

            {
                echo "<div class=\"video-block\">"
                echo "<div class=\"video-title\">${vname}</div>"
                echo "<video id=\"${vid_id}\" controls preload=\"auto\">"
                echo "  <source src=\"${encoded_vname}\">"
                echo "</video>"
                echo "<div class=\"thumb-strip\">"

                for (( i = 0; i < total_thumbs; i++ )); do
                    local secs=$(( i * 60 ))
                    local label
                    label="$(make_time_label "$secs")"
                    local col=$(( i % SPRITE_COLS ))
                    local row=$(( i / SPRITE_COLS ))
                    local bg_x=$(( col * 120 ))
                    local bg_y=$(( row * 68 ))
                    echo "<div class=\"thumb-item\" onclick=\"var v=document.getElementById('${vid_id}');if(v.fastSeek)v.fastSeek(${secs});else v.currentTime=${secs};v.play();v.scrollIntoView({behavior:'smooth'})\">"
                    echo "  <div class=\"thumb-frame\" style=\"background-image:url('${encoded_sprite}');background-size:${bg_width}px auto;background-position:-${bg_x}px -${bg_y}px\"></div>"
                    echo "  <div class=\"time\">${label}</div>"
                    echo "</div>"
                done

                echo "</div></div>"
            } >> "$outfile"
        done

        write_pagination "$outfile" "$page" "$total_pages"
        echo '</body></html>' >> "$outfile"
    done
}

do_generate() {
    load_cache
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
    if $skip_thumbs; then
        echo "--- Skipping thumbnails (-T) ---"
    else
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
    fi
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

    local max_jobs
    max_jobs="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
    local running=0
    for d in "${all_index_dirs[@]}"; do
        (generate_index "$d" || echo "  ERROR: Failed to generate index for ${d}, skipping") &
        running=$(( running + 1 ))
        if [[ "$running" -ge "$max_jobs" ]]; then
            wait -n 2>/dev/null || wait
            running=$(( running - 1 ))
        fi
    done
    wait
    save_cache
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
import http.server, socketserver, urllib.parse, os, base64, json, threading, time

AUTH_USER = 'x'
AUTH_PASS = '${AUTH_PASSWORD}'
AUTH_EXPECTED = base64.b64encode(f'{AUTH_USER}:{AUTH_PASS}'.encode()).decode()

SEEKS_FILE = os.path.join('${BASE_DIR}', '.dirindex_seeks')
VIDEO_EXTS = {'.mp4','.mkv','.avi','.mov','.webm','.m4v','.flv','.wmv','.mpg','.mpeg','.ts'}
seeks_data = {}
seeks_lock = threading.Lock()
last_save = [0.0]

def load_seeks():
    global seeks_data
    if os.path.exists(SEEKS_FILE):
        try:
            with open(SEEKS_FILE, 'r') as f:
                seeks_data = json.load(f)
        except Exception:
            seeks_data = {}

def save_seeks():
    with seeks_lock:
        try:
            with open(SEEKS_FILE, 'w') as f:
                json.dump(seeks_data, f, indent=2)
        except Exception:
            pass

def record_seek(filepath, byte_offset):
    file_size = os.path.getsize(filepath)
    if file_size == 0:
        return
    # Estimate time position as percentage bucket (1-minute granularity added later with duration)
    pct = byte_offset / file_size
    # Store as percentage bucket (0-99)
    bucket = min(int(pct * 100), 99)
    rel = os.path.relpath(filepath, '${BASE_DIR}')
    with seeks_lock:
        if rel not in seeks_data:
            seeks_data[rel] = {}
        key = str(bucket)
        seeks_data[rel][key] = seeks_data[rel].get(key, 0) + 1
    # Save at most every 10 seconds
    now = time.time()
    if now - last_save[0] > 10:
        last_save[0] = now
        threading.Thread(target=save_seeks, daemon=True).start()

load_seeks()

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

    def serve_range(self, fpath):
        \"\"\"Serve a file with byte-range support for video seeking.\"\"\"
        file_size = os.path.getsize(fpath)
        range_header = self.headers.get('Range', '')
        ctype = self.guess_type(fpath)

        if range_header.startswith('bytes='):
            # Track seeks on video files
            ext = os.path.splitext(fpath)[1].lower()
            if ext in VIDEO_EXTS:
                try:
                    s = range_header[6:].partition('-')[0]
                    if s:
                        record_seek(fpath, int(s))
                except Exception:
                    pass

            range_spec = range_header[6:]
            start_str, _, end_str = range_spec.partition('-')
            start = int(start_str) if start_str else 0
            end = int(end_str) if end_str else file_size - 1
            end = min(end, file_size - 1)
            length = end - start + 1

            self.send_response(206)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(length))
            self.send_header('Content-Range', f'bytes {start}-{end}/{file_size}')
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()

            with open(fpath, 'rb') as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(65536, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        else:
            self.send_response(200)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(file_size))
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()

            with open(fpath, 'rb') as f:
                while True:
                    chunk = f.read(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)

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
        # Use range serving for files
        if os.path.isfile(path):
            try:
                self.serve_range(path)
                return
            except Exception:
                pass
        super().do_GET()

    def do_HEAD(self):
        if not self.do_AUTHCHECK():
            return
        super().do_HEAD()

    def end_headers(self):
        self.send_header('Accept-Ranges', 'bytes')
        super().end_headers()

import signal, atexit
atexit.register(save_seeks)
signal.signal(signal.SIGTERM, lambda *a: (save_seeks(), exit(0)))
signal.signal(signal.SIGINT, lambda *a: (save_seeks(), exit(0)))

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
