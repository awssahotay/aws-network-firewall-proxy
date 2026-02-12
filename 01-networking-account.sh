#!/bin/bash
# NFW Proxy Test - Networking Account Setup
# 
# This script creates:
# - Egress VPC (172.16.0.0/16) with public and private subnets
# - Internet Gateway and NAT Gateway
# - NFW Proxy attached to NAT Gateway
# - VPC Lattice Service Network
# - Resource Gateway
# - Resource Configuration pointing to NFW Proxy VPCE domain
#
# ============================================================================
# ⚠️  UPDATE THIS PROFILE NAME TO MATCH YOUR AWS CLI CONFIGURATION
# ============================================================================
PROFILE="Networking"  # <-- CHANGE THIS to your Networking account profile
# ============================================================================
# Profile names: Networking, Workload_Dev, Workload_Test

# ============================================================================
# ⚠️  UPDATE THESE WORKLOAD ACCOUNT IDs FOR YOUR ENVIRONMENT
# ============================================================================
WORKLOAD_DEV_ACCOUNT="111111111111"    # <-- CHANGE THIS to your Workload Dev account ID
WORKLOAD_TEST_ACCOUNT="222222222222"   # <-- CHANGE THIS to your Workload Test account ID
# ============================================================================

set -e
REGION="us-east-2"
STACK_PREFIX="network-firewall-proxy"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE --query 'Account' --output text)
log_info "Networking Account ID: $ACCOUNT_ID"

# ============================================================================
# STEP 1: Create Egress VPC with CloudFormation
# ============================================================================
log_info "Step 1: Creating Egress VPC..."

cat > /tmp/egress-vpc.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: NFW Proxy Test - Egress VPC in Networking Account

Parameters:
  StackPrefix:
    Type: String
    Default: nfw-proxy-test

Resources:
  # VPC
  EgressVPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 172.16.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-egress-vpc'

  # Internet Gateway
  InternetGateway:
    Type: AWS::EC2::InternetGateway
    Properties:
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-igw'

  IGWAttachment:
    Type: AWS::EC2::VPCGatewayAttachment
    Properties:
      VpcId: !Ref EgressVPC
      InternetGatewayId: !Ref InternetGateway

  # Public Subnet (for NAT Gateway)
  PublicSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref EgressVPC
      CidrBlock: 172.16.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      MapPublicIpOnLaunch: true
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-public-subnet'

  # Private Subnet (for Resource Gateway)
  PrivateSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref EgressVPC
      CidrBlock: 172.16.2.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-private-subnet'

  # Elastic IP for NAT Gateway
  NatEIP:
    Type: AWS::EC2::EIP
    DependsOn: IGWAttachment
    Properties:
      Domain: vpc
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-nat-eip'

  # NAT Gateway
  NatGateway:
    Type: AWS::EC2::NatGateway
    Properties:
      AllocationId: !GetAtt NatEIP.AllocationId
      SubnetId: !Ref PublicSubnet
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-nat-gw'

  # Public Route Table
  PublicRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref EgressVPC
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-public-rt'

  PublicRoute:
    Type: AWS::EC2::Route
    DependsOn: IGWAttachment
    Properties:
      RouteTableId: !Ref PublicRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      GatewayId: !Ref InternetGateway

  PublicSubnetRTAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PublicSubnet
      RouteTableId: !Ref PublicRouteTable

  # Private Route Table
  PrivateRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref EgressVPC
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-private-rt'

  PrivateRoute:
    Type: AWS::EC2::Route
    Properties:
      RouteTableId: !Ref PrivateRouteTable
      DestinationCidrBlock: 0.0.0.0/0
      NatGatewayId: !Ref NatGateway

  PrivateSubnetRTAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnet
      RouteTableId: !Ref PrivateRouteTable

Outputs:
  VpcId:
    Value: !Ref EgressVPC
    Export:
      Name: !Sub '${StackPrefix}-egress-vpc-id'
  
  PublicSubnetId:
    Value: !Ref PublicSubnet
    Export:
      Name: !Sub '${StackPrefix}-public-subnet-id'
  
  PrivateSubnetId:
    Value: !Ref PrivateSubnet
    Export:
      Name: !Sub '${StackPrefix}-private-subnet-id'
  
  NatGatewayId:
    Value: !Ref NatGateway
    Export:
      Name: !Sub '${StackPrefix}-nat-gw-id'
EOF

