#!/usr/bin/env bash
#
# drive-health.sh - At-a-glance drive and ZFS array health assessment
# Displays SMART status, hours, errors, capacity for all drives + ZFS pool status
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

# Status indicators
readonly OK="${GREEN}●${RESET}"
readonly WARN="${YELLOW}●${RESET}"
readonly CRIT="${RED}●${RESET}"
readonly UNKNOWN="${GRAY}○${RESET}"

# ─────────────────────────────────────────────────────────────────────────────
# Helper Functions
# ─────────────────────────────────────────────────────────────────────────────

print_header() {
    echo -e "\n${BOLD}${CYAN}╔════════════════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║${RESET}  ${WHITE}$1${RESET}"
    echo -e "${BOLD}${CYAN}╚════════════════════════════════════════════════════════════════════════════════╝${RESET}"
}

print_subheader() {
    echo -e "\n${BOLD}${BLUE}── $1 ──${RESET}"
}

# Format bytes to human readable
human_size() {
    local bytes=$1
    if [[ -z "$bytes" || "$bytes" == "0" ]]; then
        echo "N/A"
        return
    fi
    numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
}

# Format hours to days/hours
format_hours() {
    local hours=$1
    if [[ -z "$hours" || "$hours" == "N/A" ]]; then
        echo "N/A"
        return
    fi
    local days=$((hours / 24))
    local rem_hours=$((hours % 24))
    if ((days > 0)); then
        printf "%dd %dh" "$days" "$rem_hours"
    else
        printf "%dh" "$hours"
    fi
}

# Color code temperature
color_temp() {
    local temp=$1
    if [[ -z "$temp" || "$temp" == "N/A" ]]; then
        echo -e "${GRAY}N/A${RESET}"
        return
    fi
    if ((temp >= 60)); then
        echo -e "${RED}${temp}°C${RESET}"
    elif ((temp >= 45)); then
        echo -e "${YELLOW}${temp}°C${RESET}"
    else
        echo -e "${GREEN}${temp}°C${RESET}"
    fi
}

# Color code SMART status
color_smart_status() {
    local status=$1
    case "$status" in
        PASSED|OK|GOOD)
            echo -e "${OK} ${GREEN}PASSED${RESET}"
            ;;
        FAILED|FAILING)
            echo -e "${CRIT} ${RED}FAILED${RESET}"
            ;;
        UNKNOWN|N/A)
            echo -e "${UNKNOWN} ${GRAY}N/A${RESET}"
            ;;
        *)
            echo -e "${WARN} ${YELLOW}${status}${RESET}"
            ;;
    esac
}

# Color code error counts
color_errors() {
    local count=$1
    if [[ -z "$count" || "$count" == "N/A" ]]; then
        echo -e "${GRAY}N/A${RESET}"
        return
    fi
    if ((count == 0)); then
        echo -e "${GREEN}0${RESET}"
    elif ((count < 10)); then
        echo -e "${YELLOW}${count}${RESET}"
    else
        echo -e "${RED}${count}${RESET}"
    fi
}

# Determine drive type
get_drive_type() {
    local device=$1
    local name=$(basename "$device")
    
    # Check if NVMe
    if [[ "$name" == nvme* ]]; then
        echo "NVMe"
        return
    fi
    
    # Check rotation rate from smartctl
    local rotation=$(smartctl -i "$device" 2>/dev/null | grep -i "Rotation Rate" | awk -F: '{print $2}' | xargs)
    
    if [[ "$rotation" == *"Solid State"* ]]; then
        echo "SSD"
    elif [[ "$rotation" =~ ^[0-9]+[[:space:]]*rpm$ ]]; then
        echo "HDD"
    else
        # Fallback: check if it's on a rotational device
        local rotational=$(cat "/sys/block/${name}/queue/rotational" 2>/dev/null)
        if [[ "$rotational" == "0" ]]; then
            echo "SSD"
        elif [[ "$rotational" == "1" ]]; then
            echo "HDD"
        else
            echo "???"
        fi
    fi
}

# Get drive icon based on type
get_drive_icon() {
    local type=$1
    case "$type" in
        NVMe) echo "⚡" ;;
        SSD)  echo "◆" ;;
        HDD)  echo "◎" ;;
        *)    echo "○" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# SMART Data Collection
# ─────────────────────────────────────────────────────────────────────────────

