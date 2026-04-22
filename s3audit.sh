#!/usr/bin/env bash
#
# s3audit.sh - S3 bucket security audit
# Point at an S3 URI and get an at-a-glance security assessment
#
# Usage: s3audit.sh s3://my-bucket
#        s3audit.sh s3://my-bucket/some/prefix
#        s3audit.sh my-bucket
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
readonly PASS="${GREEN}●${RESET}"
readonly WARN="${YELLOW}●${RESET}"
readonly FAIL="${RED}●${RESET}"
readonly INFO="${BLUE}●${RESET}"
readonly SKIP="${GRAY}○${RESET}"

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
WARNED_CHECKS=0
FAILED_CHECKS=0
SKIPPED_CHECKS=0

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

result_pass() {
    ((TOTAL_CHECKS++))
    ((PASSED_CHECKS++))
    printf "  ${PASS} ${GREEN}PASS${RESET}  %s\n" "$1"
}

result_fail() {
    ((TOTAL_CHECKS++))
    ((FAILED_CHECKS++))
    printf "  ${FAIL} ${RED}FAIL${RESET}  %s\n" "$1"
}

result_warn() {
    ((TOTAL_CHECKS++))
    ((WARNED_CHECKS++))
    printf "  ${WARN} ${YELLOW}WARN${RESET}  %s\n" "$1"
}

result_info() {
    printf "  ${INFO} ${BLUE}INFO${RESET}  %s\n" "$1"
}

result_skip() {
    ((TOTAL_CHECKS++))
    ((SKIPPED_CHECKS++))
    printf "  ${SKIP} ${GRAY}SKIP${RESET}  %s\n" "$1"
}

detail() {
    printf "  ${GRAY}       ↳ %s${RESET}\n" "$1"
}

