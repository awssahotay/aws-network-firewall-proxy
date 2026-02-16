#!/bin/bash
# NFW Proxy + VPC Lattice - Workload Dev Account Setup
# 
# This script creates:
# - Client VPC (10.0.0.0/16) - overlapping CIDR
# - Private subnet with test instance
# - VPC Lattice Service Network association
# - Test instance to validate proxy connectivity
#
# Run via deploy.sh or set environment variables:
#   EGRESS_WORKLOAD_DEV_PROFILE
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
PROFILE="${EGRESS_WORKLOAD_DEV_PROFILE:-}"
REGION="${EGRESS_REGION:-us-east-2}"
STACK_PREFIX="${EGRESS_STACK_PREFIX:-egress-proxy}"

# Validate required parameters
if [[ -z "$PROFILE" ]]; then
    log_error "EGRESS_WORKLOAD_DEV_PROFILE not set. Run via deploy.sh or set environment variable."
    exit 1
fi

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE --query 'Account' --output text)
log_info "Workload Dev Account ID: $ACCOUNT_ID"
log_info "Region: $REGION"
log_info "Stack Prefix: $STACK_PREFIX"

# Load networking outputs if available
if [ -f /tmp/networking-outputs.env ]; then
    source /tmp/networking-outputs.env
    log_info "Loaded networking outputs from previous script"
else
    log_error "No networking outputs found at /tmp/networking-outputs.env"
    log_error "Run 01-networking-account.sh first or run via deploy.sh"
    exit 1
fi

log_info "Service Network ID: $SERVICE_NETWORK_ID"

# ============================================================================
# STEP 1: Create Client VPC with CloudFormation
# ============================================================================
log_info "Step 1: Creating Client VPC..."

cat > /tmp/workload-vpc.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: NFW Proxy Test - Workload VPC (Overlapping CIDR)

Parameters:
  StackPrefix:
    Type: String
    Default: nfw-proxy-test
  Environment:
    Type: String
    Default: dev

Resources:
  # VPC with overlapping CIDR
  WorkloadVPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.0.0.0/16
      EnableDnsHostnames: true
      EnableDnsSupport: true
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-workload-vpc-${Environment}'

  # Private Subnet
  PrivateSubnet:
    Type: AWS::EC2::Subnet
    Properties:
      VpcId: !Ref WorkloadVPC
      CidrBlock: 10.0.1.0/24
      AvailabilityZone: !Select [0, !GetAZs '']
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-private-subnet-${Environment}'

  # Private Route Table (no internet route - uses Lattice for egress)
  PrivateRouteTable:
    Type: AWS::EC2::RouteTable
    Properties:
      VpcId: !Ref WorkloadVPC
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-private-rt-${Environment}'

  PrivateSubnetRTAssoc:
    Type: AWS::EC2::SubnetRouteTableAssociation
    Properties:
      SubnetId: !Ref PrivateSubnet
      RouteTableId: !Ref PrivateRouteTable

  # Security Group for test instance
  TestInstanceSG:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for test instance
      VpcId: !Ref WorkloadVPC
      SecurityGroupEgress:
        - IpProtocol: -1
          CidrIp: 0.0.0.0/0
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-test-sg-${Environment}'

  # SSM VPC Endpoints for Session Manager access
  SSMEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref WorkloadVPC
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssm'
      VpcEndpointType: Interface
      SubnetIds:
        - !Ref PrivateSubnet
      SecurityGroupIds:
        - !Ref VPCEndpointSG
      PrivateDnsEnabled: true

  SSMMessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref WorkloadVPC
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ssmmessages'
      VpcEndpointType: Interface
      SubnetIds:
        - !Ref PrivateSubnet
      SecurityGroupIds:
        - !Ref VPCEndpointSG
      PrivateDnsEnabled: true

  EC2MessagesEndpoint:
    Type: AWS::EC2::VPCEndpoint
    Properties:
      VpcId: !Ref WorkloadVPC
      ServiceName: !Sub 'com.amazonaws.${AWS::Region}.ec2messages'
      VpcEndpointType: Interface
      SubnetIds:
        - !Ref PrivateSubnet
      SecurityGroupIds:
        - !Ref VPCEndpointSG
      PrivateDnsEnabled: true

  VPCEndpointSG:
    Type: AWS::EC2::SecurityGroup
    Properties:
      GroupDescription: Security group for VPC endpoints
      VpcId: !Ref WorkloadVPC
      SecurityGroupIngress:
        - IpProtocol: tcp
          FromPort: 443
          ToPort: 443
          CidrIp: 10.0.0.0/16
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-vpce-sg-${Environment}'

  # IAM Role for test instance
  TestInstanceRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '${StackPrefix}-test-role-${Environment}'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: ec2.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

  TestInstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      InstanceProfileName: !Sub '${StackPrefix}-test-profile-${Environment}'
      Roles:
        - !Ref TestInstanceRole

  # Test EC2 Instance
  TestInstance:
    Type: AWS::EC2::Instance
    Properties:
      ImageId: !Sub '{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}'
      InstanceType: t3.micro
      SubnetId: !Ref PrivateSubnet
      SecurityGroupIds:
        - !Ref TestInstanceSG
      IamInstanceProfile: !Ref TestInstanceProfile
      Tags:
        - Key: Name
          Value: !Sub '${StackPrefix}-test-instance-${Environment}'

