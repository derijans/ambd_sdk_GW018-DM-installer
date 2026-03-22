#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
DEFAULT_CONFIG_FILE="$SCRIPT_DIR/flash-gw018-dm.conf"
EXAMPLE_CONFIG_FILE="$SCRIPT_DIR/flash-gw018-dm.conf.example"
LOCAL_CONFIG_FILE="$SCRIPT_DIR/flash-gw018-dm.local.conf"
DEFAULT_UPLOAD_TOOL_URL="https://github.com/ambiot/ambd_arduino/raw/dev/Arduino_package/ameba_d_tools_linux/upload_image_tool_linux"
REQUIRED_IMAGE_NAMES=("km0_boot_all.bin" "km4_boot_all.bin" "km0_km4_image2.bin")
CAPTURE_PID=""
SESSION_DIR=""
WORK_DIR_ABS=""
FIRMWARE_STAGE_DIR=""
UPLOAD_TOOL_PATH=""
EXPLICIT_CONFIG=""
COMMAND="all"
SELECTED_FIRMWARE_SOURCE=""
SELECTED_FIRMWARE_ROOT=""
SELECTED_ARTIFACT_RUN_ID=""
SELECTED_ARTIFACT_RUN_ID_AUTO="false"
declare -a LOADED_CONFIG_FILES=()

set_defaults() {
    REPO="derijans/ambd_sdk_GW018-DM"
    RUN_ID=""
    ARTIFACT_NAME="gw018-dm-custom-firmware"
    FIRMWARE_DIR=""
    UPLOAD_TOOL=""
    PORT=""
    LOG_PORT=""
    BACKUP_BAUD="115200"
    FLASH_BAUD="921600"
    WORK_DIR=".gw018-dm"
    SSID=""
    PASSPHRASE=""
    SKIP_BACKUP="false"
    SKIP_WIFI="false"
    ASSUME_YES="false"
    Z2M_ADAPTER="ezsp"
    Z2M_BAUDRATE="115200"
    Z2M_RTSCTS="true"
}

info() {
    printf '[INFO] %s\n' "$*"
}

warn() {
    printf '[WARN] %s\n' "$*" >&2
}

die() {
    printf '[ERROR] %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [command] [options]

Commands:
  all
  download
  backup
  flash
  wifi

Options:
  --config PATH
  --repo OWNER/REPO
  --run-id ID
  --artifact-name NAME
  --firmware-dir PATH
  --upload-tool PATH
  --port PATH
  --log-port PATH
  --baud-backup RATE
  --baud-flash RATE
  --work-dir PATH
  --ssid VALUE
  --passphrase VALUE
  --z2m-adapter VALUE
  --z2m-baudrate VALUE
  --z2m-rtscts VALUE
  --skip-backup
  --skip-wifi
  --yes
  -h, --help

Config load order:
  1. --config PATH, if supplied
  2. Built-in defaults
  3. $DEFAULT_CONFIG_FILE
  4. $LOCAL_CONFIG_FILE
  5. CLI flags

Examples:
  $SCRIPT_NAME all --run-id 22802077282
  $SCRIPT_NAME flash --firmware-dir release_firmware --port /dev/ttyUSB0
  $SCRIPT_NAME wifi --ssid "My WiFi" --passphrase "secret pass"
EOF
}

cleanup_capture() {
    if [[ -n "${CAPTURE_PID:-}" ]]; then
        kill "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
        CAPTURE_PID=""
    fi
}

should_pause_on_exit() {
    [[ -t 0 && -t 1 ]] || return 1
    case "${MSYSTEM:-}${OSTYPE:-}" in
        MINGW*|MSYS*|*msys*|*cygwin*) return 0 ;;
        *) return 1 ;;
    esac
}

handle_exit() {
    local exit_code=$?
    cleanup_capture
    if should_pause_on_exit; then
        printf 'Press Enter to close this window...'
        read -r _ || true
    fi
    return "$exit_code"
}

trap handle_exit EXIT
trap 'cleanup_capture; exit 130' INT TERM