aws cloudformation deploy \
    --template-file /tmp/egress-vpc.yaml \
    --stack-name ${STACK_PREFIX}-egress-vpc \
    --parameter-overrides StackPrefix=${STACK_PREFIX} \
    --region $REGION \
    --profile $PROFILE

log_info "Egress VPC created successfully"

# Get outputs
VPC_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-egress-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
PUBLIC_SUBNET_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-egress-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`PublicSubnetId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
PRIVATE_SUBNET_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-egress-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
NAT_GW_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-egress-vpc \
    --query 'Stacks[0].Outputs[?OutputKey==`NatGatewayId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)

log_info "VPC ID: $VPC_ID"
log_info "Public Subnet: $PUBLIC_SUBNET_ID"
log_info "Private Subnet: $PRIVATE_SUBNET_ID"
log_info "NAT Gateway: $NAT_GW_ID"

# ============================================================================
# STEP 2: Create NFW Proxy Rule Group
# ============================================================================
log_info "Step 2: Creating NFW Proxy Rule Group..."

# Check if rule group already exists
EXISTING_RULE_GROUP=$(aws network-firewall list-proxy-rule-groups \
    --query "ProxyRuleGroups[?Name=='${STACK_PREFIX}-rule-group'].Arn" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$EXISTING_RULE_GROUP" ] && [ "$EXISTING_RULE_GROUP" != "None" ] && [ "$EXISTING_RULE_GROUP" != "" ]; then
    RULE_GROUP_ARN=$EXISTING_RULE_GROUP
    log_info "Using existing Rule Group: $RULE_GROUP_ARN"
else
    # Create rule group with domain allowlist
    # Valid ConditionKeys: request:DestinationDomain, request:Http:Uri, request:Http:Method, etc.
    RULE_GROUP_RESPONSE=$(aws network-firewall create-proxy-rule-group \
        --proxy-rule-group-name ${STACK_PREFIX}-rule-group \
        --description "Allow common domains for testing" \
        --rules '{
            "PreDNS": [
                {
                    "ProxyRuleName": "allow-aws",
                    "Description": "Allow AWS domains",
                    "Action": "ALLOW",
                    "Conditions": [
                        {
                            "ConditionOperator": "StringLike",
                            "ConditionKey": "request:DestinationDomain",
                            "ConditionValues": ["*.amazonaws.com", "*.aws.amazon.com"]
                        }
                    ]
                },
                {
                    "ProxyRuleName": "allow-common",
                    "Description": "Allow common test domains",
                    "Action": "ALLOW",
                    "Conditions": [
                        {
                            "ConditionOperator": "StringLike",
                            "ConditionKey": "request:DestinationDomain",
                            "ConditionValues": ["example.com", "*.example.com", "httpbin.org"]
                        }
                    ]
                }
            ]
        }' \
        --region $REGION \
        --profile $PROFILE 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        RULE_GROUP_ARN=$(echo $RULE_GROUP_RESPONSE | jq -r '.ProxyRuleGroup.ProxyRuleGroupArn')
        log_info "Created Rule Group: $RULE_GROUP_ARN"
    else
        # Rule group might exist but wasn't found in list - try to get it directly
        RULE_GROUP_ARN=$(aws network-firewall describe-proxy-rule-group \
            --proxy-rule-group-name ${STACK_PREFIX}-rule-group \
            --query 'ProxyRuleGroup.ProxyRuleGroupArn' --output text \
            --region $REGION --profile $PROFILE)
        log_info "Found existing Rule Group: $RULE_GROUP_ARN"
    fi
fi

# ============================================================================
# STEP 3: Create NFW Proxy Configuration
# ============================================================================
log_info "Step 3: Creating NFW Proxy Configuration..."

# Check if configuration already exists
EXISTING_CONFIG=$(aws network-firewall list-proxy-configurations \
    --query "ProxyConfigurations[?Name=='${STACK_PREFIX}-config'].Arn" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$EXISTING_CONFIG" ] && [ "$EXISTING_CONFIG" != "None" ] && [ "$EXISTING_CONFIG" != "" ]; then
    PROXY_CONFIG_ARN=$EXISTING_CONFIG
    log_info "Using existing Proxy Configuration: $PROXY_CONFIG_ARN"
else
    PROXY_CONFIG_RESPONSE=$(aws network-firewall create-proxy-configuration \
        --proxy-configuration-name ${STACK_PREFIX}-config \
        --description "Proxy configuration for testing" \
        --rule-group-arns "$RULE_GROUP_ARN" \
        --default-rule-phase-actions "PreDNS=ALLOW,PreREQUEST=ALLOW,PostRESPONSE=ALLOW" \
        --region $REGION \
        --profile $PROFILE 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        PROXY_CONFIG_ARN=$(echo $PROXY_CONFIG_RESPONSE | jq -r '.ProxyConfiguration.ProxyConfigurationArn')
        log_info "Created Proxy Configuration: $PROXY_CONFIG_ARN"
    else
        # Config might exist but wasn't found in list - try to get it directly
        PROXY_CONFIG_ARN=$(aws network-firewall describe-proxy-configuration \
            --proxy-configuration-name ${STACK_PREFIX}-config \
            --query 'ProxyConfiguration.ProxyConfigurationArn' --output text \
            --region $REGION --profile $PROFILE)
        log_info "Found existing Proxy Configuration: $PROXY_CONFIG_ARN"
    fi
fi

# ============================================================================
# STEP 4: Create NFW Proxy
# ============================================================================
log_info "Step 4: Creating NFW Proxy..."

# Check if proxy already exists
EXISTING_PROXY=$(aws network-firewall list-proxies \
    --query "Proxies[?Name=='${STACK_PREFIX}-proxy'].Arn" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$EXISTING_PROXY" ] && [ "$EXISTING_PROXY" != "None" ] && [ "$EXISTING_PROXY" != "" ]; then
    PROXY_ARN=$EXISTING_PROXY
    log_info "Using existing Proxy: $PROXY_ARN"
else
    # Create proxy attached to NAT Gateway
    # TLS intercept disabled for simpler testing
    PROXY_RESPONSE=$(aws network-firewall create-proxy \
        --proxy-name ${STACK_PREFIX}-proxy \
        --nat-gateway-id $NAT_GW_ID \
        --proxy-configuration-arn "$PROXY_CONFIG_ARN" \
        --listener-properties "Port=3128,Type=HTTP" "Port=3129,Type=HTTPS" \
        --tls-intercept-properties "TlsInterceptMode=DISABLED" \
        --region $REGION \
        --profile $PROFILE 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        PROXY_ARN=$(echo $PROXY_RESPONSE | jq -r '.Proxy.ProxyArn')
        log_info "Created Proxy: $PROXY_ARN"
    else
        # Proxy might exist but wasn't found in list - try to get it directly
        PROXY_ARN=$(aws network-firewall describe-proxy \
            --proxy-name ${STACK_PREFIX}-proxy \
            --query 'Proxy.ProxyArn' --output text \
            --region $REGION --profile $PROFILE)
        log_info "Found existing Proxy: $PROXY_ARN"
    fi
fi

# Wait for proxy to be attached (can take 20-30 minutes)
log_info "Waiting for Proxy to become ATTACHED..."
log_warn "NFW Proxy attachment typically takes 20-30 minutes. Checking every 5 minutes..."
echo ""

WAIT_START=$(date +%s)
WAIT_COUNT=0
MAX_WAIT_MINS=45

while true; do
    PROXY_STATE=$(aws network-firewall describe-proxy \
        --proxy-name ${STACK_PREFIX}-proxy \
        --query 'Proxy.ProxyState' --output text \
        --region $REGION --profile $PROFILE)
    
    ELAPSED_SECS=$(($(date +%s) - WAIT_START))
    ELAPSED_MINS=$((ELAPSED_SECS / 60))
    
    if [ "$PROXY_STATE" == "ATTACHED" ]; then
        echo ""
        log_info "✅ Proxy is ATTACHED (took ${ELAPSED_MINS} minutes)"
        break
    elif [ "$PROXY_STATE" == "ATTACH_FAILED" ]; then
        echo ""
        log_error "❌ Proxy attachment failed!"
        aws network-firewall describe-proxy \
            --proxy-name ${STACK_PREFIX}-proxy \
            --query 'Proxy.{FailureCode:FailureCode,FailureMessage:FailureMessage}' \
            --region $REGION --profile $PROFILE
        exit 1
    fi
    
    # Check if we've exceeded max wait time
    if [ $ELAPSED_MINS -ge $MAX_WAIT_MINS ]; then
        echo ""
        log_error "❌ Timeout waiting for proxy after ${MAX_WAIT_MINS} minutes"
        log_error "Current state: $PROXY_STATE"
        exit 1
    fi
    
    WAIT_COUNT=$((WAIT_COUNT + 1))
    echo -ne "\r  [${ELAPSED_MINS}m elapsed] Proxy state: $PROXY_STATE - checking again in 5 minutes... (check #${WAIT_COUNT})    "
    sleep 300  # 5 minutes
done

# Get the VPCE domain from the proxy
log_info "Getting NFW Proxy VPCE Domain..."

# Get proxy details - this contains VpcEndpointServiceName which we can use to find the VPCE
PROXY_DETAILS=$(aws network-firewall describe-proxy \
    --proxy-name ${STACK_PREFIX}-proxy \
    --region $REGION --profile $PROFILE)

log_info "Proxy Details:"
echo "$PROXY_DETAILS" | jq '.'

# Extract the VPC Endpoint Service Name from proxy details
VPCE_SERVICE_NAME=$(echo "$PROXY_DETAILS" | jq -r '.Proxy.VpcEndpointServiceName')
log_info "VPCE Service Name: $VPCE_SERVICE_NAME"

# Find VPC endpoints created by the proxy using the exact service name
log_info "Looking for NFW Proxy VPC Endpoint..."
sleep 5  # Give time for endpoint to be created

NFW_VPCE=$(aws ec2 describe-vpc-endpoints \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=service-name,Values=$VPCE_SERVICE_NAME" \
    --query 'VpcEndpoints[0]' \
    --region $REGION --profile $PROFILE 2>/dev/null)

if [ -z "$NFW_VPCE" ] || [ "$NFW_VPCE" == "null" ]; then
    # Fallback: list all endpoints and find the one with proxy.nfw in service name
    log_info "Searching for NFW Proxy endpoint in VPC (fallback)..."
    NFW_VPCE=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=$VPC_ID" \
        --query "VpcEndpoints[?contains(ServiceName, 'proxy.nfw')] | [0]" \
        --region $REGION --profile $PROFILE 2>/dev/null)
fi

if [ -n "$NFW_VPCE" ] && [ "$NFW_VPCE" != "null" ]; then
    NFW_PROXY_VPCE_ID=$(echo $NFW_VPCE | jq -r '.VpcEndpointId')
    NFW_PROXY_VPCE_DOMAIN=$(echo $NFW_VPCE | jq -r '.DnsEntries[0].DnsName')
    log_info "Found NFW Proxy VPCE: $NFW_PROXY_VPCE_ID"
    log_info "NFW Proxy VPCE Domain: $NFW_PROXY_VPCE_DOMAIN"
else
    # VPCE not found via EC2 API - this can happen, use PrivateDNSName from proxy as fallback
    log_warn "Could not find NFW Proxy VPCE via EC2 API in VPC $VPC_ID"
    log_warn "Using PrivateDNSName from proxy description as fallback..."
    
    # The PrivateDNSName format is: <ID>.proxy.nfw.us-east-2.amazonaws.com
    # We need to construct the VPCE domain format: vpce-xxx.<ID>.proxy.nfw.us-east-2.vpce.amazonaws.com
    PRIVATE_DNS=$(echo "$PROXY_DETAILS" | jq -r '.Proxy.PrivateDNSName')
    log_info "Proxy PrivateDNSName: $PRIVATE_DNS"
    
    # For now, we'll continue without the VPCE domain - the Resource Configuration
    # will need to be created manually or we'll use an existing one
    NFW_PROXY_VPCE_DOMAIN=""
    NFW_PROXY_VPCE_ID=""
    
    log_warn "⚠️  VPCE domain not found. You may need to:"
    log_warn "   1. Wait a few minutes and check again"
    log_warn "   2. Find the VPCE manually in the AWS Console"
    log_warn "   3. Use an existing Resource Configuration"
    log_warn ""
    log_warn "Continuing with remaining setup steps..."
fi

if [ -n "$NFW_PROXY_VPCE_DOMAIN" ]; then
    log_info "NFW Proxy VPCE Domain: $NFW_PROXY_VPCE_DOMAIN"
fi

# ============================================================================
# STEP 5: Create VPC Lattice Service Network
# ============================================================================
log_info "Step 5: Creating VPC Lattice Service Network..."

SERVICE_NETWORK_ID=$(aws vpc-lattice create-service-network \
    --name ${STACK_PREFIX}-service-network \
    --auth-type NONE \
    --region $REGION \
    --profile $PROFILE \
    --query 'id' --output text 2>/dev/null || \
    aws vpc-lattice list-service-networks \
    --query "items[?name=='${STACK_PREFIX}-service-network'].id" \
    --output text --region $REGION --profile $PROFILE)

log_info "Service Network ID: $SERVICE_NETWORK_ID"

# Get Service Network ARN
SERVICE_NETWORK_ARN=$(aws vpc-lattice get-service-network \
    --service-network-identifier $SERVICE_NETWORK_ID \
    --query 'arn' --output text \
    --region $REGION --profile $PROFILE)

log_info "Service Network ARN: $SERVICE_NETWORK_ARN"

# ============================================================================
# STEP 6: Create Resource Gateway
# ============================================================================
log_info "Step 6: Creating Resource Gateway..."

# Check if Resource Gateway already exists
EXISTING_RGW=$(aws vpc-lattice list-resource-gateways \
    --query "items[?name=='${STACK_PREFIX}-resource-gateway'].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$EXISTING_RGW" ] && [ "$EXISTING_RGW" != "None" ]; then
    RESOURCE_GATEWAY_ID=$EXISTING_RGW
    log_info "Using existing Resource Gateway: $RESOURCE_GATEWAY_ID"
else
    RESOURCE_GATEWAY_ID=$(aws vpc-lattice create-resource-gateway \
        --name ${STACK_PREFIX}-resource-gateway \
        --vpc-identifier $VPC_ID \
        --subnet-ids $PRIVATE_SUBNET_ID \
        --region $REGION \
        --profile $PROFILE \
        --query 'id' --output text)
    log_info "Created Resource Gateway: $RESOURCE_GATEWAY_ID"
fi

# Wait for Resource Gateway to be active
log_info "Waiting for Resource Gateway to become active..."
while true; do
    STATUS=$(aws vpc-lattice get-resource-gateway \
        --resource-gateway-identifier $RESOURCE_GATEWAY_ID \
        --query 'status' --output text \
        --region $REGION --profile $PROFILE)
    if [ "$STATUS" == "ACTIVE" ]; then
        log_info "Resource Gateway is ACTIVE"
        break
    fi
    log_info "Resource Gateway status: $STATUS - waiting..."
    sleep 10
done

# ============================================================================
# STEP 7: Create Resource Configuration
# ============================================================================
log_info "Step 7: Creating Resource Configuration..."

# Check if we have a VPCE domain to use
if [ -z "$NFW_PROXY_VPCE_DOMAIN" ]; then
    log_warn "⚠️  Skipping Resource Configuration - no VPCE domain available"
    log_warn "You will need to create the Resource Configuration manually once VPCE is available"
    RESOURCE_CONFIG_ID=""
    RESOURCE_ASSOC_ID=""
else
    # Check if Resource Configuration already exists
    EXISTING_RC=$(aws vpc-lattice list-resource-configurations \
        --query "items[?name=='${STACK_PREFIX}-proxy-resource'].id" \
        --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

    if [ -n "$EXISTING_RC" ] && [ "$EXISTING_RC" != "None" ]; then
        RESOURCE_CONFIG_ID=$EXISTING_RC
        log_info "Using existing Resource Configuration: $RESOURCE_CONFIG_ID"
    else
        RESOURCE_CONFIG_ID=$(aws vpc-lattice create-resource-configuration \
            --name ${STACK_PREFIX}-proxy-resource \
            --type SINGLE \
            --resource-gateway-identifier $RESOURCE_GATEWAY_ID \
            --port-ranges 3128 \
            --protocol TCP \
            --resource-configuration-definition "dnsResource={domainName=${NFW_PROXY_VPCE_DOMAIN},ipAddressType=IPV4}" \
            --region $REGION \
            --profile $PROFILE \
            --query 'id' --output text)
        log_info "Created Resource Configuration: $RESOURCE_CONFIG_ID"
    fi

    # Wait for Resource Configuration to be active
    log_info "Waiting for Resource Configuration to become active..."
    while true; do
        STATUS=$(aws vpc-lattice get-resource-configuration \
            --resource-configuration-identifier $RESOURCE_CONFIG_ID \
            --query 'status' --output text \
            --region $REGION --profile $PROFILE)
        if [ "$STATUS" == "ACTIVE" ]; then
            log_info "Resource Configuration is ACTIVE"
            break
        fi
        log_info "Resource Configuration status: $STATUS - waiting..."
        sleep 10
    done

    # ============================================================================
    # STEP 8: Associate Resource Configuration with Service Network
    # ============================================================================
    log_info "Step 8: Associating Resource Configuration with Service Network..."

    # Check if association already exists
    EXISTING_ASSOC=$(aws vpc-lattice list-service-network-resource-associations \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --query "items[?resourceConfigurationId=='${RESOURCE_CONFIG_ID}'].id" \
        --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

    if [ -n "$EXISTING_ASSOC" ] && [ "$EXISTING_ASSOC" != "None" ]; then
        RESOURCE_ASSOC_ID=$EXISTING_ASSOC
        log_info "Using existing association: $RESOURCE_ASSOC_ID"
    else
        RESOURCE_ASSOC_ID=$(aws vpc-lattice create-service-network-resource-association \
            --service-network-identifier $SERVICE_NETWORK_ID \
            --resource-configuration-identifier $RESOURCE_CONFIG_ID \
            --region $REGION \
            --profile $PROFILE \
            --query 'id' --output text)
        log_info "Created association: $RESOURCE_ASSOC_ID"
    fi
fi  # End of VPCE domain check

# ============================================================================
# STEP 9: Share Service Network via RAM
# ============================================================================
log_info "Step 9: Sharing Service Network via RAM..."

log_info "Sharing to Workload Dev Account: $WORKLOAD_DEV_ACCOUNT"
log_info "Sharing to Workload Test Account: $WORKLOAD_TEST_ACCOUNT"

# Create RAM Resource Share
RAM_SHARE_ARN=$(aws ram create-resource-share \
    --name ${STACK_PREFIX}-lattice-share \
    --resource-arns $SERVICE_NETWORK_ARN \
    --principals $WORKLOAD_DEV_ACCOUNT $WORKLOAD_TEST_ACCOUNT \
    --allow-external-principals false \
    --region $REGION \
    --profile $PROFILE \
    --query 'resourceShare.resourceShareArn' --output text 2>/dev/null || \
    aws ram get-resource-shares \
    --resource-owner SELF \
    --name ${STACK_PREFIX}-lattice-share \
    --query 'resourceShares[0].resourceShareArn' --output text \
    --region $REGION --profile $PROFILE)

log_info "RAM Share ARN: $RAM_SHARE_ARN"

# ============================================================================
# Get Lattice Resource DNS
# ============================================================================
log_info "Getting Lattice Resource DNS..."

# Wait a moment for the association to be fully active
sleep 5

if [ -n "$RESOURCE_CONFIG_ID" ] && [ "$RESOURCE_CONFIG_ID" != "" ]; then
    LATTICE_RESOURCE_DNS=$(aws vpc-lattice list-service-network-resource-associations \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --query 'items[0].dnsEntry.domainName' --output text \
        --region $REGION --profile $PROFILE)
    
    log_info "Lattice Resource DNS: $LATTICE_RESOURCE_DNS"
else
    log_warn "No Resource Configuration - Lattice Resource DNS not available"
    LATTICE_RESOURCE_DNS=""
fi

# ============================================================================
# STEP 10: Create Route 53 Private Hosted Zone for friendly DNS
# ============================================================================
log_info "Step 10: Creating Route 53 Private Hosted Zone (proxy.internal)..."

# Only create PHZ if we have a Lattice Resource DNS
if [ -z "$LATTICE_RESOURCE_DNS" ] || [ "$LATTICE_RESOURCE_DNS" == "None" ]; then
    log_warn "⚠️  Skipping PHZ creation - no Lattice Resource DNS available"
    log_warn "PHZ will need to be created manually once Resource Configuration is set up"
    PHZ_ID=""
else
    # Check if PHZ already exists
    EXISTING_PHZ=$(aws route53 list-hosted-zones-by-name \
        --dns-name "proxy.internal" \
        --query "HostedZones[?Name=='proxy.internal.'].Id" \
        --output text --profile $PROFILE 2>/dev/null | head -1)

    if [ -n "$EXISTING_PHZ" ] && [ "$EXISTING_PHZ" != "None" ] && [ "$EXISTING_PHZ" != "" ]; then
        # Extract just the ID part (remove /hostedzone/ prefix)
        PHZ_ID=$(echo $EXISTING_PHZ | sed 's|/hostedzone/||')
        log_info "Using existing PHZ: $PHZ_ID"
    else
        # Create PHZ - must use a VPC from the same account (Egress VPC)
        PHZ_RESPONSE=$(aws route53 create-hosted-zone \
            --name "proxy.internal" \
            --vpc VPCRegion=$REGION,VPCId=$VPC_ID \
            --caller-reference "${STACK_PREFIX}-phz-$(date +%s)" \
            --hosted-zone-config PrivateZone=true \
            --profile $PROFILE 2>/dev/null)
        
        if [ $? -eq 0 ]; then
            PHZ_ID=$(echo $PHZ_RESPONSE | jq -r '.HostedZone.Id' | sed 's|/hostedzone/||')
            log_info "Created PHZ: $PHZ_ID"
        else
            log_error "Failed to create PHZ"
            PHZ_ID=""
        fi
    fi

if [ -n "$PHZ_ID" ] && [ "$PHZ_ID" != "None" ]; then
    # Get the Lattice Resource IP for the A record
    # We need to resolve the Lattice DNS to get the IP
    LATTICE_IP=$(dig +short $LATTICE_RESOURCE_DNS | head -1)
    
    if [ -n "$LATTICE_IP" ]; then
        log_info "Lattice Resource IP: $LATTICE_IP"
        
        # Create/Update A record for proxy.internal pointing to Lattice IP
        aws route53 change-resource-record-sets \
            --hosted-zone-id $PHZ_ID \
            --change-batch "{
                \"Changes\": [{
                    \"Action\": \"UPSERT\",
                    \"ResourceRecordSet\": {
                        \"Name\": \"proxy.internal\",
                        \"Type\": \"A\",
                        \"TTL\": 300,
                        \"ResourceRecords\": [{\"Value\": \"$LATTICE_IP\"}]
                    }
                }]
            }" \
            --profile $PROFILE > /dev/null 2>&1
        
        log_info "Created A record: proxy.internal -> $LATTICE_IP"
    else
        log_warn "Could not resolve Lattice DNS to IP. Creating CNAME instead..."
        # Fallback to CNAME for a subdomain
        aws route53 change-resource-record-sets \
            --hosted-zone-id $PHZ_ID \
            --change-batch "{
                \"Changes\": [{
                    \"Action\": \"UPSERT\",
                    \"ResourceRecordSet\": {
                        \"Name\": \"egress.proxy.internal\",
                        \"Type\": \"CNAME\",
                        \"TTL\": 300,
                        \"ResourceRecords\": [{\"Value\": \"$LATTICE_RESOURCE_DNS\"}]
                    }
                }]
            }" \
            --profile $PROFILE > /dev/null 2>&1
        
        log_info "Created CNAME record: egress.proxy.internal -> $LATTICE_RESOURCE_DNS"
    fi
    
    log_info "PHZ ID: $PHZ_ID"
    log_info "Friendly DNS: proxy.internal (or egress.proxy.internal)"
    
    # ============================================================================
    # STEP 11: Authorize Workload VPCs to associate with PHZ
    # ============================================================================
    log_info "Step 11: Authorizing Workload VPCs to associate with PHZ..."
    
    # Authorize Workload Dev VPC
    log_info "Authorizing Workload Dev VPC ($WORKLOAD_DEV_ACCOUNT)..."
    # We need to get the VPC ID from the workload account - but it doesn't exist yet
    # So we'll just create the authorization for any VPC from that account
    # The workload scripts will handle the actual association
    
    # Note: We can't pre-authorize specific VPCs because they don't exist yet
    # The workload scripts will need to handle authorization after VPC creation
    # OR we use a different approach - associate from networking account after workload VPC is created
    
    log_info "PHZ authorization will be handled by workload scripts after VPC creation"