Outputs:
  VpcId:
    Value: !Ref WorkloadVPC
    Export:
      Name: !Sub '${StackPrefix}-workload-vpc-id-${Environment}'
  
  PrivateSubnetId:
    Value: !Ref PrivateSubnet
    Export:
      Name: !Sub '${StackPrefix}-private-subnet-id-${Environment}'
  
  TestInstanceId:
    Value: !Ref TestInstance
    Export:
      Name: !Sub '${StackPrefix}-test-instance-id-${Environment}'
  
  TestInstanceSGId:
    Value: !Ref TestInstanceSG
    Export:
      Name: !Sub '${StackPrefix}-test-sg-id-${Environment}'
EOF

aws cloudformation deploy \
    --template-file /tmp/workload-vpc.yaml \
    --stack-name ${STACK_PREFIX}-workload-vpc-dev \
    --parameter-overrides StackPrefix=${STACK_PREFIX} Environment=dev \
    --capabilities CAPABILITY_NAMED_IAM \
    --region $REGION \
    --profile $PROFILE

log_info "Workload VPC created successfully"

# Get outputs
VPC_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-workload-vpc-dev \
    --query 'Stacks[0].Outputs[?OutputKey==`VpcId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
PRIVATE_SUBNET_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-workload-vpc-dev \
    --query 'Stacks[0].Outputs[?OutputKey==`PrivateSubnetId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
TEST_INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-workload-vpc-dev \
    --query 'Stacks[0].Outputs[?OutputKey==`TestInstanceId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)
TEST_SG_ID=$(aws cloudformation describe-stacks --stack-name ${STACK_PREFIX}-workload-vpc-dev \
    --query 'Stacks[0].Outputs[?OutputKey==`TestInstanceSGId`].OutputValue' --output text \
    --region $REGION --profile $PROFILE)

log_info "VPC ID: $VPC_ID"
log_info "Private Subnet: $PRIVATE_SUBNET_ID"
log_info "Test Instance: $TEST_INSTANCE_ID"

# ============================================================================
# STEP 2: Associate VPC with Service Network
# ============================================================================
log_info "Step 2: Associating VPC with Service Network..."

# Check if association already exists
EXISTING_ASSOC=$(aws vpc-lattice list-service-network-vpc-associations \
    --service-network-identifier $SERVICE_NETWORK_ID \
    --query "items[?vpcId=='${VPC_ID}'].id" \
    --output text --region $REGION --profile $PROFILE 2>/dev/null || echo "")

if [ -n "$EXISTING_ASSOC" ] && [ "$EXISTING_ASSOC" != "None" ]; then
    VPC_ASSOC_ID=$EXISTING_ASSOC
    log_info "Using existing VPC association: $VPC_ASSOC_ID"