# Parse bucket name from various input formats
parse_bucket() {
    local input="$1"
    # Strip s3:// prefix
    input="${input#s3://}"
    # Strip trailing slash
    input="${input%/}"
    # Take just the bucket name (before first /)
    echo "${input%%/*}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisite Checks
# ─────────────────────────────────────────────────────────────────────────────

check_prerequisites() {
    if ! command -v aws &>/dev/null; then
        echo -e "${RED}Error: aws CLI not found. Install it from https://aws.amazon.com/cli/${RESET}" >&2
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo -e "${RED}Error: jq not found. Install it: sudo apt install jq${RESET}" >&2
        exit 1
    fi

    # Verify credentials
    if ! aws sts get-caller-identity &>/dev/null; then
        echo -e "${RED}Error: AWS credentials not configured or expired.${RESET}" >&2
        echo -e "${DIM}  Run: aws configure${RESET}" >&2
        echo -e "${DIM}  Or:  export AWS_PROFILE=your-profile${RESET}" >&2
        exit 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Bucket Info
# ─────────────────────────────────────────────────────────────────────────────

print_bucket_info() {
    local bucket="$1"

    print_header "S3 Bucket: ${bucket}"

    # Verify bucket exists and we have access
    if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
        echo -e "\n  ${RED}Cannot access bucket '${bucket}'. Check that it exists and you have permission.${RESET}"
        exit 1
    fi

    # Get region
    local region
    region=$(aws s3api get-bucket-location --bucket "$bucket" --output text 2>/dev/null)
    [[ "$region" == "None" || -z "$region" ]] && region="us-east-1"

    # Get caller identity
    local identity
    identity=$(aws sts get-caller-identity 2>/dev/null)
    local account_id=$(echo "$identity" | jq -r '.Account // "unknown"')
    local caller_arn=$(echo "$identity" | jq -r '.Arn // "unknown"')

    echo ""
    echo -e "  ${BOLD}Region:${RESET}   ${region}"
    echo -e "  ${BOLD}Account:${RESET}  ${account_id}"
    echo -e "  ${BOLD}Caller:${RESET}   ${DIM}${caller_arn}${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Public Access Block
# ─────────────────────────────────────────────────────────────────────────────

check_public_access_block() {
    local bucket="$1"

    print_subheader "Public Access Block"

    local pab
    pab=$(aws s3api get-public-access-block --bucket "$bucket" 2>/dev/null)

    if [[ -z "$pab" ]]; then
        result_fail "No public access block configured"
        detail "Run: aws s3api put-public-access-block --bucket ${bucket} --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
        return
    fi

    local block_acls=$(echo "$pab" | jq -r '.PublicAccessBlockConfiguration.BlockPublicAcls')
    local ignore_acls=$(echo "$pab" | jq -r '.PublicAccessBlockConfiguration.IgnorePublicAcls')
    local block_policy=$(echo "$pab" | jq -r '.PublicAccessBlockConfiguration.BlockPublicPolicy')
    local restrict=$(echo "$pab" | jq -r '.PublicAccessBlockConfiguration.RestrictPublicBuckets')

    [[ "$block_acls" == "true" ]]   && result_pass "BlockPublicAcls enabled"     || result_fail "BlockPublicAcls DISABLED"
    [[ "$ignore_acls" == "true" ]]  && result_pass "IgnorePublicAcls enabled"    || result_fail "IgnorePublicAcls DISABLED"
    [[ "$block_policy" == "true" ]] && result_pass "BlockPublicPolicy enabled"   || result_fail "BlockPublicPolicy DISABLED"
    [[ "$restrict" == "true" ]]     && result_pass "RestrictPublicBuckets enabled" || result_fail "RestrictPublicBuckets DISABLED"
}

# ─────────────────────────────────────────────────────────────────────────────
# Bucket Policy
# ─────────────────────────────────────────────────────────────────────────────

check_bucket_policy() {
    local bucket="$1"

    print_subheader "Bucket Policy"

    local policy
    policy=$(aws s3api get-bucket-policy --bucket "$bucket" --output text 2>/dev/null)

    if [[ -z "$policy" ]]; then
        result_info "No bucket policy attached"
        return
    fi

    result_info "Bucket policy exists"

    # Check for wildcard principal
    if echo "$policy" | jq -e '.Statement[] | select(.Principal == "*" or .Principal.AWS == "*")' &>/dev/null; then
        # Check if those wildcard statements are Allow
        if echo "$policy" | jq -e '.Statement[] | select((.Principal == "*" or .Principal.AWS == "*") and .Effect == "Allow")' &>/dev/null; then
            result_fail "Policy grants public access (Principal: \"*\" with Effect: Allow)"

            # Check for conditions that might limit it
            if echo "$policy" | jq -e '.Statement[] | select((.Principal == "*" or .Principal.AWS == "*") and .Effect == "Allow" and .Condition)' &>/dev/null; then
                result_warn "...but conditional restrictions exist (review manually)"
            fi
        fi

        # Wildcard Deny is fine (e.g., deny non-SSL)
        if echo "$policy" | jq -e '.Statement[] | select((.Principal == "*" or .Principal.AWS == "*") and .Effect == "Deny")' &>/dev/null; then
            result_pass "Policy contains Deny rules for wildcard principal (good)"
        fi
    else
        result_pass "No wildcard principal in policy"
    fi

    # Check for enforced SSL
    if echo "$policy" | jq -e '.Statement[] | select(.Effect == "Deny" and .Condition.Bool["aws:SecureTransport"] == "false")' &>/dev/null; then
        result_pass "Policy enforces SSL/TLS (denies non-HTTPS)"
    else
        result_warn "Policy does not enforce SSL/TLS"
        detail "Consider adding a Deny statement for aws:SecureTransport=false"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# ACL
# ─────────────────────────────────────────────────────────────────────────────

check_acl() {
    local bucket="$1"

    print_subheader "Access Control List (ACL)"

    local acl
    acl=$(aws s3api get-bucket-acl --bucket "$bucket" 2>/dev/null)

    if [[ -z "$acl" ]]; then
        result_skip "Could not retrieve ACL (access denied or not supported)"
        return
    fi

    # Check for public grants
    local public_uris=(
        "http://acs.amazonaws.com/groups/global/AllUsers"
        "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"
    )

    local has_public=false
    for uri in "${public_uris[@]}"; do
        local grants
        grants=$(echo "$acl" | jq -r --arg uri "$uri" '.Grants[] | select(.Grantee.URI == $uri) | "\(.Permission) → \(.Grantee.URI)"')
        if [[ -n "$grants" ]]; then
            has_public=true
            while IFS= read -r grant; do
                result_fail "Public ACL grant: ${grant}"
            done <<< "$grants"
        fi
    done

    if [[ "$has_public" == "false" ]]; then
        result_pass "No public ACL grants"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Ownership Controls
# ─────────────────────────────────────────────────────────────────────────────

check_ownership() {
    local bucket="$1"

    print_subheader "Ownership Controls"

    local ownership
    ownership=$(aws s3api get-bucket-ownership-controls --bucket "$bucket" 2>/dev/null)

    if [[ -z "$ownership" ]]; then
        result_warn "No ownership controls configured"
        detail "Consider setting BucketOwnerEnforced to disable ACLs entirely"
        return
    fi

    local rule
    rule=$(echo "$ownership" | jq -r '.OwnershipControls.Rules[0].ObjectOwnership')

    case "$rule" in
        BucketOwnerEnforced)
            result_pass "Ownership: BucketOwnerEnforced (ACLs disabled)"
            ;;
        BucketOwnerPreferred)
            result_warn "Ownership: BucketOwnerPreferred (ACLs still active)"
            detail "Consider upgrading to BucketOwnerEnforced to disable ACLs"
            ;;
        ObjectWriter)
            result_warn "Ownership: ObjectWriter (uploaders own objects)"
            detail "Consider BucketOwnerEnforced to simplify access control"
            ;;
        *)
            result_info "Ownership: ${rule}"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Encryption
# ─────────────────────────────────────────────────────────────────────────────

check_encryption() {
    local bucket="$1"

    print_subheader "Encryption"

    local enc
    enc=$(aws s3api get-bucket-encryption --bucket "$bucket" 2>/dev/null)

    if [[ -z "$enc" ]]; then
        result_fail "No default encryption configured"
        detail "Run: aws s3api put-bucket-encryption --bucket ${bucket} --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}'"
        return
    fi

    local algorithm
    algorithm=$(echo "$enc" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm')

    local kms_key
    kms_key=$(echo "$enc" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID // empty')

    local bucket_key
    bucket_key=$(echo "$enc" | jq -r '.ServerSideEncryptionConfiguration.Rules[0].BucketKeyEnabled // false')

    case "$algorithm" in
        "aws:kms"|"aws:kms:dsse")
            result_pass "Encryption: ${algorithm} (KMS-managed)"
            [[ -n "$kms_key" ]] && detail "KMS Key: ${kms_key}"
            [[ "$bucket_key" == "true" ]] && result_pass "Bucket key enabled (cost optimization)" || result_info "Bucket key not enabled"
            ;;
        AES256)
            result_pass "Encryption: AES256 (SSE-S3)"
            result_info "Consider KMS for key management and audit trail"
            ;;
        *)
            result_warn "Encryption algorithm: ${algorithm}"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Versioning
# ─────────────────────────────────────────────────────────────────────────────

check_versioning() {
    local bucket="$1"

    print_subheader "Versioning & Deletion Protection"

    local ver
    ver=$(aws s3api get-bucket-versioning --bucket "$bucket" 2>/dev/null)

    local status
    status=$(echo "$ver" | jq -r '.Status // "Disabled"')

    local mfa_delete
    mfa_delete=$(echo "$ver" | jq -r '.MFADelete // "Disabled"')

    case "$status" in
        Enabled)
            result_pass "Versioning: Enabled"
            ;;
        Suspended)
            result_warn "Versioning: Suspended (was previously enabled)"
            detail "Existing versions are retained but new versions are not created"
            ;;
        *)
            result_warn "Versioning: Disabled"
            detail "Enable versioning for accidental deletion protection"
            ;;
    esac

    [[ "$mfa_delete" == "Enabled" ]] && result_pass "MFA Delete: Enabled" || result_info "MFA Delete: Disabled"

    # Object Lock
    local lock
    lock=$(aws s3api get-object-lock-configuration --bucket "$bucket" 2>/dev/null)

    if [[ -n "$lock" ]]; then
        local lock_enabled
        lock_enabled=$(echo "$lock" | jq -r '.ObjectLockConfiguration.ObjectLockEnabled')

        if [[ "$lock_enabled" == "Enabled" ]]; then
            result_pass "Object Lock: Enabled"

            local rule_mode
            rule_mode=$(echo "$lock" | jq -r '.ObjectLockConfiguration.Rule.DefaultRetention.Mode // empty')
            local rule_days
            rule_days=$(echo "$lock" | jq -r '.ObjectLockConfiguration.Rule.DefaultRetention.Days // empty')
            local rule_years
            rule_years=$(echo "$lock" | jq -r '.ObjectLockConfiguration.Rule.DefaultRetention.Years // empty')

            if [[ -n "$rule_mode" ]]; then
                local period="${rule_days:+${rule_days} days}${rule_years:+${rule_years} years}"
                detail "Default retention: ${rule_mode} for ${period}"
            fi
        fi
    else
        result_info "Object Lock: Not configured"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Logging & Monitoring
