# NFW Proxy + VPC Lattice Resource Configuration Test

## Overview

This test environment validates centralized egress with overlapping CIDRs using:
- AWS Network Firewall Proxy (Preview)
- VPC Lattice Resource Configuration
- Cross-account access via RAM-shared Service Network

## Quick Start

```bash
# Deploy all resources
./deploy.sh \
    --networking-profile <YOUR_NETWORKING_PROFILE> \
    --workload-dev-profile <YOUR_DEV_PROFILE> \
    --workload-test-profile <YOUR_TEST_PROFILE> \
    all

# Check status
./deploy.sh \
    --networking-profile <YOUR_NETWORKING_PROFILE> \
    --workload-dev-profile <YOUR_DEV_PROFILE> \
    --workload-test-profile <YOUR_TEST_PROFILE> \
    status

# Cleanup
./deploy.sh \
    --networking-profile <YOUR_NETWORKING_PROFILE> \
    --workload-dev-profile <YOUR_DEV_PROFILE> \
    --workload-test-profile <YOUR_TEST_PROFILE> \
    cleanup
```

## Prerequisites

- AWS CLI v2 with NFW Proxy support
- Three AWS accounts with configured CLI profiles
- Appropriate IAM permissions in each account

## Commands

| Command | Description |
|---------|-------------|
| `all` | Deploy all resources (networking + both workloads) |
| `networking` | Deploy networking account only |
| `workload-dev` | Deploy workload dev account only |
| `workload-test` | Deploy workload test account only |
| `cleanup` | Delete all resources |
| `status` | Show deployment status |

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `--networking-profile` | AWS CLI profile for networking account | Required |
| `--workload-dev-profile` | AWS CLI profile for workload dev account | Required |
| `--workload-test-profile` | AWS CLI profile for workload test account | Required |
| `--region` | AWS region | us-east-2 |
| `--prefix` | Stack prefix for resource naming | egress-proxy |

## Architecture

```
Workload Dev VPC (10.0.0.0/16)     Workload Test VPC (10.0.0.0/16)
         │                                  │
         └──────────────┬───────────────────┘
                        │
                        ▼
         VPC Lattice Service Network (RAM shared)
         DNS: snra-xxx.rcfg-xxx.vpc-lattice-rsc.us-east-2.on.aws
                        │
                        ▼
         Resource Gateway (172.16.x.x)
                        │
                        ▼
         NFW Proxy VPCE (172.16.x.x)
                        │
                        ▼
         NFW Proxy → NAT Gateway → Internet
```

## Scripts

| Script | Purpose |
|--------|---------|
| `deploy.sh` | Main entry point - handles all deployments |
| `01-networking-account.sh` | Creates Egress VPC, NFW Proxy, Lattice resources, PHZ |
| `02-workload-dev.sh` | Creates Dev workload VPC (10.0.0.0/16) |
| `03-workload-test.sh` | Creates Test workload VPC (10.0.0.0/16 - same CIDR!) |
| `cleanup.sh` | Deletes all test resources |

### What Gets Created

**Networking Account:**
- Egress VPC (172.16.0.0/16) with public/private subnets
- NAT Gateway and Internet Gateway
- NFW Proxy Rule Group (FQDN allowlist)
- NFW Proxy Configuration
- NFW Proxy attached to NAT Gateway
- VPC Lattice Service Network
- Resource Gateway
- Resource Configuration pointing to NFW Proxy VPCE
- RAM Share to workload accounts
- Route 53 Private Hosted Zone (`proxy.internal`)

**Workload Accounts:**
- Workload VPC (10.0.0.0/16 - overlapping CIDR)
- Private subnet with test instance
- SSM VPC endpoints for Session Manager access
- VPC Lattice Service Network association
- PHZ association (cross-account)

## Testing

After deployment, connect to a test instance via SSM:

```bash
# Get instance ID from deployment output, then:
aws ssm start-session --target <INSTANCE_ID> --profile <YOUR_DEV_PROFILE> --region us-east-2

# Test with friendly DNS (recommended)
curl -I --proxy http://proxy.internal:3128 https://docs.aws.amazon.com

# Test blocked domain (should return 403)
curl -I --proxy http://proxy.internal:3128 https://google.com
```

## Important: Use Lattice DNS, Not VPCE Domain

```bash
# CORRECT - Friendly DNS
curl --proxy http://proxy.internal:3128 https://docs.aws.amazon.com

# CORRECT - Lattice Resource DNS
curl --proxy http://snra-xxx.rcfg-xxx.vpc-lattice-rsc.us-east-2.on.aws:3128 https://docs.aws.amazon.com

# WRONG - Direct VPCE domain (no route from workload VPC)
curl --proxy http://vpce-xxx.proxy.nfw.us-east-2.vpce.amazonaws.com:3128 https://example.com
```

## Expected Results

| Test | Expected Result |
|------|-----------------|
| `nslookup proxy.internal` | Lattice IP (129.224.x.x) |
| `docs.aws.amazon.com` | 200 Connection Established |
| `google.com` | 403 Forbidden (FQDN filtering) |

## Troubleshooting

### proxy.internal returns NXDOMAIN
The workload VPC is not associated with the Private Hosted Zone. Check PHZ associations or use the Lattice DNS directly.

### DNS resolves to 172.16.x.x
You're using the VPCE domain directly. Use the Lattice Resource DNS instead.

### HTTP CONNECT returns 404
You're using VPC Lattice Services (L7) instead of Resource Configuration (L4).

### Connection timeout
1. Check VPC association is ACTIVE
2. Check security groups allow port 3128
3. Verify Resource Gateway is ACTIVE