get_smart_data() {
    local device=$1
    local smart_output
    local smart_health
    
    # Get SMART data
    smart_output=$(smartctl -a "$device" 2>/dev/null)
    
    # Check if SMART is supported
    if [[ -z "$smart_output" ]] || echo "$smart_output" | grep -q "Unable to detect device type"; then
        echo "N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A"
        return
    fi
    
    # Overall health
    smart_health=$(echo "$smart_output" | grep -E "SMART overall-health|SMART Health Status" | head -1 | awk -F: '{print $2}' | xargs)
    [[ -z "$smart_health" ]] && smart_health="UNKNOWN"
    [[ "$smart_health" == *"PASSED"* ]] && smart_health="PASSED"
    [[ "$smart_health" == *"OK"* ]] && smart_health="PASSED"
    
    # Power on hours - try multiple attributes
    local power_hours=$(echo "$smart_output" | grep -E "Power_On_Hours|Power On Hours" | head -1 | awk '{print $NF}')
    [[ -z "$power_hours" ]] && power_hours=$(echo "$smart_output" | grep -E "9 Power_On_Hours" | awk '{print $10}')
    [[ -z "$power_hours" || ! "$power_hours" =~ ^[0-9]+$ ]] && power_hours="N/A"
    
    # Temperature
    local temp=$(echo "$smart_output" | grep -E "Temperature_Celsius|Airflow_Temperature|Current Drive Temperature" | head -1 | awk '{print $10}')
    [[ -z "$temp" ]] && temp=$(echo "$smart_output" | grep -E "Temperature:" | head -1 | awk '{print $2}')
    [[ -z "$temp" || ! "$temp" =~ ^[0-9]+$ ]] && temp="N/A"
    
    # Reallocated sectors
    local reallocated=$(echo "$smart_output" | grep -E "Reallocated_Sector_Ct|Reallocated_Event_Count" | head -1 | awk '{print $10}')
    [[ -z "$reallocated" || ! "$reallocated" =~ ^[0-9]+$ ]] && reallocated="0"
    
    # Pending sectors
    local pending=$(echo "$smart_output" | grep "Current_Pending_Sector" | awk '{print $10}')
    [[ -z "$pending" || ! "$pending" =~ ^[0-9]+$ ]] && pending="0"
    
    # Uncorrectable errors
    local uncorrectable=$(echo "$smart_output" | grep "Offline_Uncorrectable" | awk '{print $10}')
    [[ -z "$uncorrectable" || ! "$uncorrectable" =~ ^[0-9]+$ ]] && uncorrectable="0"
    
    # Power cycles
    local power_cycles=$(echo "$smart_output" | grep -E "Power_Cycle_Count" | awk '{print $10}')
    [[ -z "$power_cycles" || ! "$power_cycles" =~ ^[0-9]+$ ]] && power_cycles="N/A"
    
    # Wear leveling / percentage used (for SSDs)
    local wear=$(echo "$smart_output" | grep -E "Wear_Leveling_Count|Percent_Lifetime_Remain|Media_Wearout_Indicator|SSD_Life_Left" | head -1 | awk '{print $4}')
    [[ -z "$wear" || ! "$wear" =~ ^[0-9]+$ ]] && wear="N/A"
    
    echo "${smart_health}|${power_hours}|${temp}|${reallocated}|${pending}|${uncorrectable}|${power_cycles}|${wear}"
}