else
    log_warn "Skipping PHZ creation - will use Lattice DNS directly"
fi  # End of inner PHZ_ID check
fi  # End of outer LATTICE_RESOURCE_DNS check

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "============================================================================"
echo "NETWORKING ACCOUNT SETUP COMPLETE"
echo "============================================================================"
echo ""
echo "Resources Created:"
echo "  - Egress VPC: $VPC_ID"
echo "  - NAT Gateway: $NAT_GW_ID"
echo "  - NFW Proxy: ${STACK_PREFIX}-proxy"
echo "  - Service Network: $SERVICE_NETWORK_ID"
echo "  - Resource Gateway: $RESOURCE_GATEWAY_ID"
if [ -n "$RESOURCE_CONFIG_ID" ]; then
echo "  - Resource Configuration: $RESOURCE_CONFIG_ID"
else
echo "  - Resource Configuration: NOT CREATED (VPCE not found)"
fi
echo "  - RAM Share: $RAM_SHARE_ARN"
if [ -n "$PHZ_ID" ]; then
echo "  - Private Hosted Zone: $PHZ_ID (proxy.internal)"
fi
echo ""

if [ -n "$LATTICE_RESOURCE_DNS" ] && [ "$LATTICE_RESOURCE_DNS" != "None" ]; then
    echo "============================================================================"
    echo "PROXY DNS OPTIONS"
    echo "============================================================================"
    echo ""
    if [ -n "$PHZ_ID" ]; then
    echo "  Option 1 (Friendly): proxy.internal:3128"
    echo "  Option 2 (Lattice):  $LATTICE_RESOURCE_DNS:3128"
    else
    echo "  Lattice DNS: $LATTICE_RESOURCE_DNS:3128"
    fi
    echo ""
    echo "============================================================================"
    echo "⚠️  IMPORTANT NOTES"
    echo "============================================================================"
    echo ""
    echo "  1. Workload VPCs must be associated with the PHZ to use proxy.internal"
    echo "  2. The Lattice DNS always works without PHZ association"
    if [ -n "$NFW_PROXY_VPCE_DOMAIN" ]; then
    echo "  3. DO NOT use the VPCE domain directly: $NFW_PROXY_VPCE_DOMAIN"
    echo "     (This resolves to 172.16.x.x which has no route from workload VPCs)"
    fi
    echo ""
