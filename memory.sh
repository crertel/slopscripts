#!/usr/bin/env bash
#
# memory.sh - ASCII-art diagram of system memory setup
# Displays RAM topology, usage, and swap configuration
#

set -o pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Colors and Formatting
# ─────────────────────────────────────────────────────────────────────────────
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly MAGENTA='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly GRAY='\033[0;90m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RESET='\033[0m'

# Box drawing characters
readonly TL='╔' TR='╗' BL='╚' BR='╝'
readonly H='═' V='║'
readonly LT='╠' RT='╣' TT='╦' BT='╩' CR='╬'

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

# Convert KB to human readable (pure bash, no bc dependency)
human_kb() {
    local kb=$1
    if [[ -z "$kb" || "$kb" == "0" ]]; then
        echo "0"
        return
    fi

    # Use awk for floating point (available on all systems)
    if ((kb >= 1073741824)); then
        awk "BEGIN {printf \"%.1f TiB\", $kb / 1073741824}"
    elif ((kb >= 1048576)); then
        awk "BEGIN {printf \"%.1f GiB\", $kb / 1048576}"
    elif ((kb >= 1024)); then
        awk "BEGIN {printf \"%.1f MiB\", $kb / 1024}"
    else
        printf "%d KiB" "$kb"
    fi
}

# Draw a horizontal line
draw_line() {
    local width=$1
    local char=${2:-$H}
    printf '%*s' "$width" '' | tr ' ' "$char"
}

# Draw a usage bar
draw_bar() {
    local used=$1
    local total=$2
    local width=${3:-40}
    local label=${4:-""}

    if ((total == 0)); then
        printf "[%s]" "$(draw_line $width '-')"
        return
    fi

    local pct=$((used * 100 / total))
    local filled=$((used * width / total))
    local empty=$((width - filled))

    # Color based on percentage
    local color
    if ((pct >= 90)); then
        color=$RED
    elif ((pct >= 70)); then
        color=$YELLOW
    else
        color=$GREEN
    fi

    printf "["
    printf "${color}"
    printf '%*s' "$filled" '' | tr ' ' '█'
    printf "${RESET}"
    printf '%*s' "$empty" '' | tr ' ' '░'
    printf "] %3d%%" "$pct"
}

# ─────────────────────────────────────────────────────────────────────────────
# Memory Information Gathering
# ─────────────────────────────────────────────────────────────────────────────

get_meminfo() {
    local field=$1
    grep "^${field}:" /proc/meminfo 2>/dev/null | awk '{print $2}'
}

# ─────────────────────────────────────────────────────────────────────────────
# Physical Memory Topology (DIMM slots)
# ─────────────────────────────────────────────────────────────────────────────

print_dimm_diagram() {
    echo -e "\n${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${CYAN}│${RESET}  ${WHITE}Physical Memory Topology${RESET}                                                  ${BOLD}${CYAN}│${RESET}"
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${RESET}"

    # Try to get DMI information (requires root)
    if [[ $EUID -eq 0 ]] && command -v dmidecode &>/dev/null; then
        local dimm_info
        dimm_info=$(dmidecode -t memory 2>/dev/null)

        if [[ -n "$dimm_info" ]]; then
            # Get memory array info
            local max_capacity=$(echo "$dimm_info" | grep "Maximum Capacity:" | head -1 | awk -F: '{print $2}' | xargs)
            local num_devices=$(echo "$dimm_info" | grep "Number Of Devices:" | head -1 | awk -F: '{print $2}' | xargs)

            echo -e "\n  ${DIM}Max Capacity: ${max_capacity:-Unknown} | Slots: ${num_devices:-Unknown}${RESET}\n"

            echo -e "  ${GRAY}┌────────────────────────────────────────────────────────────────────────┐${RESET}"

            # Parse memory devices using awk - outputs: locator|size|type|speed|manufacturer
            local total_installed=0
            while IFS='|' read -r locator size type speed manufacturer; do
                [[ -z "$locator" ]] && continue

                # Draw DIMM slot
                if [[ "$size" == "No Module Installed" || -z "$size" || "$size" == "Unknown" ]]; then
                    echo -e "  ${GRAY}│${RESET}  ┌─────────┐                                                          ${GRAY}│${RESET}"
                    printf "  ${GRAY}│${RESET}  │ ${DIM}EMPTY${RESET}   │  ${DIM}%-12s${RESET}                                         ${GRAY}│${RESET}\n" "$locator"
                    echo -e "  ${GRAY}│${RESET}  └─────────┘                                                          ${GRAY}│${RESET}"
                else
                    total_installed=$((total_installed + 1))
                    echo -e "  ${GRAY}│${RESET}  ${GREEN}┌─────────┐${RESET}                                                          ${GRAY}│${RESET}"
                    printf "  ${GRAY}│${RESET}  ${GREEN}│${RESET} ${BOLD}%-7s ${GREEN}│${RESET}  %-12s ${CYAN}%-6s${RESET} ${MAGENTA}%-12s${RESET} ${DIM}%-10s${RESET}${GRAY}│${RESET}\n" \
                        "$size" "$locator" "$type" "$speed" "$manufacturer"
                    echo -e "  ${GRAY}│${RESET}  ${GREEN}└─────────┘${RESET}                                                          ${GRAY}│${RESET}"
                fi
            done < <(echo "$dimm_info" | awk '
                /^Memory Device$/ {
                    if (locator != "") {
                        print locator "|" size "|" type "|" speed "|" manufacturer
                    }
                    locator = ""; size = ""; type = ""; speed = ""; manufacturer = ""
                    in_device = 1
                    next
                }
                /^Handle.*DMI type 17/ { in_device = 1; next }
                /^Handle/ { in_device = 0 }
                in_device && /^\tLocator:/ {
                    gsub(/^\tLocator:[ \t]*/, "")
                    locator = $0
                }
                in_device && /^\tSize:/ {
                    gsub(/^\tSize:[ \t]*/, "")
                    size = $0
                }
                in_device && /^\tType:/ && !/Type Detail/ {
                    gsub(/^\tType:[ \t]*/, "")
                    type = $0
                }
                in_device && /^\tSpeed:/ && !/Configured/ {
                    gsub(/^\tSpeed:[ \t]*/, "")
                    speed = $0
                }
                in_device && /^\tManufacturer:/ {
                    gsub(/^\tManufacturer:[ \t]*/, "")
                    if ($0 != "Not Specified") manufacturer = $0
                }
                END {
                    if (locator != "") {
                        print locator "|" size "|" type "|" speed "|" manufacturer
                    }
                }
            ')

            echo -e "  ${GRAY}└────────────────────────────────────────────────────────────────────────┘${RESET}"
            echo -e "\n  ${DIM}Installed: ${total_installed} module(s)${RESET}"
        fi
    else
        echo -e "\n  ${YELLOW}⚠ Run as root to see DIMM slot details (requires dmidecode)${RESET}"

        # Fallback: show basic info from /proc/meminfo
        local total_kb=$(get_meminfo "MemTotal")
        local total_human=$(human_kb "$total_kb")

        echo -e "\n  ${GRAY}┌────────────────────────────────────────────────────────────────────────┐${RESET}"
        echo -e "  ${GRAY}│${RESET}                                                                        ${GRAY}│${RESET}"
        echo -e "  ${GRAY}│${RESET}    ${GREEN}┌─────────────────────────────────────────────────────────┐${RESET}       ${GRAY}│${RESET}"
        echo -e "  ${GRAY}│${RESET}    ${GREEN}│${RESET}                                                         ${GREEN}│${RESET}       ${GRAY}│${RESET}"
        printf "  ${GRAY}│${RESET}    ${GREEN}│${RESET}           ${BOLD}${WHITE}System RAM: %-20s${RESET}        ${GREEN}│${RESET}       ${GRAY}│${RESET}\n" "$total_human"
        echo -e "  ${GRAY}│${RESET}    ${GREEN}│${RESET}                                                         ${GREEN}│${RESET}       ${GRAY}│${RESET}"
        echo -e "  ${GRAY}│${RESET}    ${GREEN}└─────────────────────────────────────────────────────────┘${RESET}       ${GRAY}│${RESET}"
        echo -e "  ${GRAY}│${RESET}                                                                        ${GRAY}│${RESET}"
        echo -e "  ${GRAY}└────────────────────────────────────────────────────────────────────────┘${RESET}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Memory Usage Diagram
# ─────────────────────────────────────────────────────────────────────────────

print_memory_usage() {
    echo -e "\n${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${CYAN}│${RESET}  ${WHITE}Memory Usage Breakdown${RESET}                                                    ${BOLD}${CYAN}│${RESET}"
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${RESET}"

    # Get memory values (in KB)
    local mem_total=$(get_meminfo "MemTotal")
    local mem_free=$(get_meminfo "MemFree")
    local mem_available=$(get_meminfo "MemAvailable")
    local buffers=$(get_meminfo "Buffers")
    local cached=$(get_meminfo "Cached")
    local slab=$(get_meminfo "Slab")
    local sreclaimable=$(get_meminfo "SReclaimable")
    local sunreclaim=$(get_meminfo "SUnreclaim")
    local shmem=$(get_meminfo "Shmem")
    local swap_total=$(get_meminfo "SwapTotal")
    local swap_free=$(get_meminfo "SwapFree")
    local dirty=$(get_meminfo "Dirty")
    local writeback=$(get_meminfo "Writeback")
    local anon_pages=$(get_meminfo "AnonPages")
    local mapped=$(get_meminfo "Mapped")
    local kernel_stack=$(get_meminfo "KernelStack")
    local page_tables=$(get_meminfo "PageTables")
    local hugepages_total=$(get_meminfo "HugePages_Total")
    local hugepage_size=$(get_meminfo "Hugepagesize")

    # Calculate derived values
    local mem_used=$((mem_total - mem_free - buffers - cached))
    local swap_used=$((swap_total - swap_free))
    local cache_total=$((buffers + cached))
    local kernel_mem=$((slab + kernel_stack + page_tables))

    echo ""

    # Main memory bar
    echo -e "  ${BOLD}Total RAM:${RESET}     $(human_kb $mem_total)"
    echo -e "  $(draw_bar $((mem_total - mem_available)) $mem_total 50 "used")"
    echo ""

    # Memory breakdown ASCII diagram
    echo -e "  ${GRAY}┌──────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "  ${GRAY}│${RESET} ${BOLD}Memory Map${RESET}                                                           ${GRAY}│${RESET}"
    echo -e "  ${GRAY}├──────────────────────────────────────────────────────────────────────┤${RESET}"

    # Calculate percentages for visual representation
    local total=$mem_total
    local user_pct=$((anon_pages * 100 / total))
    local cache_pct=$((cache_total * 100 / total))
    local kernel_pct=$((kernel_mem * 100 / total))
    local free_pct=$((mem_free * 100 / total))

    # Visual memory map
    printf "  ${GRAY}│${RESET}                                                                      ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}  ${RED}┌─ User/Apps ────────────────────────────────────┐${RESET}                 ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}  ${RED}│${RESET} Anonymous Pages:    %12s  (%2d%%)        ${RED}│${RESET}                 ${GRAY}│${RESET}\n" "$(human_kb $anon_pages)" "$user_pct"
    printf "  ${GRAY}│${RESET}  ${RED}│${RESET} Mapped Files:       %12s               ${RED}│${RESET}                 ${GRAY}│${RESET}\n" "$(human_kb $mapped)"
    printf "  ${GRAY}│${RESET}  ${RED}│${RESET} Shared Memory:      %12s               ${RED}│${RESET}                 ${GRAY}│${RESET}\n" "$(human_kb $shmem)"
    printf "  ${GRAY}│${RESET}  ${RED}└────────────────────────────────────────────────┘${RESET}                 ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}                                                                      ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}  ${YELLOW}┌─ Cache/Buffers ─────────────────────────────────┐${RESET}                ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}  ${YELLOW}│${RESET} Page Cache:        %12s  (%2d%%)        ${YELLOW}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $cached)" "$cache_pct"
    printf "  ${GRAY}│${RESET}  ${YELLOW}│${RESET} Buffers:           %12s               ${YELLOW}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $buffers)"
    printf "  ${GRAY}│${RESET}  ${YELLOW}│${RESET} Dirty:             %12s               ${YELLOW}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $dirty)"
    printf "  ${GRAY}│${RESET}  ${YELLOW}│${RESET} Writeback:         %12s               ${YELLOW}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $writeback)"
    printf "  ${GRAY}│${RESET}  ${YELLOW}└────────────────────────────────────────────────┘${RESET}                ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}                                                                      ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}  ${MAGENTA}┌─ Kernel ────────────────────────────────────────┐${RESET}                ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}  ${MAGENTA}│${RESET} Slab (reclaimable): %12s              ${MAGENTA}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $sreclaimable)"
    printf "  ${GRAY}│${RESET}  ${MAGENTA}│${RESET} Slab (unreclaim):   %12s              ${MAGENTA}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $sunreclaim)"
    printf "  ${GRAY}│${RESET}  ${MAGENTA}│${RESET} Kernel Stack:       %12s              ${MAGENTA}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $kernel_stack)"
    printf "  ${GRAY}│${RESET}  ${MAGENTA}│${RESET} Page Tables:        %12s              ${MAGENTA}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $page_tables)"
    printf "  ${GRAY}│${RESET}  ${MAGENTA}└────────────────────────────────────────────────┘${RESET}                ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}                                                                      ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}  ${GREEN}┌─ Free ──────────────────────────────────────────┐${RESET}                ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}  ${GREEN}│${RESET} Free Memory:       %12s  (%2d%%)        ${GREEN}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $mem_free)" "$free_pct"
    printf "  ${GRAY}│${RESET}  ${GREEN}│${RESET} Available:         %12s               ${GREEN}│${RESET}                ${GRAY}│${RESET}\n" "$(human_kb $mem_available)"
    printf "  ${GRAY}│${RESET}  ${GREEN}└────────────────────────────────────────────────┘${RESET}                ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}                                                                      ${GRAY}│${RESET}\n"
    echo -e "  ${GRAY}└──────────────────────────────────────────────────────────────────────┘${RESET}"

    # Huge pages if configured
    if [[ -n "$hugepages_total" && "$hugepages_total" != "0" ]]; then
        local hp_free=$(get_meminfo "HugePages_Free")
        local hp_used=$((hugepages_total - hp_free))
        local hp_size_total=$((hugepages_total * hugepage_size))

        echo -e "\n  ${BOLD}Huge Pages:${RESET}"
        printf "    Total: %d × %s = %s\n" "$hugepages_total" "$(human_kb $hugepage_size)" "$(human_kb $hp_size_total)"
        printf "    Used:  %d  Free: %d\n" "$hp_used" "$hp_free"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Swap Diagram
# ─────────────────────────────────────────────────────────────────────────────

print_swap_diagram() {
    echo -e "\n${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${CYAN}│${RESET}  ${WHITE}Swap Configuration${RESET}                                                       ${BOLD}${CYAN}│${RESET}"
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${RESET}"

    local swap_total=$(get_meminfo "SwapTotal")
    local swap_free=$(get_meminfo "SwapFree")
    local swap_cached=$(get_meminfo "SwapCached")
    local swap_used=$((swap_total - swap_free))

    if [[ "$swap_total" == "0" || -z "$swap_total" ]]; then
        echo -e "\n  ${DIM}No swap configured${RESET}"
        return
    fi

    echo ""
    echo -e "  ${BOLD}Total Swap:${RESET}    $(human_kb $swap_total)"
    echo -e "  $(draw_bar $swap_used $swap_total 50 "used")"
    echo ""

    # Get individual swap devices/files
    echo -e "  ${GRAY}┌──────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "  ${GRAY}│${RESET} ${BOLD}Swap Devices${RESET}                                                         ${GRAY}│${RESET}"
    echo -e "  ${GRAY}├──────────────────────────────────────────────────────────────────────┤${RESET}"

    if [[ -r /proc/swaps ]]; then
        local first=true
        while read -r filename type size used priority; do
            [[ "$filename" == "Filename" ]] && continue

            local pct=0
            ((size > 0)) && pct=$((used * 100 / size))

            # Determine icon
            local icon="📄"
            [[ "$type" == "partition" ]] && icon="💾"
            [[ "$filename" == *"zram"* ]] && icon="⚡"

            printf "  ${GRAY}│${RESET}                                                                      ${GRAY}│${RESET}\n"
            printf "  ${GRAY}│${RESET}   %s %-40s                       ${GRAY}│${RESET}\n" "$icon" "$filename"
            printf "  ${GRAY}│${RESET}      Type: %-12s  Priority: %-6s                         ${GRAY}│${RESET}\n" "$type" "$priority"
            printf "  ${GRAY}│${RESET}      Size: %-12s  Used: %-12s (%d%%)                ${GRAY}│${RESET}\n" "$(human_kb $size)" "$(human_kb $used)" "$pct"
        done < /proc/swaps
    fi

    printf "  ${GRAY}│${RESET}                                                                      ${GRAY}│${RESET}\n"
    printf "  ${GRAY}│${RESET}   ${DIM}Swap Cached: %s${RESET}                                              ${GRAY}│${RESET}\n" "$(human_kb $swap_cached)"
    echo -e "  ${GRAY}└──────────────────────────────────────────────────────────────────────┘${RESET}"

    # Swappiness
    local swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    if [[ -n "$swappiness" ]]; then
        echo -e "\n  ${DIM}vm.swappiness = ${swappiness}${RESET}"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# NUMA Topology (if applicable)
# ─────────────────────────────────────────────────────────────────────────────

print_numa_diagram() {
    # Check if NUMA is available
    if [[ ! -d /sys/devices/system/node/node0 ]]; then
        return
    fi

    local num_nodes=$(ls -d /sys/devices/system/node/node[0-9]* 2>/dev/null | wc -l)

    # Skip if only one node (not really NUMA)
    ((num_nodes <= 1)) && return

    echo -e "\n${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${CYAN}│${RESET}  ${WHITE}NUMA Topology${RESET}                                                            ${BOLD}${CYAN}│${RESET}"
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${RESET}"

    echo ""
    echo -e "  ${GRAY}┌──────────────────────────────────────────────────────────────────────┐${RESET}"

    for node_dir in /sys/devices/system/node/node[0-9]*; do
        local node=$(basename "$node_dir")
        local node_num=${node#node}

        # Get memory info for this node
        local meminfo="$node_dir/meminfo"
        local node_total=0
        local node_free=0

        if [[ -r "$meminfo" ]]; then
            node_total=$(grep "MemTotal:" "$meminfo" | awk '{print $4}')
            node_free=$(grep "MemFree:" "$meminfo" | awk '{print $4}')
        fi

        local node_used=$((node_total - node_free))

        # Get CPUs for this node
        local cpulist=""
        if [[ -r "$node_dir/cpulist" ]]; then
            cpulist=$(cat "$node_dir/cpulist")
        fi

        echo -e "  ${GRAY}│${RESET}                                                                      ${GRAY}│${RESET}"
        echo -e "  ${GRAY}│${RESET}   ${BLUE}┌─ Node ${node_num} ─────────────────────────────────────────────┐${RESET}       ${GRAY}│${RESET}"
        printf "  ${GRAY}│${RESET}   ${BLUE}│${RESET}  Memory: %-10s / %-10s                       ${BLUE}│${RESET}       ${GRAY}│${RESET}\n" \
            "$(human_kb $node_used)" "$(human_kb $node_total)"
        printf "  ${GRAY}│${RESET}   ${BLUE}│${RESET}  CPUs:   %-40s   ${BLUE}│${RESET}       ${GRAY}│${RESET}\n" "$cpulist"
        echo -e "  ${GRAY}│${RESET}   ${BLUE}│${RESET}  $(draw_bar $node_used $node_total 35)           ${BLUE}│${RESET}       ${GRAY}│${RESET}"
        echo -e "  ${GRAY}│${RESET}   ${BLUE}└────────────────────────────────────────────────────────┘${RESET}       ${GRAY}│${RESET}"
    done

    echo -e "  ${GRAY}│${RESET}                                                                      ${GRAY}│${RESET}"
    echo -e "  ${GRAY}└──────────────────────────────────────────────────────────────────────┘${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Top Memory Consumers
# ─────────────────────────────────────────────────────────────────────────────

print_top_processes() {
    echo -e "\n${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${CYAN}│${RESET}  ${WHITE}Top Memory Consumers${RESET}                                                     ${BOLD}${CYAN}│${RESET}"
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${RESET}"

    echo ""
    printf "  ${BOLD}%-8s %-10s %-8s %-8s  %-40s${RESET}\n" "PID" "USER" "RSS" "%MEM" "COMMAND"
    echo -e "  ${GRAY}────────────────────────────────────────────────────────────────────────────${RESET}"

    # Get top 10 processes by RSS
    ps aux --sort=-%mem 2>/dev/null | head -11 | tail -10 | while read -r user pid cpu mem vsz rss tty stat start time cmd; do
        # Truncate command
        local short_cmd="${cmd:0:40}"
        [[ ${#cmd} -gt 40 ]] && short_cmd="${short_cmd:0:37}..."

        printf "  %-8s %-10s %-8s %-8s  %-40s\n" "$pid" "${user:0:10}" "$(human_kb $rss)" "${mem}%" "$short_cmd"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    echo -e "\n${BOLD}${CYAN}┌─────────────────────────────────────────────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}${CYAN}│${RESET}  ${WHITE}Summary${RESET}                                                                   ${BOLD}${CYAN}│${RESET}"
    echo -e "${BOLD}${CYAN}└─────────────────────────────────────────────────────────────────────────────┘${RESET}"

    local mem_total=$(get_meminfo "MemTotal")
    local mem_available=$(get_meminfo "MemAvailable")
    local mem_used=$((mem_total - mem_available))
    local swap_total=$(get_meminfo "SwapTotal")
    local swap_free=$(get_meminfo "SwapFree")
    local swap_used=$((swap_total - swap_free))

    local mem_pct=$((mem_used * 100 / mem_total))
    local swap_pct=0
    ((swap_total > 0)) && swap_pct=$((swap_used * 100 / swap_total))

    echo ""
    printf "  ${BOLD}RAM:${RESET}  %s used / %s total (%d%%)\n" "$(human_kb $mem_used)" "$(human_kb $mem_total)" "$mem_pct"

    if ((swap_total > 0)); then
        printf "  ${BOLD}Swap:${RESET} %s used / %s total (%d%%)\n" "$(human_kb $swap_used)" "$(human_kb $swap_total)" "$swap_pct"
    else
        echo -e "  ${BOLD}Swap:${RESET} ${DIM}Not configured${RESET}"
    fi

    # Memory pressure assessment
    echo ""
    if ((mem_pct >= 90)); then
        echo -e "  ${RED}⚠ Memory pressure: HIGH - System may be swapping heavily${RESET}"
    elif ((mem_pct >= 70)); then
        echo -e "  ${YELLOW}◆ Memory pressure: MODERATE - Monitor usage${RESET}"
    else
        echo -e "  ${GREEN}● Memory pressure: LOW - System healthy${RESET}"
    fi

    echo -e "\n  ${DIM}Generated: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo -e "${BOLD}${WHITE}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║             🧠 System Memory Diagram Tool 🧠                  ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    print_dimm_diagram
    print_memory_usage
    print_swap_diagram
    print_numa_diagram
    print_top_processes
    print_summary

    echo ""
}

main "$@"
