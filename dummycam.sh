#!/usr/bin/env bash

# Virtual Webcam Setup Script
# Creates virtual video devices and feeds them test patterns using v4l2loopback + FFmpeg

set -eou pipefail

# Configuration
DEFAULT_WIDTH=1280
DEFAULT_HEIGHT=720
DEFAULT_FPS=30

# Available test patterns (FFmpeg lavfi sources)
PATTERNS=(
    "smptebars"      # Classic SMPTE color bars
    "testsrc2"       # Modern test pattern with moving elements
    "testsrc"        # Classic test pattern
    "rgbtestsrc"     # RGB test pattern
    "pal100bars"     # PAL color bars
    "colorchart"     # Color chart
)

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  setup <count>       Load v4l2loopback with <count> virtual devices"
    echo "  start <device> <pattern>  Start feeding a pattern to a device"
    echo "  stop                Stop all running pattern feeds"
    echo "  list                List available devices and patterns"
    echo "  unload              Unload v4l2loopback module"
    echo ""
    echo "Options:"
    echo "  -w, --width <px>    Video width (default: $DEFAULT_WIDTH)"
    echo "  -h, --height <px>   Video height (default: $DEFAULT_HEIGHT)"
    echo "  -f, --fps <fps>     Frame rate (default: $DEFAULT_FPS)"
    echo ""
    echo "Examples:"
    echo "  $0 setup 2                      # Create 2 virtual webcams"
    echo "  $0 start /dev/video10 smptebars # Feed SMPTE bars to video10"
    echo "  $0 start /dev/video11 testsrc2  # Feed test pattern to video11"
    echo "  $0 list                         # Show devices and patterns"
    echo "  $0 stop                         # Stop all feeds"
    echo ""
    echo "Available patterns: ${PATTERNS[*]}"
}

check_dependencies() {
    local missing=()
    
    if ! command -v ffmpeg &> /dev/null; then
        missing+=("ffmpeg")
    fi
    
    if ! command -v v4l2-ctl &> /dev/null; then
        missing+=("v4l2-ctl (v4l-utils)")
    fi
    
    if ! modinfo v4l2loopback &> /dev/null 2>&1; then
        missing+=("v4l2loopback-dkms")
    fi
    
    if [ ${#missing[@]} -ne 0 ]; then
        echo "Error: Missing dependencies: ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  sudo apt install ffmpeg v4l-utils v4l2loopback-dkms v4l2loopback-utils"
        exit 1
    fi
}

setup_devices() {
    local count=${1:-1}
    
    if lsmod | grep -q v4l2loopback; then
        echo "v4l2loopback already loaded. Unload first with: $0 unload"
        exit 1
    fi
    
    # Generate device numbers and labels
    local video_nrs=""
    local labels=""
    for ((i=0; i<count; i++)); do
        video_nrs+="$((10 + i)),"
        labels+="\"VCam$((i + 1))\","
    done
    video_nrs=${video_nrs%,}
    labels=${labels%,}
    
    echo "Loading v4l2loopback with $count device(s)..."
    sudo modprobe v4l2loopback devices="$count" video_nr="$video_nrs" card_label="$labels" exclusive_caps=0
    
    echo "Created virtual devices:"
    for ((i=0; i<count; i++)); do
        echo "  /dev/video$((10 + i)) (VCam$((i + 1)))"
    done
}

start_pattern() {
    local device=$1
    local pattern=$2
    local width=${WIDTH:-$DEFAULT_WIDTH}
    local height=${HEIGHT:-$DEFAULT_HEIGHT}
    local fps=${FPS:-$DEFAULT_FPS}
    
    if [ -z "$device" ] || [ -z "$pattern" ]; then
        echo "Error: Device and pattern required"
        usage
        exit 1
    fi
    
    if [ ! -e "$device" ]; then
        echo "Error: Device $device does not exist"
        echo "Run '$0 setup <count>' first"
        exit 1
    fi
    
    # Validate pattern
    local valid=0
    for p in "${PATTERNS[@]}"; do
        if [ "$p" == "$pattern" ]; then
            valid=1
            break
        fi
    done
    
    if [ $valid -eq 0 ]; then
        echo "Error: Unknown pattern '$pattern'"
        echo "Available: ${PATTERNS[*]}"
        exit 1
    fi
    
    echo "Starting $pattern (${width}x${height}@${fps}fps) on $device..."
    echo "Press Ctrl+C to stop, or run '$0 stop' from another terminal"
    
    ffmpeg -loglevel warning -f lavfi \
        -i "${pattern}=size=${width}x${height}:rate=${fps}" \
        -vf format=yuv420p \
        -f v4l2 "$device"
}

stop_feeds() {
    echo "Stopping all FFmpeg pattern feeds..."
    pkill -f "ffmpeg.*v4l2loopback\|ffmpeg.*-f v4l2" 2>/dev/null || true
    echo "Done"
}

list_info() {
    echo "=== Available Test Patterns ==="
    for p in "${PATTERNS[@]}"; do
        echo "  $p"
    done
    echo ""
    echo "=== Video Devices ==="
    if command -v v4l2-ctl &> /dev/null; then
        v4l2-ctl --list-devices 2>/dev/null || echo "  No devices found (run '$0 setup' first)"
    else
        ls -la /dev/video* 2>/dev/null || echo "  No video devices found"
    fi
}

unload_module() {
    stop_feeds
    echo "Unloading v4l2loopback..."
    sudo modprobe -r v4l2loopback 2>/dev/null || echo "Module not loaded"
    echo "Done"
}

# Parse global options
WIDTH=$DEFAULT_WIDTH
HEIGHT=$DEFAULT_HEIGHT
FPS=$DEFAULT_FPS

while [[ $# -gt 0 ]]; do
    case $1 in
        -w|--width)  WIDTH="$2"; shift 2 ;;
        -h|--height) HEIGHT="$2"; shift 2 ;;
        -f|--fps)    FPS="$2"; shift 2 ;;
        setup)       check_dependencies; setup_devices "$2"; exit 0 ;;
        start)       check_dependencies; start_pattern "$2" "$3"; exit 0 ;;
        stop)        stop_feeds; exit 0 ;;
        list)        list_info; exit 0 ;;
        unload)      unload_module; exit 0 ;;
        help|--help) usage; exit 0 ;;
        *)           echo "Unknown command: $1"; usage; exit 1 ;;
    esac
done

usage