else
    echo "============================================================================"
    echo "⚠️  INCOMPLETE SETUP - MANUAL STEPS REQUIRED"
    echo "============================================================================"
    echo ""
    echo "  The NFW Proxy VPCE was not found automatically."
    echo "  You need to manually:"
    echo ""
    echo "  1. Find the NFW Proxy VPCE in the AWS Console:"
    echo "     - Go to VPC > Endpoints"
    echo "     - Look for endpoint with service name containing 'proxy.nfw'"
    echo "     - Copy the DNS name (vpce-xxx...vpce.amazonaws.com)"
    echo ""
    echo "  2. Create Resource Configuration:"
    echo "     aws vpc-lattice create-resource-configuration \\"
    echo "         --name ${STACK_PREFIX}-proxy-resource \\"
    echo "         --type SINGLE \\"
    echo "         --resource-gateway-identifier $RESOURCE_GATEWAY_ID \\"
    echo "         --port-ranges 3128 \\"
    echo "         --protocol TCP \\"
    echo "         --resource-configuration-definition \"dnsResource={domainName=<VPCE_DNS>,ipAddressType=IPV4}\" \\"
    echo "         --region $REGION --profile $PROFILE"
    echo ""
    echo "  3. Associate with Service Network:"
    echo "     aws vpc-lattice create-service-network-resource-association \\"
    echo "         --service-network-identifier $SERVICE_NETWORK_ID \\"
    echo "         --resource-configuration-identifier <RESOURCE_CONFIG_ID> \\"
    echo "         --region $REGION --profile $PROFILE"
    echo ""
    echo "  4. Get the Lattice Resource DNS:"
    echo "     aws vpc-lattice list-service-network-resource-associations \\"
    echo "         --service-network-identifier $SERVICE_NETWORK_ID \\"
    echo "         --query 'items[0].dnsEntry.domainName' --output text \\"
    echo "         --region $REGION --profile $PROFILE"
    echo ""
fi

echo "Save these values for workload account scripts:"
echo "  SERVICE_NETWORK_ID=$SERVICE_NETWORK_ID"
if [ -n "$PHZ_ID" ]; then
echo "  PHZ_ID=$PHZ_ID"
fi
echo ""

# Save outputs to file
cat > /tmp/networking-outputs.env << ENVEOF
SERVICE_NETWORK_ID=$SERVICE_NETWORK_ID
SERVICE_NETWORK_ARN=$SERVICE_NETWORK_ARN
RESOURCE_GATEWAY_ID=$RESOURCE_GATEWAY_ID
RESOURCE_CONFIG_ID=$RESOURCE_CONFIG_ID
NFW_PROXY_VPCE_DOMAIN=$NFW_PROXY_VPCE_DOMAIN
LATTICE_RESOURCE_DNS=$LATTICE_RESOURCE_DNS
RAM_SHARE_ARN=$RAM_SHARE_ARN
WORKLOAD_DEV_ACCOUNT=$WORKLOAD_DEV_ACCOUNT
WORKLOAD_TEST_ACCOUNT=$WORKLOAD_TEST_ACCOUNT
PHZ_ID=$PHZ_ID
ENVEOF

log_info "Outputs saved to /tmp/networking-outputs.env"