is_true() {
    case "${1,,}" in
        1|true|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

require_option_value() {
    local option_name="$1"
    local option_value="${2-}"
    [[ -n "$option_value" ]] || die "$option_name requires a value"
    printf '%s' "$option_value"
}

preparse_args() {
    local args=("$@")
    local index=0
    local first_command=""
    while (( index < ${#args[@]} )); do
        case "${args[$index]}" in
            all|download|backup|flash|wifi)
                if [[ -z "$first_command" ]]; then
                    first_command="${args[$index]}"
                fi
                ;;
            --config)
                (( index + 1 < ${#args[@]} )) || die "--config requires a value"
                EXPLICIT_CONFIG="${args[$((index + 1))]}"
                ((index++))
                ;;
            -h|--help)
                usage
                exit 0
                ;;
        esac
        ((index++))
    done
    if [[ -n "$first_command" ]]; then
        COMMAND="$first_command"
    fi
}

validate_config_file() {
    local config_file="$1"
    local line_number=0
    local line=""
    local trimmed=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        trimmed=$(printf '%s' "$line" | sed 's/^[[:space:]]*//')
        if [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]]; then
            continue
        fi
        if [[ ! "$trimmed" =~ ^[A-Z0-9_]+= ]]; then
            die "Malformed config line $line_number in $config_file"
        fi
    done < "$config_file"
}

load_config_file() {
    local config_file="$1"
    local is_required="$2"
    if [[ ! -f "$config_file" ]]; then
        if is_true "$is_required"; then
            die "Config file not found: $config_file"
        fi
        return 0
    fi
    validate_config_file "$config_file"
    source "$config_file"
    LOADED_CONFIG_FILES+=("$config_file")
}

ensure_default_config_ready() {
    if [[ -n "$EXPLICIT_CONFIG" ]]; then
        return 0
    fi
    if [[ -f "$DEFAULT_CONFIG_FILE" ]]; then
        return 0
    fi
    if [[ -f "$EXAMPLE_CONFIG_FILE" ]]; then
        cp "$EXAMPLE_CONFIG_FILE" "$DEFAULT_CONFIG_FILE"
        info "Created $DEFAULT_CONFIG_FILE from $EXAMPLE_CONFIG_FILE"
        info "Adjust $DEFAULT_CONFIG_FILE and run the script again."
        info "You can also use --config PATH or CLI flags instead."
        exit 0
    fi
    warn "Default config file not found: $DEFAULT_CONFIG_FILE"
    warn "Config template not found: $EXAMPLE_CONFIG_FILE"
    die "Create $DEFAULT_CONFIG_FILE manually or use --config PATH or CLI flags."
}

parse_cli_args() {
    local command_seen="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            all|download|backup|flash|wifi)
                if is_true "$command_seen"; then
                    die "Only one command can be used at a time"
                fi
                COMMAND="$1"
                command_seen="true"
                shift
                ;;
            --config)
                EXPLICIT_CONFIG=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --repo)
                REPO=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --run-id)
                RUN_ID=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --artifact-name)
                ARTIFACT_NAME=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --firmware-dir)
                FIRMWARE_DIR=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --upload-tool)
                UPLOAD_TOOL=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --port)
                PORT=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --log-port)
                LOG_PORT=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --baud-backup)
                BACKUP_BAUD=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --baud-flash)
                FLASH_BAUD=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --work-dir)
                WORK_DIR=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --ssid)
                SSID=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --passphrase)
                PASSPHRASE=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --z2m-adapter)
                Z2M_ADAPTER=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --z2m-baudrate)
                Z2M_BAUDRATE=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --z2m-rtscts)
                Z2M_RTSCTS=$(require_option_value "$1" "${2-}")
                shift 2
                ;;
            --skip-backup)
                SKIP_BACKUP="true"
                shift
                ;;
            --skip-wifi)
                SKIP_WIFI="true"
                shift
                ;;
            --yes)
                ASSUME_YES="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done
}