get_nvme_smart_data() {
    local device=$1
    local smart_output
    
    smart_output=$(smartctl -a "$device" 2>/dev/null)
    
    if [[ -z "$smart_output" ]]; then
        echo "N/A|N/A|N/A|N/A|N/A|N/A|N/A|N/A"
        return
    fi
    
    # NVMe health status
    local health=$(echo "$smart_output" | grep "SMART overall-health" | awk -F: '{print $2}' | xargs)
    [[ -z "$health" ]] && health="UNKNOWN"
    [[ "$health" == *"PASSED"* ]] && health="PASSED"
    
    # Power on hours
    local power_hours=$(echo "$smart_output" | grep "Power On Hours" | awk '{print $4}' | tr -d ',')
    [[ -z "$power_hours" || ! "$power_hours" =~ ^[0-9]+$ ]] && power_hours="N/A"
    
    # Temperature
    local temp=$(echo "$smart_output" | grep "Temperature:" | head -1 | awk '{print $2}')
    [[ -z "$temp" || ! "$temp" =~ ^[0-9]+$ ]] && temp="N/A"
    
    # Media errors
    local media_errors=$(echo "$smart_output" | grep "Media and Data Integrity Errors" | awk '{print $NF}')
    [[ -z "$media_errors" || ! "$media_errors" =~ ^[0-9]+$ ]] && media_errors="0"
    
    # Error log entries
    local error_log=$(echo "$smart_output" | grep "Error Information Log Entries" | awk '{print $NF}')
    [[ -z "$error_log" || ! "$error_log" =~ ^[0-9]+$ ]] && error_log="0"
    
    # Power cycles
    local power_cycles=$(echo "$smart_output" | grep "Power Cycles" | awk '{print $3}' | tr -d ',')
    [[ -z "$power_cycles" || ! "$power_cycles" =~ ^[0-9]+$ ]] && power_cycles="N/A"
    
    # Percentage used
    local percent_used=$(echo "$smart_output" | grep "Percentage Used" | awk '{print $3}' | tr -d '%')
    [[ -z "$percent_used" || ! "$percent_used" =~ ^[0-9]+$ ]] && percent_used="N/A"
    
    # Available spare
    local spare=$(echo "$smart_output" | grep "Available Spare:" | awk '{print $3}' | tr -d '%')
    [[ -z "$spare" || ! "$spare" =~ ^[0-9]+$ ]] && spare="N/A"
    
    echo "${health}|${power_hours}|${temp}|${media_errors}|${error_log}|0|${power_cycles}|${percent_used}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Drive Discovery and Display
# ─────────────────────────────────────────────────────────────────────────────

print_drive_table() {
    print_header "💾 Physical Drive Health"
    
    # Check for smartctl
    if ! command -v smartctl &>/dev/null; then
        echo -e "${YELLOW}⚠ smartctl not found. Install smartmontools for SMART data.${RESET}"
        echo -e "${DIM}  Ubuntu/Debian: sudo apt install smartmontools${RESET}"
        echo -e "${DIM}  RHEL/CentOS:   sudo yum install smartmontools${RESET}"
        return 1
    fi
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}⚠ Not running as root. Some SMART data may be unavailable.${RESET}"
        echo -e "${DIM}  Run with: sudo $0${RESET}\n"
    fi
    
    # Table header
    printf "\n${BOLD}${WHITE}"
    printf "%-6s %-10s %-6s %-12s %-10s %-8s %-8s %-10s %-8s %-6s${RESET}\n" \
        "TYPE" "DEVICE" "SIZE" "MODEL" "SMART" "HOURS" "TEMP" "ERRORS" "CYCLES" "WEAR"
    printf "${GRAY}%s${RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────────────"
    
    # Find all block devices (exclude loop, ram, rom)
    local devices=()
    
    # Standard block devices
    for dev in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme[0-9]n[0-9] /dev/hd[a-z]; do
        [[ -b "$dev" ]] && devices+=("$dev")
    done
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo -e "${GRAY}No physical drives detected${RESET}"
        return
    fi
    
    for device in "${devices[@]}"; do
        local name=$(basename "$device")
        local type=$(get_drive_type "$device")
        local icon=$(get_drive_icon "$type")
        
        # Get size
        local size_bytes=$(blockdev --getsize64 "$device" 2>/dev/null)
        local size=$(human_size "$size_bytes")
        
        # Get model
        local model=$(smartctl -i "$device" 2>/dev/null | grep -E "Device Model|Model Number|Product:" | head -1 | awk -F: '{print $2}' | xargs | cut -c1-12)
        [[ -z "$model" ]] && model=$(cat "/sys/block/${name}/device/model" 2>/dev/null | xargs | cut -c1-12)
        [[ -z "$model" ]] && model="Unknown"
        
        # Get SMART data based on type
        local smart_data
        if [[ "$type" == "NVMe" ]]; then
            smart_data=$(get_nvme_smart_data "$device")
        else
            smart_data=$(get_smart_data "$device")
        fi
        
        IFS='|' read -r health hours temp realloc pending uncorrect cycles wear <<< "$smart_data"
        
        # Calculate total errors
        local total_errors=0
        [[ "$realloc" =~ ^[0-9]+$ ]] && total_errors=$((total_errors + realloc))
        [[ "$pending" =~ ^[0-9]+$ ]] && total_errors=$((total_errors + pending))
        [[ "$uncorrect" =~ ^[0-9]+$ ]] && total_errors=$((total_errors + uncorrect))
        
        # Format wear display
        local wear_display
        if [[ "$wear" != "N/A" && "$type" == "NVMe" ]]; then
            # NVMe reports percentage used
            if ((wear <= 10)); then
                wear_display="${GREEN}${wear}%${RESET}"
            elif ((wear <= 50)); then
                wear_display="${YELLOW}${wear}%${RESET}"
            else
                wear_display="${RED}${wear}%${RESET}"
            fi
        elif [[ "$wear" != "N/A" ]]; then
            # SATA SSDs often report remaining life
            if ((wear >= 90)); then
                wear_display="${GREEN}${wear}%${RESET}"
            elif ((wear >= 50)); then
                wear_display="${YELLOW}${wear}%${RESET}"
            else
                wear_display="${RED}${wear}%${RESET}"
            fi
        else
            wear_display="${GRAY}N/A${RESET}"
        fi
        
        # Format hours
        local hours_display
        if [[ "$hours" != "N/A" ]]; then
            hours_display=$(format_hours "$hours")
        else
            hours_display="N/A"
        fi
        
        # Format cycles
        local cycles_display
        if [[ "$cycles" != "N/A" ]]; then
            cycles_display="$cycles"
        else
            cycles_display="${GRAY}N/A${RESET}"
        fi
        
        # Print row
        printf "${CYAN}${icon}${RESET} %-4s " "$type"
        printf "%-10s " "$name"
        printf "%-6s " "$size"
        printf "%-12s " "$model"
        printf "%-18b " "$(color_smart_status "$health")"
        printf "%-8s " "$hours_display"
        printf "%-16b " "$(color_temp "$temp")"
        printf "%-16b " "$(color_errors "$total_errors")"
        printf "%-8s " "$cycles_display"
        printf "%-14b\n" "$wear_display"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# ZFS Pool Assessment
# ─────────────────────────────────────────────────────────────────────────────

print_zfs_status() {
    print_header "🗄️  ZFS Pool Health"
    
    # Check for ZFS
    if ! command -v zpool &>/dev/null; then
        echo -e "${GRAY}ZFS not installed or not in PATH${RESET}"
        return
    fi
    
    # Get list of pools
    local pools=$(zpool list -H -o name 2>/dev/null)
    
    if [[ -z "$pools" ]]; then
        echo -e "${GRAY}No ZFS pools found${RESET}"
        return
    fi
    
    # Pool summary header
    printf "\n${BOLD}${WHITE}"
    printf "%-15s %-10s %-10s %-10s %-8s %-10s %-12s %-10s${RESET}\n" \
        "POOL" "SIZE" "USED" "FREE" "CAP" "HEALTH" "FRAGMENTATION" "ERRORS"
    printf "${GRAY}%s${RESET}\n" "────────────────────────────────────────────────────────────────────────────────────────"
    
    while read -r pool; do
        [[ -z "$pool" ]] && continue
        
        # Get pool properties
        local pool_info=$(zpool list -H -o name,size,alloc,free,cap,health,frag "$pool" 2>/dev/null)
        IFS=$'\t' read -r name size alloc free cap health frag <<< "$pool_info"
        
        # Get error counts
        local status=$(zpool status "$pool" 2>/dev/null)
        local read_errors=$(echo "$status" | grep -E "^\s+${pool}" | awk '{print $3}' | head -1)
        local write_errors=$(echo "$status" | grep -E "^\s+${pool}" | awk '{print $4}' | head -1)
        local cksum_errors=$(echo "$status" | grep -E "^\s+${pool}" | awk '{print $5}' | head -1)
        
        # Calculate total errors
        local total_errors=0
        [[ "$read_errors" =~ ^[0-9]+$ ]] && total_errors=$((total_errors + read_errors))
        [[ "$write_errors" =~ ^[0-9]+$ ]] && total_errors=$((total_errors + write_errors))
        [[ "$cksum_errors" =~ ^[0-9]+$ ]] && total_errors=$((total_errors + cksum_errors))
        
        # Color code health
        local health_color
        case "$health" in
            ONLINE)   health_color="${OK} ${GREEN}${health}${RESET}" ;;
            DEGRADED) health_color="${WARN} ${YELLOW}${health}${RESET}" ;;
            FAULTED)  health_color="${CRIT} ${RED}${health}${RESET}" ;;
            OFFLINE)  health_color="${CRIT} ${RED}${health}${RESET}" ;;
            *)        health_color="${UNKNOWN} ${GRAY}${health}${RESET}" ;;
        esac
        
        # Color code capacity
        local cap_num=${cap%\%}
        local cap_color
        if ((cap_num >= 90)); then
            cap_color="${RED}${cap}${RESET}"
        elif ((cap_num >= 80)); then
            cap_color="${YELLOW}${cap}${RESET}"
        else
            cap_color="${GREEN}${cap}${RESET}"
        fi
        
        # Color code fragmentation
        local frag_num=${frag%\%}
        local frag_color
        if [[ "$frag" == "-" ]]; then
            frag_color="${GRAY}N/A${RESET}"
        elif ((frag_num >= 50)); then
            frag_color="${RED}${frag}${RESET}"
        elif ((frag_num >= 30)); then
            frag_color="${YELLOW}${frag}${RESET}"
        else
            frag_color="${GREEN}${frag}${RESET}"
        fi
        
        printf "%-15s %-10s %-10s %-10s %-16b %-18b %-20b %-10b\n" \
            "$name" "$size" "$alloc" "$free" "$cap_color" "$health_color" "$frag_color" "$(color_errors "$total_errors")"
            
    done <<< "$pools"
    
    # Detailed pool status
    print_subheader "Pool Device Status"
    
    while read -r pool; do
        [[ -z "$pool" ]] && continue
        
        echo -e "\n${BOLD}${MAGENTA}$pool${RESET}"
        
        # Get detailed status with vdev structure
        local status=$(zpool status "$pool" 2>/dev/null)
        
        # Parse and display device tree
        echo "$status" | awk '
            /config:/{found=1; next}
            /errors:/{found=0}
            found && /NAME/{
                printf "  '"${GRAY}"'%-20s %-10s %-8s %-8s %-8s'"${RESET}"'\n", "DEVICE", "STATE", "READ", "WRITE", "CKSUM"
                printf "  '"${GRAY}"'%s'"${RESET}"'\n", "────────────────────────────────────────────────────────"
                next
            }
            found && NF>=5 && !/^$/{
                name=$1; state=$2; read=$3; write=$4; cksum=$5
                # Indent based on hierarchy
                indent=""
                if (name ~ /^(mirror|raidz|spare|log|cache|special)/) indent="  "
                else if (name !~ /^[a-zA-Z]/) indent="    "
                
                # Color state
                if (state == "ONLINE") state_color="'"${GREEN}"'" state "'"${RESET}"'"
                else if (state == "DEGRADED") state_color="'"${YELLOW}"'" state "'"${RESET}"'"
                else if (state == "FAULTED" || state == "OFFLINE" || state == "UNAVAIL") state_color="'"${RED}"'" state "'"${RESET}"'"
                else state_color=state
                
                # Color errors
                if (read+0 > 0) read="'"${RED}"'" read "'"${RESET}"'"
                if (write+0 > 0) write="'"${RED}"'" write "'"${RESET}"'"
                if (cksum+0 > 0) cksum="'"${RED}"'" cksum "'"${RESET}"'"
                
                printf "  %s%-16s %-18s %-16s %-16s %-8s\n", indent, name, state_color, read, write, cksum
            }
        '
        
        # Show any error messages
        local errors=$(echo "$status" | grep -A1 "errors:" | tail -1)
        if [[ "$errors" != *"No known data errors"* && -n "$errors" ]]; then
            echo -e "\n  ${RED}⚠ ${errors}${RESET}"
        fi
        
        # Show scrub status
        local scrub=$(echo "$status" | grep "scan:" | head -1)
        if [[ -n "$scrub" ]]; then
            if [[ "$scrub" == *"in progress"* ]]; then
                echo -e "  ${CYAN}🔄 Scrub in progress${RESET}"
                echo "$status" | grep -E "done|to go" | head -1 | sed 's/^/  /'
            elif [[ "$scrub" == *"scrub repaired"* ]]; then
                local scrub_date=$(echo "$scrub" | grep -oE "[A-Z][a-z]{2} [A-Z][a-z]{2} +[0-9]+ [0-9:]+")
                echo -e "  ${DIM}Last scrub: ${scrub_date}${RESET}"
            fi
        fi
        
    done <<< "$pools"
}

