#!/bin/bash
# NFW Proxy + VPC Lattice - Cleanup Script
# Deletes all resources created by the test scripts
#
# Run via deploy.sh or set environment variables:
#   EGRESS_NETWORKING_PROFILE, EGRESS_WORKLOAD_DEV_PROFILE, EGRESS_WORKLOAD_TEST_PROFILE
#   EGRESS_REGION (optional, default: us-east-2)
#   EGRESS_STACK_PREFIX (optional, default: egress-proxy)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get configuration from environment variables or use defaults
PROFILE_NETWORKING="${EGRESS_NETWORKING_PROFILE:-}"
PROFILE_WORKLOAD_DEV="${EGRESS_WORKLOAD_DEV_PROFILE:-}"
PROFILE_WORKLOAD_TEST="${EGRESS_WORKLOAD_TEST_PROFILE:-}"
REGION="${EGRESS_REGION:-us-east-2}"
STACK_PREFIX="${EGRESS_STACK_PREFIX:-egress-proxy}"

# Validate required parameters
if [[ -z "$PROFILE_NETWORKING" ]] || [[ -z "$PROFILE_WORKLOAD_DEV" ]] || [[ -z "$PROFILE_WORKLOAD_TEST" ]]; then
    log_error "All profile environment variables must be set."
    log_error "Run via deploy.sh or set: EGRESS_NETWORKING_PROFILE, EGRESS_WORKLOAD_DEV_PROFILE, EGRESS_WORKLOAD_TEST_PROFILE"
    exit 1
fi

echo "============================================================================"
echo "NFW Proxy + VPC Lattice - Cleanup"
echo "============================================================================"
echo ""
log_info "Region: $REGION"
log_info "Stack Prefix: $STACK_PREFIX"
log_info "Networking Profile: $PROFILE_NETWORKING"
log_info "Workload Dev Profile: $PROFILE_WORKLOAD_DEV"
log_info "Workload Test Profile: $PROFILE_WORKLOAD_TEST"
echo ""
log_warn "This will delete ALL resources created by the test scripts!"
echo ""
read -p "Are you sure you want to continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    log_info "Cleanup cancelled"
    exit 0
fi

# ============================================================================
# STEP 1: Cleanup Workload Test Account
# ============================================================================
log_info "Step 1: Cleaning up Workload Test Account..."

PROFILE="$PROFILE_WORKLOAD_TEST"

