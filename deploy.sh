#!/bin/bash
# NFW Proxy + VPC Lattice Resource Configuration - Deployment Script
#
# Usage:
#   ./deploy.sh --networking-profile <PROFILE> \
#               --workload-dev-profile <PROFILE> \
#               --workload-test-profile <PROFILE> \
#               [--region <REGION>] [--prefix <STACK_PREFIX>] \
#               <COMMAND>
#
# Commands:
#   all           - Deploy all resources (networking + both workloads)
#   networking    - Deploy networking account only
#   workload-dev  - Deploy workload dev account only
#   workload-test - Deploy workload test account only
#   cleanup       - Delete all resources
#   status        - Show deployment status
#
# Example:
#   ./deploy.sh --networking-profile NetworkingAdmin \
#               --workload-dev-profile DevAdmin \
#               --workload-test-profile TestAdmin \
#               all

set -e

# Default values
REGION="us-east-2"
STACK_PREFIX="egress-proxy"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_header() { echo -e "${BLUE}=== $1 ===${NC}"; }

# Parse arguments
NETWORKING_PROFILE=""
WORKLOAD_DEV_PROFILE=""
WORKLOAD_TEST_PROFILE=""
COMMAND=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --networking-profile)
            NETWORKING_PROFILE="$2"
            shift 2
            ;;
        --workload-dev-profile)
            WORKLOAD_DEV_PROFILE="$2"
            shift 2
            ;;
        --workload-test-profile)
            WORKLOAD_TEST_PROFILE="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --prefix)
            STACK_PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] COMMAND"
            echo ""
            echo "Options:"
            echo "  --networking-profile    AWS CLI profile for networking account"
            echo "  --workload-dev-profile  AWS CLI profile for workload dev account"
            echo "  --workload-test-profile AWS CLI profile for workload test account"
            echo "  --region                AWS region (default: us-east-2)"
            echo "  --prefix                Stack prefix (default: egress-proxy)"
            echo ""
            echo "Commands:"
            echo "  all           Deploy all resources"
            echo "  networking    Deploy networking account only"
            echo "  workload-dev  Deploy workload dev account only"
            echo "  workload-test Deploy workload test account only"
            echo "  cleanup       Delete all resources"
            echo "  status        Show deployment status"
            exit 0
            ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND="$1"
            else
                log_error "Unknown argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

# Get account ID from profile
get_account_id() {
    local profile="$1"
    aws sts get-caller-identity --profile "$profile" --query 'Account' --output text 2>/dev/null
}

# Validate required parameters based on command
validate_networking_params() {
    if [[ -z "$NETWORKING_PROFILE" ]]; then
        log_error "Missing --networking-profile"
        exit 1
    fi
    if [[ -z "$WORKLOAD_DEV_PROFILE" ]] || [[ -z "$WORKLOAD_TEST_PROFILE" ]]; then
        log_error "Missing --workload-dev-profile or --workload-test-profile (needed for RAM sharing)"
        exit 1
    fi
}

validate_workload_dev_params() {
    if [[ -z "$WORKLOAD_DEV_PROFILE" ]]; then
        log_error "Missing --workload-dev-profile"
        exit 1
    fi
}

validate_workload_test_params() {
    if [[ -z "$WORKLOAD_TEST_PROFILE" ]]; then
        log_error "Missing --workload-test-profile"
        exit 1
    fi
}

validate_all_params() {
    if [[ -z "$NETWORKING_PROFILE" ]]; then
        log_error "Missing --networking-profile"
        exit 1
    fi
    validate_workload_dev_params
    validate_workload_test_params
}

