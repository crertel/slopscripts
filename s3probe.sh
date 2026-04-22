#!/usr/bin/env bash
#
# s3probe.sh - Unauthenticated S3 bucket exposure probe
# Tests what the outside world can see without any AWS credentials
#
# Usage: s3probe.sh s3://my-bucket
#        s3probe.sh my-bucket
#        s3probe.sh my-bucket us-west-2
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
readonly EXPOSED="${RED}●${RESET}"
readonly BLOCKED="${GREEN}●${RESET}"
readonly PARTIAL="${YELLOW}●${RESET}"
readonly INFO="${BLUE}●${RESET}"
readonly SKIP="${GRAY}○${RESET}"

# Counters
TOTAL_PROBES=0
EXPOSED_COUNT=0
BLOCKED_COUNT=0
PARTIAL_COUNT=0

# Request timeout (seconds)
readonly TIMEOUT=10

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

exposed() {
    ((TOTAL_PROBES++))
    ((EXPOSED_COUNT++))
    printf "  ${EXPOSED} ${RED}EXPOSED${RESET}   %s\n" "$1"
}

blocked() {
    ((TOTAL_PROBES++))
    ((BLOCKED_COUNT++))
    printf "  ${BLOCKED} ${GREEN}BLOCKED${RESET}   %s\n" "$1"
}

partial() {
    ((TOTAL_PROBES++))
    ((PARTIAL_COUNT++))
    printf "  ${PARTIAL} ${YELLOW}PARTIAL${RESET}   %s\n" "$1"
}

info() {
    printf "  ${INFO} ${BLUE}INFO${RESET}      %s\n" "$1"
}

detail() {
    printf "  ${GRAY}            ↳ %s${RESET}\n" "$1"
}

parse_bucket() {
    local input="$1"
    input="${input#s3://}"
    input="${input%/}"
    echo "${input%%/*}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Region Discovery
# ─────────────────────────────────────────────────────────────────────────────

discover_region() {
    local bucket="$1"
    local hint="$2"

    # If user provided a region hint, try that first
    if [[ -n "$hint" ]]; then
        echo "$hint"
        return
    fi

    # HEAD the global endpoint — S3 returns x-amz-bucket-region header
    local headers
    headers=$(curl -sI --max-time "$TIMEOUT" "https://${bucket}.s3.amazonaws.com/" 2>/dev/null)

    local region
    region=$(echo "$headers" | grep -i "x-amz-bucket-region" | tr -d '\r' | awk '{print $2}')

    if [[ -n "$region" ]]; then
        echo "$region"
    else
        echo "us-east-1"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Bucket Existence
# ─────────────────────────────────────────────────────────────────────────────

probe_existence() {
    local bucket="$1"
    local region="$2"

    print_subheader "Bucket Existence"

    # Try DNS resolution first
    if host "${bucket}.s3.amazonaws.com" &>/dev/null; then
        info "DNS resolves: ${bucket}.s3.amazonaws.com"
    else
        info "DNS does not resolve (bucket may not exist)"
        return 1
    fi

    # HEAD request to check existence vs access
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
        "https://${bucket}.s3.${region}.amazonaws.com/" 2>/dev/null)

    case "$http_code" in
        200)
            exposed "Bucket exists and is publicly accessible (HTTP 200)"
            ;;
        301)
            info "Bucket exists (HTTP 301 — redirect, possibly wrong region)"
            ;;
        307)
            info "Bucket exists (HTTP 307 — temporary redirect to correct region)"
            ;;
        403)
            blocked "Bucket exists but denies anonymous access (HTTP 403)"
            ;;
        404)
            info "Bucket does not exist (HTTP 404)"
            return 1
            ;;
        *)
            info "Bucket response: HTTP ${http_code}"
            ;;
    esac

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Public Listing
# ─────────────────────────────────────────────────────────────────────────────