# Delete VPC association
log_info "Deleting VPC Lattice associations..."
for ASSOC_ID in $(aws vpc-lattice list-service-network-vpc-associations \
    --query "items[?contains(id, '${STACK_PREFIX}')].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting association: $ASSOC_ID"
    aws vpc-lattice delete-service-network-vpc-association \
        --service-network-vpc-association-identifier $ASSOC_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Delete Lattice security group
log_info "Deleting Lattice security groups..."
for SG_ID in $(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${STACK_PREFIX}-lattice-sg-test" \
    --query 'SecurityGroups[*].GroupId' --output text \
    --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting security group: $SG_ID"
    aws ec2 delete-security-group --group-id $SG_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Delete CloudFormation stack
log_info "Deleting CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name ${STACK_PREFIX}-workload-vpc-test \
    --region $REGION --profile $PROFILE 2>/dev/null || true

aws cloudformation wait stack-delete-complete \
    --stack-name ${STACK_PREFIX}-workload-vpc-test \
    --region $REGION --profile $PROFILE 2>/dev/null || true

log_info "Workload Test cleanup complete"

# ============================================================================
# STEP 2: Cleanup Workload Dev Account
# ============================================================================
log_info "Step 2: Cleaning up Workload Dev Account..."

PROFILE="$PROFILE_WORKLOAD_DEV"

# Delete VPC association
log_info "Deleting VPC Lattice associations..."
for ASSOC_ID in $(aws vpc-lattice list-service-network-vpc-associations \
    --query "items[?contains(id, '${STACK_PREFIX}')].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting association: $ASSOC_ID"
    aws vpc-lattice delete-service-network-vpc-association \
        --service-network-vpc-association-identifier $ASSOC_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Delete Lattice security group
log_info "Deleting Lattice security groups..."
for SG_ID in $(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${STACK_PREFIX}-lattice-sg-dev" \
    --query 'SecurityGroups[*].GroupId' --output text \
    --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting security group: $SG_ID"
    aws ec2 delete-security-group --group-id $SG_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Delete CloudFormation stack
log_info "Deleting CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name ${STACK_PREFIX}-workload-vpc-dev \
    --region $REGION --profile $PROFILE 2>/dev/null || true

aws cloudformation wait stack-delete-complete \
    --stack-name ${STACK_PREFIX}-workload-vpc-dev \
    --region $REGION --profile $PROFILE 2>/dev/null || true

log_info "Workload Dev cleanup complete"

# ============================================================================
# STEP 3: Cleanup Networking Account
# ============================================================================
log_info "Step 3: Cleaning up Networking Account..."

PROFILE="$PROFILE_NETWORKING"

# Delete RAM share
log_info "Deleting RAM resource share..."
RAM_SHARE_ARN=$(aws ram get-resource-shares \
    --resource-owner SELF \
    --name ${STACK_PREFIX}-lattice-share \
    --query 'resourceShares[0].resourceShareArn' --output text \
    --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$RAM_SHARE_ARN" ] && [ "$RAM_SHARE_ARN" != "None" ]; then
    aws ram delete-resource-share \
        --resource-share-arn $RAM_SHARE_ARN \
        --region $REGION --profile $PROFILE 2>/dev/null || true
fi

# Delete Service Network Resource Associations
log_info "Deleting Service Network Resource Associations..."
SERVICE_NETWORK_ID=$(aws vpc-lattice list-service-networks \
    --query "items[?name=='${STACK_PREFIX}-service-network'].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$SERVICE_NETWORK_ID" ] && [ "$SERVICE_NETWORK_ID" != "None" ]; then
    for ASSOC_ID in $(aws vpc-lattice list-service-network-resource-associations \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --query 'items[*].id' --output text \
        --region $REGION --profile $PROFILE 2>/dev/null); do
        log_info "Deleting resource association: $ASSOC_ID"
        aws vpc-lattice delete-service-network-resource-association \
            --service-network-resource-association-identifier $ASSOC_ID \
            --region $REGION --profile $PROFILE 2>/dev/null || true
    done
fi

# Delete Resource Configurations
log_info "Deleting Resource Configurations..."
for RC_ID in $(aws vpc-lattice list-resource-configurations \
    --query "items[?contains(name, '${STACK_PREFIX}')].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting resource configuration: $RC_ID"
    aws vpc-lattice delete-resource-configuration \
        --resource-configuration-identifier $RC_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Delete Resource Gateways
log_info "Deleting Resource Gateways..."
for RGW_ID in $(aws vpc-lattice list-resource-gateways \
    --query "items[?contains(name, '${STACK_PREFIX}')].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null); do
    log_info "Deleting resource gateway: $RGW_ID"
    aws vpc-lattice delete-resource-gateway \
        --resource-gateway-identifier $RGW_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
done

# Delete Service Network
log_info "Deleting Service Network..."
if [ -n "$SERVICE_NETWORK_ID" ] && [ "$SERVICE_NETWORK_ID" != "None" ]; then
    aws vpc-lattice delete-service-network \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --region $REGION --profile $PROFILE 2>/dev/null || true
fi

# Delete CloudFormation stack
log_info "Deleting CloudFormation stack..."
aws cloudformation delete-stack \
    --stack-name ${STACK_PREFIX}-egress-vpc \
    --region $REGION --profile $PROFILE 2>/dev/null || true

aws cloudformation wait stack-delete-complete \
    --stack-name ${STACK_PREFIX}-egress-vpc \
    --region $REGION --profile $PROFILE 2>/dev/null || true

log_info "Networking Account cleanup complete"

# ============================================================================
# STEP 4: Cleanup NFW Proxy Resources
# ============================================================================
log_info "Step 4: Cleaning up NFW Proxy Resources..."

PROFILE="$PROFILE_NETWORKING"

# Delete Proxy
log_info "Deleting NFW Proxy..."
aws network-firewall delete-proxy \
    --proxy-name ${STACK_PREFIX}-proxy \
    --region $REGION --profile $PROFILE 2>/dev/null || true

# Wait for proxy to be deleted
log_info "Waiting for Proxy to be deleted..."
while true; do
    PROXY_EXISTS=$(aws network-firewall list-proxies \
        --query "Proxies[?Name=='${STACK_PREFIX}-proxy'].Name" \
        --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")
    if [ -z "$PROXY_EXISTS" ] || [ "$PROXY_EXISTS" == "None" ]; then
        log_info "Proxy deleted"
        break
    fi
    log_info "Waiting for proxy deletion..."
    sleep 10
done

# Delete Proxy Configuration
log_info "Deleting NFW Proxy Configuration..."
aws network-firewall delete-proxy-configuration \
    --proxy-configuration-name ${STACK_PREFIX}-config \
    --region $REGION --profile $PROFILE 2>/dev/null || true

# Delete Proxy Rule Group
log_info "Deleting NFW Proxy Rule Group..."
aws network-firewall delete-proxy-rule-group \
    --proxy-rule-group-name ${STACK_PREFIX}-rule-group \
    --region $REGION --profile $PROFILE 2>/dev/null || true

log_info "NFW Proxy resources cleanup complete"

# ============================================================================
# STEP 5: Cleanup Route 53 Private Hosted Zone
# ============================================================================
log_info "Step 5: Cleaning up Route 53 Private Hosted Zone..."

PROFILE="$PROFILE_NETWORKING"

# Find PHZ for proxy.internal
PHZ_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "proxy.internal" \
    --query "HostedZones[?Name=='proxy.internal.'].Id" \
    --output text --profile $PROFILE 2>/dev/null | head -1 | sed 's|/hostedzone/||')

if [ -n "$PHZ_ID" ] && [ "$PHZ_ID" != "None" ] && [ "$PHZ_ID" != "" ]; then
    log_info "Found PHZ: $PHZ_ID"
    
    # First, disassociate all VPCs except the one that created it
    log_info "Disassociating VPCs from PHZ..."
    
    # Get all associated VPCs
    ASSOCIATED_VPCS=$(aws route53 get-hosted-zone \
        --id $PHZ_ID \
        --query 'VPCs[*].VPCId' --output text \
        --profile $PROFILE 2>/dev/null || echo "")
    
    # We need to keep at least one VPC associated (the one that created the PHZ)
    # So we'll delete the PHZ which will automatically disassociate all VPCs
    
    # Delete all resource record sets except NS and SOA
    log_info "Deleting resource record sets..."
    RECORD_SETS=$(aws route53 list-resource-record-sets \
        --hosted-zone-id $PHZ_ID \
        --query "ResourceRecordSets[?Type!='NS' && Type!='SOA']" \
        --profile $PROFILE 2>/dev/null)
    
    if [ -n "$RECORD_SETS" ] && [ "$RECORD_SETS" != "[]" ]; then
        # Build change batch to delete records
        echo "$RECORD_SETS" | jq -c '.[]' | while read -r record; do
            NAME=$(echo "$record" | jq -r '.Name')
            TYPE=$(echo "$record" | jq -r '.Type')
            log_info "Deleting record: $NAME ($TYPE)"
            
            aws route53 change-resource-record-sets \
                --hosted-zone-id $PHZ_ID \
                --change-batch "{
                    \"Changes\": [{
                        \"Action\": \"DELETE\",
                        \"ResourceRecordSet\": $record
                    }]
                }" \
                --profile $PROFILE 2>/dev/null || true
        done
    fi
    
    # Delete the PHZ
    log_info "Deleting PHZ..."
    aws route53 delete-hosted-zone \
        --id $PHZ_ID \
        --profile $PROFILE 2>/dev/null && \
        log_info "PHZ deleted" || \
        log_warn "Could not delete PHZ - may have associated VPCs"
else
    log_info "No PHZ found for proxy.internal"
fi

log_info "Route 53 cleanup complete"