# Export environment variables for child scripts
export_env() {
    export EGRESS_REGION="$REGION"
    export EGRESS_STACK_PREFIX="$STACK_PREFIX"
    export EGRESS_NETWORKING_PROFILE="$NETWORKING_PROFILE"
    export EGRESS_WORKLOAD_DEV_PROFILE="$WORKLOAD_DEV_PROFILE"
    export EGRESS_WORKLOAD_TEST_PROFILE="$WORKLOAD_TEST_PROFILE"
    
    # Derive account IDs from profiles
    if [[ -n "$WORKLOAD_DEV_PROFILE" ]]; then
        export EGRESS_WORKLOAD_DEV_ACCOUNT=$(get_account_id "$WORKLOAD_DEV_PROFILE")
    fi
    if [[ -n "$WORKLOAD_TEST_PROFILE" ]]; then
        export EGRESS_WORKLOAD_TEST_ACCOUNT=$(get_account_id "$WORKLOAD_TEST_PROFILE")
    fi
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Command handlers
run_networking() {
    log_header "Deploying Networking Account"
    validate_networking_params
    export_env
    "$SCRIPT_DIR/01-networking-account.sh"
}

run_workload_dev() {
    log_header "Deploying Workload Dev Account"
    validate_workload_dev_params
    export_env
    "$SCRIPT_DIR/02-workload-dev.sh"
}

run_workload_test() {
    log_header "Deploying Workload Test Account"
    validate_workload_test_params
    export_env
    "$SCRIPT_DIR/03-workload-test.sh"
}

run_all() {
    log_header "Deploying All Resources"
    validate_all_params
    export_env
    
    log_info "Step 1/3: Networking Account"
    "$SCRIPT_DIR/01-networking-account.sh"
    
    log_info "Step 2/3: Workload Dev Account"
    "$SCRIPT_DIR/02-workload-dev.sh"
    
    log_info "Step 3/3: Workload Test Account"
    "$SCRIPT_DIR/03-workload-test.sh"
    
    log_info "All deployments complete!"
}

run_cleanup() {
    log_header "Cleaning Up All Resources"
    validate_all_params
    export_env
    "$SCRIPT_DIR/cleanup.sh"
}

run_status() {
    log_header "Deployment Status"
    
    echo ""
    log_info "Networking Account Resources:"
    if [[ -n "$NETWORKING_PROFILE" ]]; then
        echo "  CloudFormation Stacks:"
        aws cloudformation list-stacks \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
            --query "StackSummaries[?contains(StackName, '${STACK_PREFIX}')].{Name:StackName,Status:StackStatus}" \
            --output table --region "$REGION" --profile "$NETWORKING_PROFILE" 2>/dev/null || echo "    None found"
        
        echo "  NFW Proxies:"
        aws network-firewall list-proxies \
            --query "Proxies[?contains(Name, '${STACK_PREFIX}')].{Name:Name,State:ProxyState}" \
            --output table --region "$REGION" --profile "$NETWORKING_PROFILE" 2>/dev/null || echo "    None found"
        
        echo "  VPC Lattice Service Networks:"
        aws vpc-lattice list-service-networks \
            --query "items[?contains(name, '${STACK_PREFIX}')].{Name:name,Id:id}" \
            --output table --region "$REGION" --profile "$NETWORKING_PROFILE" 2>/dev/null || echo "    None found"
    else
        echo "  (--networking-profile not provided)"
    fi
    
    echo ""
    log_info "Workload Dev Account Resources:"
    if [[ -n "$WORKLOAD_DEV_PROFILE" ]]; then
        aws cloudformation list-stacks \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
            --query "StackSummaries[?contains(StackName, '${STACK_PREFIX}')].{Name:StackName,Status:StackStatus}" \
            --output table --region "$REGION" --profile "$WORKLOAD_DEV_PROFILE" 2>/dev/null || echo "    None found"
    else
        echo "  (--workload-dev-profile not provided)"
    fi
    
    echo ""
    log_info "Workload Test Account Resources:"
    if [[ -n "$WORKLOAD_TEST_PROFILE" ]]; then
        aws cloudformation list-stacks \
            --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
            --query "StackSummaries[?contains(StackName, '${STACK_PREFIX}')].{Name:StackName,Status:StackStatus}" \
            --output table --region "$REGION" --profile "$WORKLOAD_TEST_PROFILE" 2>/dev/null || echo "    None found"
    else
        echo "  (--workload-test-profile not provided)"
    fi
}

# Main
if [[ -z "$COMMAND" ]]; then
    log_error "No command specified. Use --help for usage."
    exit 1
fi

case "$COMMAND" in
    all)
        run_all
        ;;
    networking)
        run_networking
        ;;
    workload-dev)
        run_workload_dev
        ;;
    workload-test)
        run_workload_test
        ;;
    cleanup)
        run_cleanup
        ;;
    status)
        run_status
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        log_error "Use --help for usage."
        exit 1
        ;;
esac