probe_listing() {
    local bucket="$1"
    local region="$2"

    print_subheader "Public Bucket Listing"

    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        "https://${bucket}.s3.${region}.amazonaws.com/?list-type=2&max-keys=5" 2>/dev/null)

    if echo "$response" | grep -q "<ListBucketResult"; then
        exposed "Bucket contents are publicly listable"

        # Count how many keys returned
        local key_count
        key_count=$(echo "$response" | grep -c "<Key>")
        detail "${key_count} object(s) visible in sample (max-keys=5)"

        # Show first few keys
        echo "$response" | grep -oP '<Key>\K[^<]+' | head -5 | while IFS= read -r key; do
            detail "  ${key}"
        done

        # Check if truncated
        if echo "$response" | grep -q "<IsTruncated>true"; then
            detail "...and more (listing was truncated)"
        fi
    elif echo "$response" | grep -q "AccessDenied"; then
        blocked "Bucket listing denied (AccessDenied)"
    elif echo "$response" | grep -q "AllAccessDisabled"; then
        blocked "All public access disabled"
    else
        blocked "Bucket listing not accessible"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Public Object Read (common paths)
# ─────────────────────────────────────────────────────────────────────────────

probe_common_objects() {
    local bucket="$1"
    local region="$2"

    print_subheader "Common Sensitive Paths"

    local paths=(
        "index.html"
        "robots.txt"
        ".env"
        ".git/config"
        ".git/HEAD"
        "config.json"
        "config.yml"
        "config.yaml"
        "credentials"
        "credentials.json"
        "secrets.json"
        "backup.sql"
        "dump.sql"
        "database.sql"
        ".htpasswd"
        ".htaccess"
        "id_rsa"
        "wp-config.php"
        "crossdomain.xml"
    )

    local found_any=false

    for path in "${paths[@]}"; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
            "https://${bucket}.s3.${region}.amazonaws.com/${path}" 2>/dev/null)

        case "$http_code" in
            200)
                exposed "Publicly readable: /${path}"
                found_any=true
                ;;
            403)
                # Access denied is expected and good — don't clutter output
                ;;
            404)
                # Not found — also fine, skip
                ;;
        esac
    done

    if [[ "$found_any" == "false" ]]; then
        blocked "No common sensitive paths publicly readable"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Website Endpoint
# ─────────────────────────────────────────────────────────────────────────────

probe_website() {
    local bucket="$1"
    local region="$2"

    print_subheader "Static Website Endpoint"

    # S3 website endpoints use a different hostname pattern
    local website_url="http://${bucket}.s3-website-${region}.amazonaws.com/"
    # Newer format
    local website_url_v2="http://${bucket}.s3-website.${region}.amazonaws.com/"

    local found_website=false

    for url in "$website_url" "$website_url_v2"; do
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$url" 2>/dev/null)

        case "$http_code" in
            200|301|302)
                exposed "Website endpoint active: ${url} (HTTP ${http_code})"
                found_website=true

                # Grab the title if 200
                if [[ "$http_code" == "200" ]]; then
                    local title
                    title=$(curl -s --max-time "$TIMEOUT" "$url" 2>/dev/null | grep -oP '<title>\K[^<]+' | head -1)
                    [[ -n "$title" ]] && detail "Page title: ${title}"
                fi
                break
                ;;
            403)
                # Website hosting is enabled but access is denied
                partial "Website endpoint exists but returns 403: ${url}"
                detail "Hosting is enabled — content may be gated by policy"
                found_website=true
                break
                ;;
            404)
                # 404 from the website endpoint means hosting IS enabled but no index
                # (vs. a connection failure which means hosting is off)
                partial "Website endpoint returns 404 (hosting enabled, no index document)"
                found_website=true
                break
                ;;
            000)
                # Connection failed — hosting not enabled on this endpoint form
                ;;
        esac
    done

    if [[ "$found_website" == "false" ]]; then
        blocked "No website endpoint detected"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Public ACL
# ─────────────────────────────────────────────────────────────────────────────