# ─────────────────────────────────────────────────────────────────────────────

check_logging() {
    local bucket="$1"

    print_subheader "Logging & Monitoring"

    # Server access logging
    local logging
    logging=$(aws s3api get-bucket-logging --bucket "$bucket" 2>/dev/null)

    local log_bucket
    log_bucket=$(echo "$logging" | jq -r '.LoggingEnabled.TargetBucket // empty')

    if [[ -n "$log_bucket" ]]; then
        local log_prefix
        log_prefix=$(echo "$logging" | jq -r '.LoggingEnabled.TargetPrefix // "(none)"')
        result_pass "Server access logging: Enabled"
        detail "Target: s3://${log_bucket}/${log_prefix}"
    else
        result_warn "Server access logging: Disabled"
        detail "Enable for audit trail of bucket access"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Lifecycle Rules
# ─────────────────────────────────────────────────────────────────────────────

check_lifecycle() {
    local bucket="$1"

    print_subheader "Lifecycle Rules"

    local lifecycle
    lifecycle=$(aws s3api get-bucket-lifecycle-configuration --bucket "$bucket" 2>/dev/null)

    if [[ -z "$lifecycle" ]]; then
        result_info "No lifecycle rules configured"
        return
    fi

    local rule_count
    rule_count=$(echo "$lifecycle" | jq '.Rules | length')

    result_info "${rule_count} lifecycle rule(s) configured"

    echo "$lifecycle" | jq -r '.Rules[] | "  \(.ID // "unnamed") — Status: \(.Status)"' | while IFS= read -r line; do
        detail "$line"
    done

    # Check for abort incomplete multipart uploads
    if echo "$lifecycle" | jq -e '.Rules[] | select(.AbortIncompleteMultipartUpload)' &>/dev/null; then
        result_pass "Incomplete multipart upload cleanup configured"
    else
        result_warn "No cleanup rule for incomplete multipart uploads"
        detail "Incomplete uploads silently accumulate storage costs"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Website / CORS
# ─────────────────────────────────────────────────────────────────────────────

check_website_cors() {
    local bucket="$1"

    print_subheader "Static Website & CORS"

    # Website hosting
    local website
    website=$(aws s3api get-bucket-website --bucket "$bucket" 2>/dev/null)

    if [[ -n "$website" ]]; then
        result_warn "Static website hosting: Enabled"
        detail "This makes bucket contents accessible via HTTP endpoint"

        local index=$(echo "$website" | jq -r '.IndexDocument.Suffix // "n/a"')
        local error=$(echo "$website" | jq -r '.ErrorDocument.Key // "n/a"')
        detail "Index: ${index} | Error: ${error}"
    else
        result_pass "Static website hosting: Disabled"
    fi

    # CORS
    local cors
    cors=$(aws s3api get-bucket-cors --bucket "$bucket" 2>/dev/null)

    if [[ -n "$cors" ]]; then
        result_info "CORS rules configured"

        # Check for wildcard origins
        if echo "$cors" | jq -e '.CORSRules[] | select(.AllowedOrigins[] == "*")' &>/dev/null; then
            result_warn "CORS allows wildcard origin (*)"
            detail "Consider restricting to specific domains"
        else
            result_pass "CORS origins are restricted (no wildcard)"
        fi
    else
        result_info "No CORS configuration"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Replication
# ─────────────────────────────────────────────────────────────────────────────

check_replication() {
    local bucket="$1"

    print_subheader "Replication"

    local replication
    replication=$(aws s3api get-bucket-replication --bucket "$bucket" 2>/dev/null)

    if [[ -n "$replication" ]]; then
        result_info "Replication configured"

        echo "$replication" | jq -r '.ReplicationConfiguration.Rules[] | "  \(.ID // "unnamed") → \(.Destination.Bucket) [Status: \(.Status)]"' | while IFS= read -r line; do
            detail "$line"
        done
    else
        result_info "No replication configured"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
    local bucket="$1"

    print_header "Audit Summary"

    echo ""
    printf "  ${BOLD}Bucket:${RESET}  %s\n" "$bucket"
    echo ""

    printf "  ${GREEN}%-4d passed${RESET}" "$PASSED_CHECKS"
    printf "  ${YELLOW}%-4d warnings${RESET}" "$WARNED_CHECKS"
    printf "  ${RED}%-4d failed${RESET}" "$FAILED_CHECKS"
    printf "  ${GRAY}%-4d skipped${RESET}\n" "$SKIPPED_CHECKS"
    printf "  ${BOLD}%-4d total checks${RESET}\n" "$TOTAL_CHECKS"
    echo ""

    # Overall assessment
    if ((FAILED_CHECKS == 0 && WARNED_CHECKS == 0)); then
        echo -e "  ${GREEN}● Overall: GOOD — No issues found${RESET}"
    elif ((FAILED_CHECKS == 0)); then
        echo -e "  ${YELLOW}● Overall: FAIR — ${WARNED_CHECKS} item(s) to review${RESET}"
    elif ((FAILED_CHECKS <= 2)); then
        echo -e "  ${YELLOW}● Overall: NEEDS ATTENTION — ${FAILED_CHECKS} issue(s) to fix${RESET}"
    else
        echo -e "  ${RED}● Overall: AT RISK — ${FAILED_CHECKS} issue(s) require immediate attention${RESET}"
    fi

    echo -e "\n  ${DIM}Audit completed: $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 <s3-uri-or-bucket-name>"
    echo ""
    echo "Examples:"
    echo "  $0 s3://my-bucket"
    echo "  $0 s3://my-bucket/some/prefix"
    echo "  $0 my-bucket"
    exit 1
}

main() {
    if [[ $# -lt 1 || "$1" == "-h" || "$1" == "--help" ]]; then
        usage
    fi

    local bucket
    bucket=$(parse_bucket "$1")

    if [[ -z "$bucket" ]]; then
        echo -e "${RED}Error: Could not parse bucket name from '${1}'${RESET}" >&2
        usage
    fi

    echo -e "${BOLD}${WHITE}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║             S3 Bucket Security Audit Tool                    ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"

    check_prerequisites

    print_bucket_info "$bucket"
    check_public_access_block "$bucket"
    check_bucket_policy "$bucket"
    check_acl "$bucket"
    check_ownership "$bucket"
    check_encryption "$bucket"
    check_versioning "$bucket"
    check_logging "$bucket"
    check_lifecycle "$bucket"
    check_website_cors "$bucket"
    check_replication "$bucket"
    print_summary "$bucket"

    echo ""

    # Exit code reflects findings
    if ((FAILED_CHECKS > 0)); then
        exit 2
    elif ((WARNED_CHECKS > 0)); then
        exit 1
    fi
    exit 0
}

main "$@"