# ─────────────────────────────────────────────────────────────────────────────
# ZFS Dataset Information
# ─────────────────────────────────────────────────────────────────────────────

print_zfs_datasets() {
    if ! command -v zfs &>/dev/null; then
        return
    fi
    
    local datasets=$(zfs list -H -o name 2>/dev/null | head -20)
    [[ -z "$datasets" ]] && return
    
    print_subheader "ZFS Datasets (Top 20)"
    
    printf "\n${BOLD}${WHITE}"
    printf "%-30s %-10s %-10s %-10s %-8s %-12s${RESET}\n" \
        "DATASET" "USED" "AVAIL" "REFER" "RATIO" "MOUNTPOINT"
    printf "${GRAY}%s${RESET}\n" "──────────────────────────────────────────────────────────────────────────────────────"
    
    while read -r dataset; do
        [[ -z "$dataset" ]] && continue
        
        local info=$(zfs list -H -o name,used,avail,refer,compressratio,mountpoint "$dataset" 2>/dev/null)
        IFS=$'\t' read -r name used avail refer ratio mount <<< "$info"
        
        # Truncate long names
        local short_name="${name:0:30}"
        [[ ${#name} -gt 30 ]] && short_name="${short_name:0:27}..."
        
        # Truncate long mountpoints
        local short_mount="${mount:0:12}"
        [[ ${#mount} -gt 12 ]] && short_mount="${short_mount:0:9}..."
        
        printf "%-30s %-10s %-10s %-10s %-8s %-12s\n" \
            "$short_name" "$used" "$avail" "$refer" "$ratio" "$short_mount"
            
    done <<< "$datasets"
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary Stats
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    print_header "📊 Summary"
    
    local total_drives=0
    local healthy_drives=0
    local warning_drives=0
    local failed_drives=0
    
    # Count drives
    for dev in /dev/sd[a-z] /dev/sd[a-z][a-z] /dev/nvme[0-9]n[0-9]; do
        [[ -b "$dev" ]] || continue
        ((total_drives++))
        
        local health=$(smartctl -H "$dev" 2>/dev/null | grep -E "SMART overall-health|SMART Health Status" | grep -oE "PASSED|OK|FAILED")
        case "$health" in
            PASSED|OK) ((healthy_drives++)) ;;
            FAILED)    ((failed_drives++)) ;;
            *)         ((warning_drives++)) ;;
        esac
    done
    
    # ZFS pool counts
    local total_pools=0
    local healthy_pools=0
    local degraded_pools=0
    local faulted_pools=0
    
    if command -v zpool &>/dev/null; then
        while read -r pool; do
            [[ -z "$pool" ]] && continue
            ((total_pools++))
            
            local health=$(zpool list -H -o health "$pool" 2>/dev/null)
            case "$health" in
                ONLINE)   ((healthy_pools++)) ;;
                DEGRADED) ((degraded_pools++)) ;;
                *)        ((faulted_pools++)) ;;
            esac
        done <<< "$(zpool list -H -o name 2>/dev/null)"
    fi
    
    echo ""
    printf "  ${BOLD}Physical Drives:${RESET} "
    printf "${GREEN}%d healthy${RESET}" "$healthy_drives"
    ((warning_drives > 0)) && printf ", ${YELLOW}%d unknown${RESET}" "$warning_drives"
    ((failed_drives > 0)) && printf ", ${RED}%d failed${RESET}" "$failed_drives"
    printf " (of %d total)\n" "$total_drives"
    
    if ((total_pools > 0)); then
        printf "  ${BOLD}ZFS Pools:${RESET}        "
        printf "${GREEN}%d healthy${RESET}" "$healthy_pools"
        ((degraded_pools > 0)) && printf ", ${YELLOW}%d degraded${RESET}" "$degraded_pools"
        ((faulted_pools > 0)) && printf ", ${RED}%d faulted${RESET}" "$faulted_pools"
        printf " (of %d total)\n" "$total_pools"
    fi
    
    echo -e "\n  ${DIM}Report generated: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
    echo -e "  ${DIM}Run with sudo for complete SMART data${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo -e "${BOLD}${WHITE}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║           🔍 Drive & ZFS Health Assessment Tool 🔍            ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
    
    print_drive_table
    print_zfs_status
    print_zfs_datasets
    print_summary
    
    echo ""
}

main "$@"