probe_acl() {
    local bucket="$1"
    local region="$2"

    print_subheader "ACL Exposure"

    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        "https://${bucket}.s3.${region}.amazonaws.com/?acl" 2>/dev/null)

    if echo "$response" | grep -q "<AccessControlPolicy"; then
        exposed "Bucket ACL is publicly readable"

        # Check for public grants in the ACL
        if echo "$response" | grep -q "AllUsers"; then
            exposed "ACL grants access to AllUsers (everyone)"
        fi
        if echo "$response" | grep -q "AuthenticatedUsers"; then
            exposed "ACL grants access to AuthenticatedUsers (any AWS account)"
        fi

        # Show owner
        local owner
        owner=$(echo "$response" | grep -oP '<DisplayName>\K[^<]+' | head -1)
        [[ -n "$owner" ]] && detail "Bucket owner: ${owner}"
    elif echo "$response" | grep -q "AccessDenied"; then
        blocked "ACL not publicly readable"
    else
        blocked "ACL not accessible"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CORS Headers
# ─────────────────────────────────────────────────────────────────────────────

probe_cors() {
    local bucket="$1"
    local region="$2"

    print_subheader "CORS Configuration"

    # Send an OPTIONS preflight with a wildcard origin
    local response_headers
    response_headers=$(curl -sI --max-time "$TIMEOUT" \
        -X OPTIONS \
        -H "Origin: https://evil-example.com" \
        -H "Access-Control-Request-Method: GET" \
        "https://${bucket}.s3.${region}.amazonaws.com/" 2>/dev/null)

    local acao
    acao=$(echo "$response_headers" | grep -i "access-control-allow-origin" | tr -d '\r' | awk '{print $2}')

    if [[ -n "$acao" ]]; then
        if [[ "$acao" == "*" ]]; then
            partial "CORS allows any origin (Access-Control-Allow-Origin: *)"
            detail "Any website can make cross-origin requests to this bucket"
        elif [[ "$acao" == "https://evil-example.com" ]]; then
            exposed "CORS reflects arbitrary origins (responded with our test origin)"
            detail "Origin reflection without validation — effectively open to all"
        else
            info "CORS allows specific origin: ${acao}"
        fi

        # Check allowed methods
        local methods
        methods=$(echo "$response_headers" | grep -i "access-control-allow-methods" | tr -d '\r' | sed 's/^[^:]*: //')
        [[ -n "$methods" ]] && detail "Allowed methods: ${methods}"

        # Check exposed headers
        local exposed_headers
        exposed_headers=$(echo "$response_headers" | grep -i "access-control-expose-headers" | tr -d '\r' | sed 's/^[^:]*: //')
        [[ -n "$exposed_headers" ]] && detail "Exposed headers: ${exposed_headers}"
    else
        blocked "No CORS headers returned for arbitrary origin"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Public Upload Test (PUT)
# ─────────────────────────────────────────────────────────────────────────────

probe_upload() {
    local bucket="$1"
    local region="$2"

    print_subheader "Public Write Access"

    # We do NOT actually write anything — just send a PUT and check the response code
    # Using a content-length 0 to a canary path
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" \
        -X PUT \
        -H "Content-Length: 0" \
        "https://${bucket}.s3.${region}.amazonaws.com/.s3audit-probe-DELETE-ME" 2>/dev/null)

    case "$http_code" in
        200)
            exposed "PUBLIC WRITE! Anonymous PUT returned HTTP 200"
            detail "CRITICAL: Anyone can upload objects to this bucket"
            detail "A zero-byte test object may have been created at /.s3audit-probe-DELETE-ME"
            ;;
        403)
            blocked "Anonymous PUT denied (HTTP 403)"
            ;;
        405)
            blocked "PUT method not allowed (HTTP 405)"
            ;;
        *)
            info "Anonymous PUT returned HTTP ${http_code}"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Server Headers Leak
# ─────────────────────────────────────────────────────────────────────────────