else
    # Create security group for Lattice
    LATTICE_SG_ID=$(aws ec2 create-security-group \
        --group-name ${STACK_PREFIX}-lattice-sg-dev \
        --description "Security group for VPC Lattice" \
        --vpc-id $VPC_ID \
        --region $REGION \
        --profile $PROFILE \
        --query 'GroupId' --output text 2>/dev/null || \
        aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${STACK_PREFIX}-lattice-sg-dev" "Name=vpc-id,Values=${VPC_ID}" \
        --query 'SecurityGroups[0].GroupId' --output text \
        --region $REGION --profile $PROFILE)
    
    # Allow all outbound
    aws ec2 authorize-security-group-egress \
        --group-id $LATTICE_SG_ID \
        --protocol -1 \
        --cidr 0.0.0.0/0 \
        --region $REGION \
        --profile $PROFILE 2>/dev/null || true
    
    # Allow inbound from VPC CIDR
    aws ec2 authorize-security-group-ingress \
        --group-id $LATTICE_SG_ID \
        --protocol tcp \
        --port 3128 \
        --cidr 10.0.0.0/16 \
        --region $REGION \
        --profile $PROFILE 2>/dev/null || true

    VPC_ASSOC_ID=$(aws vpc-lattice create-service-network-vpc-association \
        --service-network-identifier $SERVICE_NETWORK_ID \
        --vpc-identifier $VPC_ID \
        --security-group-ids $LATTICE_SG_ID \
        --region $REGION \
        --profile $PROFILE \
        --query 'id' --output text)
    log_info "Created VPC association: $VPC_ASSOC_ID"
fi

# Wait for association to be active
log_info "Waiting for VPC association to become active..."
while true; do
    STATUS=$(aws vpc-lattice get-service-network-vpc-association \
        --service-network-vpc-association-identifier $VPC_ASSOC_ID \
        --query 'status' --output text \
        --region $REGION --profile $PROFILE)
    if [ "$STATUS" == "ACTIVE" ]; then
        log_info "VPC association is ACTIVE"
        break
    fi
    log_info "VPC association status: $STATUS - waiting..."
    sleep 10
done

# ============================================================================
# STEP 3: Associate VPC with Private Hosted Zone (for proxy.internal)
# ============================================================================
log_info "Step 3: Associating VPC with Private Hosted Zone..."

if [ -n "$PHZ_ID" ] && [ "$PHZ_ID" != "None" ] && [ "$PHZ_ID" != "" ]; then
    # Check if already associated
    EXISTING_PHZ_ASSOC=$(aws route53 list-hosted-zones-by-vpc \
        --vpc-id $VPC_ID \
        --vpc-region $REGION \
        --query "HostedZoneSummaries[?HostedZoneId=='/hostedzone/${PHZ_ID}'].HostedZoneId" \
        --output text --profile $PROFILE 2>/dev/null || echo "")
    
    if [ -n "$EXISTING_PHZ_ASSOC" ] && [ "$EXISTING_PHZ_ASSOC" != "None" ]; then
        log_info "VPC already associated with PHZ"
    else
        log_info "Associating VPC with PHZ $PHZ_ID..."
        
        # For cross-account PHZ association, we need to:
        # 1. Authorize from networking account (using networking profile)
        # 2. Associate from this account (using workload profile)
        
        # Step 3a: Authorize from networking account
        log_info "Authorizing VPC association from networking account..."
        
        # Get networking profile from the outputs file
        NETWORKING_PROFILE="Networking"  # Default, should match networking script
        
        aws route53 create-vpc-association-authorization \
            --hosted-zone-id $PHZ_ID \
            --vpc VPCRegion=$REGION,VPCId=$VPC_ID \
            --profile $NETWORKING_PROFILE 2>/dev/null && \
            log_info "Authorization created" || \
            log_info "Authorization may already exist"
        
        # Step 3b: Associate from this account
        log_info "Associating VPC with PHZ..."
        aws route53 associate-vpc-with-hosted-zone \
            --hosted-zone-id $PHZ_ID \
            --vpc VPCRegion=$REGION,VPCId=$VPC_ID \
            --profile $PROFILE 2>/dev/null && \
            log_info "VPC associated with PHZ successfully" || \
            log_warn "Could not associate VPC with PHZ - may need manual authorization"
    fi
else
    log_info "No PHZ configured - skipping PHZ association"
    log_info "Use the Lattice Resource DNS directly for proxy access"
fi

# ============================================================================
# STEP 4: Create Test Script
# ============================================================================
log_info "Step 4: Creating test script..."

cat > /tmp/test-proxy.sh << TESTEOF
#!/bin/bash
# Test NFW Proxy connectivity via VPC Lattice

PROXY_DOMAIN="${NFW_PROXY_VPCE_DOMAIN}"
PROXY_PORT="3128"

echo "============================================"
echo "NFW Proxy Test - Workload Dev Account"
echo "============================================"
echo ""
echo "Proxy Domain: \$PROXY_DOMAIN"
echo "Proxy Port: \$PROXY_PORT"
echo ""

# Test 1: DNS Resolution
echo "Test 1: DNS Resolution"
echo "----------------------"
nslookup \$PROXY_DOMAIN || echo "DNS resolution failed"
echo ""

# Test 2: TCP Connectivity
echo "Test 2: TCP Connectivity to proxy"
echo "---------------------------------"
timeout 5 bash -c "echo > /dev/tcp/\$PROXY_DOMAIN/\$PROXY_PORT" 2>/dev/null && echo "TCP connection successful" || echo "TCP connection failed"
echo ""

# Test 3: HTTP CONNECT via proxy
echo "Test 3: HTTP CONNECT (HTTPS proxy test)"
echo "----------------------------------------"
curl -v --proxy http://\$PROXY_DOMAIN:\$PROXY_PORT --connect-timeout 10 https://aws.amazon.com -o /dev/null 2>&1 | head -30
echo ""

# Test 4: HTTP GET via proxy
echo "Test 4: HTTP GET via proxy"
echo "--------------------------"
curl -v --proxy http://\$PROXY_DOMAIN:\$PROXY_PORT --connect-timeout 10 http://example.com -o /dev/null 2>&1 | head -20
echo ""

echo "============================================"
echo "Tests Complete"
echo "============================================"
TESTEOF

log_info "Test script created at /tmp/test-proxy.sh"

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo "============================================================================"
echo "WORKLOAD DEV ACCOUNT SETUP COMPLETE"
echo "============================================================================"
echo ""
echo "Resources Created:"
echo "  - Workload VPC: $VPC_ID (CIDR: 10.0.0.0/16)"
echo "  - Private Subnet: $PRIVATE_SUBNET_ID"
echo "  - Test Instance: $TEST_INSTANCE_ID"
echo "  - VPC Association: $VPC_ASSOC_ID"
echo ""
echo "============================================================================"
echo " IMPORTANT: Get the Lattice Resource DNS before testing!"
echo "============================================================================"
echo ""
echo "Run this command to get the Lattice Resource DNS:"
echo ""
echo "  aws vpc-lattice list-service-network-resource-associations \\"
echo "      --service-network-identifier $SERVICE_NETWORK_ID \\"
echo "      --query 'items[0].dnsEntry.domainName' --output text \\"
echo "      --region $REGION --profile <NETWORKING_PROFILE>"
echo ""
echo "Then connect to the test instance via SSM:"
echo ""
echo "  aws ssm start-session --target $TEST_INSTANCE_ID --profile $PROFILE --region $REGION"
echo ""
echo "And run the test commands using the LATTICE DNS (not VPCE domain):"
echo ""
echo "  # Test DNS resolution (should return 129.224.x.x or 169.254.x.x)"
echo "  nslookup <LATTICE_RESOURCE_DNS>"
echo ""
echo "  # Test HTTP CONNECT"
echo "  curl -I --proxy http://<LATTICE_RESOURCE_DNS>:3128 https://docs.aws.amazon.com"
echo ""
echo "  # Test blocked domain (should return 403)"
echo "  curl -I --proxy http://<LATTICE_RESOURCE_DNS>:3128 https://google.com"
echo ""

# Save outputs
cat > /tmp/workload-dev-outputs.env << ENVEOF
VPC_ID=$VPC_ID
PRIVATE_SUBNET_ID=$PRIVATE_SUBNET_ID
TEST_INSTANCE_ID=$TEST_INSTANCE_ID
VPC_ASSOC_ID=$VPC_ASSOC_ID
ENVEOF

log_info "Outputs saved to /tmp/workload-dev-outputs.env"