resolve_root_path() {
    local input_path="$1"
    if [[ -z "$input_path" ]]; then
        printf '%s' ""
        return 0
    fi
    if [[ "$input_path" == /* ]]; then
        printf '%s' "$input_path"
    else
        printf '%s/%s' "$ROOT_DIR" "$input_path"
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

has_command() {
    command -v "$1" >/dev/null 2>&1
}

ensure_directory() {
    mkdir -p "$1"
}

session_path() {
    printf '%s/%s' "$SESSION_DIR" "$1"
}

prompt_continue() {
    local message="$1"
    if is_true "$ASSUME_YES"; then
        info "$message"
        return 0
    fi
    printf '%s [y/N]: ' "$message"
    local reply=""
    read -r reply || die "Input aborted"
    case "${reply,,}" in
        y|yes) return 0 ;;
        *) die "Stopped by user" ;;
    esac
}

preflight_checks() {
    require_command awk
    require_command cat
    require_command chmod
    require_command cp
    require_command sed
    require_command grep
    require_command mktemp
    require_command readlink
    require_command sleep
    require_command stty
    require_command tail
    require_command tee
    require_command xxd
    require_command sha256sum
    require_command find
    require_command date
    require_command sort
    case "$COMMAND" in
        download|flash|all)
            preflight_firmware_source_dependencies
            ;;
    esac
    case "$COMMAND" in
        flash|all)
            preflight_upload_tool_dependencies
            ;;
    esac
}

prepare_session() {
    WORK_DIR_ABS=$(resolve_root_path "$WORK_DIR")
    ensure_directory "$WORK_DIR_ABS"
    ensure_directory "$WORK_DIR_ABS/tools"
    SESSION_DIR="$WORK_DIR_ABS/sessions/$(date +%Y%m%d-%H%M%S)"
    ensure_directory "$SESSION_DIR"
    ensure_directory "$(session_path firmware)"
    ensure_directory "$(session_path backup)"
    ensure_directory "$(session_path logs)"
}

find_unique_file() {
    local search_root="$1"
    local expected_name="$2"
    mapfile -t matches < <(find "$search_root" -type f -name "$expected_name" 2>/dev/null | sort)
    if (( ${#matches[@]} == 0 )); then
        die "Could not find $expected_name under $search_root"
    fi
    if (( ${#matches[@]} > 1 )); then
        die "Found multiple copies of $expected_name under $search_root"
    fi
    printf '%s' "${matches[0]}"
}

describe_firmware_tree() {
    local search_root="$1"
    local image_name=""
    local -a matches=()
    [[ -d "$search_root" ]] || {
        printf 'directory not found: %s' "$search_root"
        return 1
    }
    for image_name in "${REQUIRED_IMAGE_NAMES[@]}"; do
        mapfile -t matches < <(find "$search_root" -type f -name "$image_name" 2>/dev/null | sort)
        if (( ${#matches[@]} == 0 )); then
            printf 'missing %s under %s' "$image_name" "$search_root"
            return 1
        fi
        if (( ${#matches[@]} > 1 )); then
            printf 'found multiple copies of %s under %s' "$image_name" "$search_root"
            return 1
        fi
    done
    return 0
}

configured_firmware_dir_is_usable() {
    local configured_firmware_root=""
    [[ -n "$FIRMWARE_DIR" ]] || return 1
    configured_firmware_root=$(resolve_root_path "$FIRMWARE_DIR")
    describe_firmware_tree "$configured_firmware_root" >/dev/null 2>&1
}

preflight_firmware_source_dependencies() {
    local configured_firmware_root=""
    if has_command gh; then
        return 0
    fi
    if configured_firmware_dir_is_usable; then
        warn "gh is not installed. GitHub artifact firmware will be unavailable, but the configured local firmware directory is usable."
        return 0
    fi
    configured_firmware_root=$(resolve_root_path "$FIRMWARE_DIR")
    if [[ -n "$RUN_ID" ]]; then
        die "gh is required to download firmware from run $RUN_ID"
    fi
    if [[ -n "$FIRMWARE_DIR" ]]; then
        die "gh is required because the configured firmware directory is not usable: $configured_firmware_root"
    fi
    die "gh is required because no usable local firmware source is configured"
}

preflight_upload_tool_dependencies() {
    local configured_upload_tool_path=""
    local cache_upload_tool_path
    local default_example_upload_tool_path
    cache_upload_tool_path="$(resolve_root_path "$WORK_DIR")/tools/upload_image_tool_linux"
    default_example_upload_tool_path=$(resolve_root_path ".gw018-dm/tools/upload_image_tool_linux")
    if [[ -n "$UPLOAD_TOOL" ]]; then
        configured_upload_tool_path=$(resolve_root_path "$UPLOAD_TOOL")
        if [[ -f "$configured_upload_tool_path" ]]; then
            return 0
        fi
        if [[ "$configured_upload_tool_path" == "$cache_upload_tool_path" || "$configured_upload_tool_path" == "$default_example_upload_tool_path" ]]; then
            if has_command curl || has_command wget; then
                return 0
            fi
            die "curl or wget is required to download the upload tool to $configured_upload_tool_path"
        fi
        die "Upload tool not found: $configured_upload_tool_path"
    fi
    if [[ -f "$cache_upload_tool_path" ]]; then
        return 0
    fi
    if has_command curl || has_command wget; then
        return 0
    fi
    die "curl or wget is required to download the upload tool to $cache_upload_tool_path"
}

stage_firmware_from_tree() {
    local search_root="$1"
    local destination_dir="$2"
    local image_name=""
    local source_path=""
    for image_name in "${REQUIRED_IMAGE_NAMES[@]}"; do
        source_path=$(find_unique_file "$search_root" "$image_name")
        cp "$source_path" "$destination_dir/$image_name"
    done
}

artifact_run_has_named_artifact() {
    local run_id="$1"
    local artifact_name=""
    while IFS= read -r artifact_name; do
        if [[ "$artifact_name" == "$ARTIFACT_NAME" ]]; then
            return 0
        fi
    done < <(gh api "repos/$REPO/actions/runs/$run_id/artifacts" --jq '.artifacts[]?.name' 2>/dev/null || true)
    return 1
}

resolve_artifact_candidate_run_id() {
    local requested_run_id="$1"
    local run_id=""
    if ! command -v gh >/dev/null 2>&1; then
        printf '%s' "gh is not installed"
        return 1
    fi
    if [[ -n "$requested_run_id" ]]; then
        if artifact_run_has_named_artifact "$requested_run_id"; then
            printf '%s' "$requested_run_id"
            return 0
        fi
        printf '%s' "artifact $ARTIFACT_NAME was not found in run $requested_run_id from $REPO"
        return 1
    fi
    while IFS= read -r run_id; do
        [[ -n "$run_id" ]] || continue
        if artifact_run_has_named_artifact "$run_id"; then
            printf '%s' "$run_id"
            return 0
        fi
    done < <(gh run list --repo "$REPO" --limit 50 --json databaseId,conclusion --jq '.[] | select(.conclusion == "success") | .databaseId' 2>/dev/null || true)
    printf '%s' "could not find a successful run in $REPO with artifact $ARTIFACT_NAME"
    return 1
}

select_firmware_source() {
    local requested_run_id="$RUN_ID"
    local configured_firmware_root=""
    local local_source_issue=""
    local artifact_source_issue=""
    local artifact_candidate_run_id=""
    local selection=""
    SELECTED_FIRMWARE_SOURCE=""
    SELECTED_FIRMWARE_ROOT=""
    SELECTED_ARTIFACT_RUN_ID=""
    SELECTED_ARTIFACT_RUN_ID_AUTO="false"

    if [[ -n "$FIRMWARE_DIR" ]]; then
        configured_firmware_root=$(resolve_root_path "$FIRMWARE_DIR")
        if local_source_issue=$(describe_firmware_tree "$configured_firmware_root"); then
            SELECTED_FIRMWARE_ROOT="$configured_firmware_root"
            SELECTED_FIRMWARE_SOURCE="local"
            return 0
        else
            warn "Ignoring configured firmware directory: $local_source_issue"
        fi
    fi

    if artifact_source_issue=$(resolve_artifact_candidate_run_id "$requested_run_id"); then
        artifact_candidate_run_id="$artifact_source_issue"
        SELECTED_ARTIFACT_RUN_ID="$artifact_candidate_run_id"
        if [[ -z "$requested_run_id" ]]; then
            SELECTED_ARTIFACT_RUN_ID_AUTO="true"
        fi
    else
        warn "GitHub artifact source unavailable: $artifact_source_issue"
    fi

    if [[ -n "$SELECTED_FIRMWARE_ROOT" && -n "$SELECTED_ARTIFACT_RUN_ID" ]]; then
        if is_true "$ASSUME_YES"; then
            SELECTED_FIRMWARE_SOURCE="local"
            return 0
        fi
        [[ -t 0 ]] || die "Both local firmware and a GitHub artifact are available. Use --yes to prefer local firmware."
        info "Choose the firmware source"
        printf '  1. Local firmware: %s\n' "$SELECTED_FIRMWARE_ROOT"
        printf '  2. GitHub artifact: %s run %s (%s)\n' "$REPO" "$SELECTED_ARTIFACT_RUN_ID" "$ARTIFACT_NAME"
        printf 'Selection: '
        read -r selection || die "Input aborted"
        case "$selection" in
            1) SELECTED_FIRMWARE_SOURCE="local" ;;
            2) SELECTED_FIRMWARE_SOURCE="artifact" ;;
            *) die "Invalid selection: $selection" ;;
        esac
        return 0
    fi

    if [[ -n "$SELECTED_FIRMWARE_ROOT" ]]; then
        SELECTED_FIRMWARE_SOURCE="local"
        return 0
    fi

    if [[ -n "$SELECTED_ARTIFACT_RUN_ID" ]]; then
        SELECTED_FIRMWARE_SOURCE="artifact"
        return 0
    fi

    die "No usable firmware source found. Set FIRMWARE_DIR to a directory with the required images, or make sure GitHub artifact access works for $REPO / $ARTIFACT_NAME."
}

download_artifact_files() {
    local destination_root="$1"
    local artifact_run_id="$2"
    local artifact_dir="$destination_root/artifact"
    ensure_directory "$artifact_dir"
    info "Downloading artifact $ARTIFACT_NAME from $REPO run $artifact_run_id"
    gh run download "$artifact_run_id" --repo "$REPO" --name "$ARTIFACT_NAME" --dir "$artifact_dir" >/dev/null
    stage_firmware_from_tree "$artifact_dir" "$destination_root"
}

write_firmware_checksums() {
    (
        cd "$FIRMWARE_STAGE_DIR"
        sha256sum "${REQUIRED_IMAGE_NAMES[@]}" > SHA256SUMS
    )
}

stage_firmware() {
    FIRMWARE_STAGE_DIR="$(session_path firmware)"
    select_firmware_source
    if [[ "$SELECTED_FIRMWARE_SOURCE" == "local" ]]; then
        info "Using firmware from $SELECTED_FIRMWARE_ROOT"
        stage_firmware_from_tree "$SELECTED_FIRMWARE_ROOT" "$FIRMWARE_STAGE_DIR"
    else
        RUN_ID="$SELECTED_ARTIFACT_RUN_ID"
        if is_true "$SELECTED_ARTIFACT_RUN_ID_AUTO"; then
            info "Resolved latest successful artifact run: $RUN_ID"
        fi
        download_artifact_files "$FIRMWARE_STAGE_DIR" "$RUN_ID"
    fi
    write_firmware_checksums
}

download_to_path() {
    local url="$1"
    local destination_path="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$destination_path"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$destination_path" "$url"
    else
        die "curl or wget is required to download $url"
    fi
}

resolve_upload_tool_path() {
    local configured_upload_tool_path=""
    local cache_upload_tool_path="$WORK_DIR_ABS/tools/upload_image_tool_linux"
    local default_example_upload_tool_path
    default_example_upload_tool_path=$(resolve_root_path ".gw018-dm/tools/upload_image_tool_linux")
    if [[ -n "$UPLOAD_TOOL" ]]; then
        configured_upload_tool_path=$(resolve_root_path "$UPLOAD_TOOL")
        UPLOAD_TOOL_PATH="$configured_upload_tool_path"
        if [[ ! -f "$UPLOAD_TOOL_PATH" ]]; then
            if [[ "$UPLOAD_TOOL_PATH" == "$cache_upload_tool_path" || "$UPLOAD_TOOL_PATH" == "$default_example_upload_tool_path" ]]; then
                info "Downloading upload_image_tool_linux"
                ensure_directory "$(dirname "$UPLOAD_TOOL_PATH")"
                download_to_path "$DEFAULT_UPLOAD_TOOL_URL" "$UPLOAD_TOOL_PATH"
            else
                die "Upload tool not found: $UPLOAD_TOOL_PATH"
            fi
        fi
        chmod +x "$UPLOAD_TOOL_PATH"
        return 0
    fi
    UPLOAD_TOOL_PATH="$cache_upload_tool_path"
    if [[ ! -f "$UPLOAD_TOOL_PATH" ]]; then
        info "Downloading upload_image_tool_linux"
        download_to_path "$DEFAULT_UPLOAD_TOOL_URL" "$UPLOAD_TOOL_PATH"
        chmod +x "$UPLOAD_TOOL_PATH"
    fi
    [[ -f "$UPLOAD_TOOL_PATH" ]] || die "Upload tool not found: $UPLOAD_TOOL_PATH"
    chmod +x "$UPLOAD_TOOL_PATH"
}

discover_serial_ports() {
    declare -A seen_targets=()
    declare -a ordered_ports=()
    local candidate=""
    local resolved=""
    if compgen -G "/dev/serial/by-id/*" >/dev/null; then
        for candidate in /dev/serial/by-id/*; do
            [[ -e "$candidate" ]] || continue
            resolved=$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")
            if [[ -z "${seen_targets[$resolved]:-}" ]]; then
                seen_targets["$resolved"]=1
                ordered_ports+=("$candidate")
            fi
        done
    fi
    for candidate in /dev/ttyUSB* /dev/ttyACM*; do
        [[ -e "$candidate" ]] || continue
        resolved=$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")
        if [[ -z "${seen_targets[$resolved]:-}" ]]; then
            seen_targets["$resolved"]=1
            ordered_ports+=("$candidate")
        fi
    done
    printf '%s\n' "${ordered_ports[@]}"
}

choose_serial_port() {
    local port_label="$1"
    local configured_port="$2"
    if [[ -n "$configured_port" ]]; then
        [[ -e "$configured_port" ]] || die "$port_label not found: $configured_port"
        printf '%s' "$configured_port"
        return 0
    fi

    mapfile -t available_ports < <(discover_serial_ports)
    if (( ${#available_ports[@]} == 0 )); then
        die "No serial device found under /dev/serial/by-id, /dev/ttyUSB*, or /dev/ttyACM*"
    fi
    if (( ${#available_ports[@]} == 1 )); then
        printf '%s' "${available_ports[0]}"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        die "Multiple serial ports detected. Set --port or --log-port explicitly."
    fi

    info "Select $port_label"
    local index=1
    local selection=""
    local entry=""
    for entry in "${available_ports[@]}"; do
        printf '  %d. %s\n' "$index" "$entry"
        index=$((index + 1))
    done
    printf 'Selection: '
    read -r selection || die "Input aborted"
    [[ "$selection" =~ ^[0-9]+$ ]] || die "Invalid selection: $selection"
    (( selection >= 1 && selection <= ${#available_ports[@]} )) || die "Invalid selection: $selection"
    printf '%s' "${available_ports[$((selection - 1))]}"
}

wait_for_path() {
    local target_path="$1"
    local timeout_seconds="$2"
    local started_at=$SECONDS
    while (( SECONDS - started_at < timeout_seconds )); do
        if [[ -e "$target_path" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

configure_serial_port() {
    local serial_port="$1"
    local baud_rate="$2"
    stty -F "$serial_port" "$baud_rate" cs8 -cstopb -parenb -ixon -ixoff -crtscts -icanon -echo min 1 time 1
}

start_port_capture() {
    local serial_port="$1"
    local log_path="$2"
    local mirror_stdout="$3"
    cleanup_capture
    : > "$log_path"
    if is_true "$mirror_stdout"; then
        cat "$serial_port" | tee -a "$log_path" &
    else
        cat "$serial_port" >> "$log_path" &
    fi
    CAPTURE_PID=$!
    sleep 1
}

wait_for_log_pattern() {
    local log_path="$1"
    local pattern="$2"
    local timeout_seconds="$3"
    local started_at=$SECONDS
    while (( SECONDS - started_at < timeout_seconds )); do
        if grep -aEq "$pattern" "$log_path"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

send_serial_raw() {
    local serial_port="$1"
    local payload="$2"
    printf '%b' "$payload" > "$serial_port"
}

send_serial_line() {
    local serial_port="$1"
    local payload="$2"
    printf '%s\r' "$payload" > "$serial_port"
}

send_escape_burst() {
    local serial_port="$1"
    local repeat_count=24
    local current_count=0
    while (( current_count < repeat_count )); do
        printf '\033' > "$serial_port"
        sleep 0.1
        current_count=$((current_count + 1))
    done
}

extract_ip_from_log() {
    local log_path="$1"
    local detected_ip=""
    detected_ip=$(sed -nE 's/.*Interface 0 IP address[[:space:]]*:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$log_path" | tail -n 1)
    if [[ -n "$detected_ip" ]]; then
        printf '%s' "$detected_ip"
        return 0
    fi
    return 1
}

build_backup_binary() {
    local transcript_path="$1"
    local binary_path="$2"
    local filtered_path
    filtered_path=$(mktemp)
    grep -aE '^[0-9a-fA-F]{8}:' "$transcript_path" | sed 's/\r$//' > "$filtered_path"
    [[ -s "$filtered_path" ]] || die "Backup transcript does not contain valid flash dump lines"
    awk '{print $2 $3 $4 $5}' "$filtered_path" \
        | xxd -r -p \
        | xxd -e -g4 \
        | awk '{print $2 $3 $4 $5}' \
        | xxd -r -p > "$binary_path"
    rm -f "$filtered_path"
    [[ -s "$binary_path" ]] || die "Backup binary is empty"
}

perform_backup() {
    local serial_port="$1"
    local backup_log="$(session_path backup/backup-transcript.log)"
    local backup_bin="$(session_path backup/wbrg1-firmware.bin)"
    local attempt=1
    local prompt_pattern='(^|[\r\n])#|COMMAND MODE HELP'
    while (( attempt <= 3 )); do
        info "Backup attempt $attempt"
        info "To enter command mode, leave power disconnected from the adapter, power the gateway first, then connect the USB-UART adapter."
        prompt_continue "Prepare the gateway for command mode, then continue"
        configure_serial_port "$serial_port" "$BACKUP_BAUD"
        start_port_capture "$serial_port" "$backup_log" "false"
        send_escape_burst "$serial_port"
        send_serial_raw "$serial_port" "\r?\r"
        if wait_for_log_pattern "$backup_log" "$prompt_pattern" 15; then
            info "Command mode detected"
            send_serial_line "$serial_port" "flash read 0 2097152"
            if wait_for_log_pattern "$backup_log" '^007ffff0:' 600; then
                cleanup_capture
                build_backup_binary "$backup_log" "$backup_bin"
                sha256sum "$backup_bin" > "$(session_path backup/SHA256SUMS)"
                info "Backup saved to $backup_bin"
                return 0
            fi
            cleanup_capture
            die "Timed out while waiting for the backup dump to finish"
        fi
        cleanup_capture
        warn "Command mode was not detected on attempt $attempt"
        attempt=$((attempt + 1))
    done
    die "Unable to enter command mode for backup after 3 attempts"
}

print_staged_firmware_summary() {
    info "Staged firmware:"
    local image_name=""
    for image_name in "${REQUIRED_IMAGE_NAMES[@]}"; do
        printf '  %s\n' "$FIRMWARE_STAGE_DIR/$image_name"
    done
    printf '  %s\n' "$FIRMWARE_STAGE_DIR/SHA256SUMS"
}

perform_flash() {
    local serial_port="$1"
    local erase_log="$(session_path logs/flash-erase.log)"
    local flash_log="$(session_path logs/flash-download.log)"
    print_staged_firmware_summary
    info "The uploader expects the gateway to be powered first and the USB-UART adapter connected second."
    prompt_continue "Ready to erase and flash through $serial_port"
    "$UPLOAD_TOOL_PATH" "$FIRMWARE_STAGE_DIR" "$serial_port" ameba_rtl8721csm Enable Enable "$FLASH_BAUD" >"$erase_log" 2>&1 || die "Flash erase failed. See $erase_log"
    "$UPLOAD_TOOL_PATH" "$FIRMWARE_STAGE_DIR" "$serial_port" ameba_rtl8721csm Enable Disable "$FLASH_BAUD" >"$flash_log" 2>&1 || die "Firmware download failed. See $flash_log"
    info "Flash completed. Logs saved to $erase_log and $flash_log"
}

ensure_wifi_credentials() {
    if [[ -z "$SSID" && ! -t 0 ]]; then
        die "SSID is empty and stdin is not interactive. Set SSID in config or pass --ssid."
    fi
    if [[ -n "$SSID" && -z "$PASSPHRASE" ]]; then
        if [[ ! -t 0 ]]; then
            die "SSID is set but PASSPHRASE is empty. Set PASSPHRASE in config or pass --passphrase."
        fi
        printf 'Wi-Fi passphrase: '
        read -r -s PASSPHRASE || die "Input aborted"
        printf '\n'
    fi
}

write_zigbee2mqtt_config() {
    local gateway_ip="$1"
    local yaml_path="$(session_path zigbee2mqtt.yaml)"
    cat > "$yaml_path" <<EOF
serial:
  adapter: $Z2M_ADAPTER
  baudrate: $Z2M_BAUDRATE
  port: tcp://$gateway_ip:80
  rtscts: ${Z2M_RTSCTS,,}
EOF
    info "Zigbee2MQTT config:"
    cat "$yaml_path"
    info "Saved Zigbee2MQTT config to $yaml_path"
}

perform_wifi_setup() {
    local serial_port="$1"
    local wifi_log="$(session_path logs/wifi-session.log)"
    local detected_ip=""
    ensure_wifi_credentials
    info "Power-cycle the gateway if needed, then connect the log UART."
    prompt_continue "Ready to start the Wi-Fi setup session on $serial_port"
    wait_for_path "$serial_port" 60 || die "Serial port did not appear: $serial_port"
    configure_serial_port "$serial_port" "$BACKUP_BAUD"
    start_port_capture "$serial_port" "$wifi_log" "true"
    info "Wi-Fi log session started. Session log: $wifi_log"
    info "Type AT commands directly and press Enter. Type exit to stop the session."
    info "Typical commands: ATW0=<ssid>, ATW1=<passphrase>, ATWC"

    if [[ -n "$SSID" ]]; then
        info "Sending ATW0"
        send_serial_line "$serial_port" "ATW0=$SSID"
        sleep 1
    fi
    if [[ -n "$PASSPHRASE" ]]; then
        info "Sending ATW1"
        send_serial_line "$serial_port" "ATW1=$PASSPHRASE"
        sleep 1
    fi
    if [[ -n "$SSID" && -n "$PASSPHRASE" ]]; then
        info "Sending ATWC"
        send_serial_line "$serial_port" "ATWC"
    fi

    local started_at=$SECONDS
    local manual_input=""
    while (( SECONDS - started_at < 180 )); do
        if detected_ip=$(extract_ip_from_log "$wifi_log"); then
            cleanup_capture
            write_zigbee2mqtt_config "$detected_ip"
            return 0
        fi
        if [[ -t 0 ]]; then
            if IFS= read -r -t 1 manual_input; then
                if [[ "$manual_input" == "exit" ]]; then
                    cleanup_capture
                    die "Wi-Fi session stopped before an IP address was detected"
                fi
                if [[ -n "$manual_input" ]]; then
                    send_serial_line "$serial_port" "$manual_input"
                fi
            fi
        else
            sleep 1
        fi
    done
    cleanup_capture
    die "Timed out waiting for the gateway IP address. See $wifi_log"
}

run_download_command() {
    stage_firmware
    print_staged_firmware_summary
}

run_backup_command() {
    PORT=$(choose_serial_port "flash port" "$PORT")
    LOG_PORT="${LOG_PORT:-$PORT}"
    info "Selected flash port: $PORT"
    perform_backup "$PORT"
}

run_flash_command() {
    stage_firmware
    resolve_upload_tool_path
    PORT=$(choose_serial_port "flash port" "$PORT")
    LOG_PORT="${LOG_PORT:-$PORT}"
    info "Selected flash port: $PORT"
    info "Using upload tool: $UPLOAD_TOOL_PATH"
    perform_flash "$PORT"
}

run_wifi_command() {
    LOG_PORT=$(choose_serial_port "log port" "${LOG_PORT:-$PORT}")
    info "Selected log port: $LOG_PORT"
    perform_wifi_setup "$LOG_PORT"
}

run_all_command() {
    stage_firmware
    resolve_upload_tool_path
    PORT=$(choose_serial_port "flash port" "$PORT")
    LOG_PORT="${LOG_PORT:-$PORT}"
    info "Selected flash port: $PORT"
    info "Selected log port: $LOG_PORT"
    info "Using upload tool: $UPLOAD_TOOL_PATH"
    if ! is_true "$SKIP_BACKUP"; then
        perform_backup "$PORT"
    fi
    perform_flash "$PORT"
    if ! is_true "$SKIP_WIFI"; then
        perform_wifi_setup "$LOG_PORT"
    fi
}

main() {
    set_defaults
    preparse_args "$@"
    ensure_default_config_ready
    if [[ -n "$EXPLICIT_CONFIG" ]]; then
        load_config_file "$(resolve_root_path "$EXPLICIT_CONFIG")" "true"
    else
        load_config_file "$DEFAULT_CONFIG_FILE" "false"
        load_config_file "$LOCAL_CONFIG_FILE" "false"
    fi
    parse_cli_args "$@"
    preflight_checks
    prepare_session
    info "Session directory: $SESSION_DIR"
    if (( ${#LOADED_CONFIG_FILES[@]} > 0 )); then
        info "Loaded config files:"
        local loaded_config=""
        for loaded_config in "${LOADED_CONFIG_FILES[@]}"; do
            printf '  %s\n' "$loaded_config"
        done
    fi

    case "$COMMAND" in
        download)
            run_download_command
            ;;
        backup)
            run_backup_command
            ;;
        flash)
            run_flash_command
            ;;
        wifi)
            run_wifi_command
            ;;
        all)
            run_all_command
            ;;
        *)
            die "Unknown command: $COMMAND"
            ;;
    esac
    info "Completed. Session data is available in $SESSION_DIR"
}

main "$@"