probe_headers() {
    local bucket="$1"
    local region="$2"

    print_subheader "Response Header Analysis"

    local headers
    headers=$(curl -sI --max-time "$TIMEOUT" \
        "https://${bucket}.s3.${region}.amazonaws.com/" 2>/dev/null)

    # Check server header
    local server
    server=$(echo "$headers" | grep -i "^server:" | tr -d '\r' | sed 's/^[^:]*: //')
    [[ -n "$server" ]] && info "Server: ${server}"

    # Check for x-amz-request-id (confirms it's S3)
    if echo "$headers" | grep -qi "x-amz-request-id"; then
        info "Confirmed AWS S3 (x-amz-request-id present)"
    fi

    # Check for x-amz-bucket-region
    local hdr_region
    hdr_region=$(echo "$headers" | grep -i "x-amz-bucket-region" | tr -d '\r' | awk '{print $2}')
    [[ -n "$hdr_region" ]] && info "Region disclosed: ${hdr_region}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    local bucket="$1"

    print_header "Probe Summary"

    echo ""
    printf "  ${BOLD}Bucket:${RESET}  %s\n" "$bucket"
    echo ""

    printf "  ${RED}%-4d exposed${RESET}" "$EXPOSED_COUNT"
    printf "  ${YELLOW}%-4d partial${RESET}" "$PARTIAL_COUNT"
    printf "  ${GREEN}%-4d blocked${RESET}\n" "$BLOCKED_COUNT"
    printf "  ${BOLD}%-4d total probes${RESET}\n" "$TOTAL_PROBES"
    echo ""

    if ((EXPOSED_COUNT == 0 && PARTIAL_COUNT == 0)); then
        echo -e "  ${GREEN}● Overall: LOCKED DOWN — No public exposure detected${RESET}"
    elif ((EXPOSED_COUNT == 0)); then
        echo -e "  ${YELLOW}● Overall: MOSTLY CLOSED — ${PARTIAL_COUNT} item(s) partially exposed${RESET}"
    elif ((EXPOSED_COUNT <= 2)); then
        echo -e "  ${YELLOW}● Overall: LEAKING — ${EXPOSED_COUNT} item(s) publicly exposed${RESET}"
    else
        echo -e "  ${RED}● Overall: WIDE OPEN — ${EXPOSED_COUNT} item(s) publicly exposed${RESET}"
    fi

    echo ""
    echo -e "  ${DIM}This is an external probe only. For full configuration audit,${RESET}"
    echo -e "  ${DIM}use s3audit.sh with AWS credentials.${RESET}"
    echo -e "\n  ${DIM}Probe completed: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 <s3-uri-or-bucket-name> [region]"
    echo ""
    echo "Examples:"
    echo "  $0 s3://my-bucket"
    echo "  $0 my-bucket"
    echo "  $0 my-bucket us-west-2"
    echo ""
    echo "No AWS credentials required — probes only what's publicly visible."
    exit 1
}

main() {
    if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    local bucket
    bucket=$(parse_bucket "$1")
    local region_hint="${2:-}"

    if [[ -z "$bucket" ]]; then
        echo -e "${RED}Error: Could not parse bucket name from '${1}'${RESET}" >&2
        usage
    fi

    # Check for curl
    if ! command -v curl &>/dev/null; then
        echo -e "${RED}Error: curl is required but not found${RESET}" >&2
        exit 1
    fi

    echo -e "${BOLD}${WHITE}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║          S3 Bucket Exposure Probe (No Creds)                ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    echo -e "  ${DIM}Discovering region...${RESET}"
    local region
    region=$(discover_region "$bucket" "$region_hint")
    echo -e "  ${DIM}Using region: ${region}${RESET}"

    probe_existence "$bucket" "$region" || {
        echo -e "\n  ${GRAY}Bucket does not appear to exist. Nothing to probe.${RESET}\n"
        exit 0
    }

    probe_listing "$bucket" "$region"
    probe_common_objects "$bucket" "$region"
    probe_acl "$bucket" "$region"
    probe_website "$bucket" "$region"
    probe_cors "$bucket" "$region"
    probe_upload "$bucket" "$region"
    probe_headers "$bucket" "$region"
    print_summary "$bucket"

    echo ""

    if ((EXPOSED_COUNT > 0)); then
        exit 2
    elif ((PARTIAL_COUNT > 0)); then
        exit 1
    fi
    exit 0
}

main "$@"
