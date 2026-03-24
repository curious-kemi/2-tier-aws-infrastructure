# Terraform — Infrastructure Provisioning Notes
### 2-Tier AWS Project (VotingApp)

---

## Project Goal

Take source code (VotingApp on GitHub) and turn it into a running application that users can access — securely, consistently, and automatically.

The problem: the app lives on GitHub as raw code. Nobody can use it yet because it's not running anywhere. Terraform's job is to build all the infrastructure that makes it accessible.

---

## Architecture Overview

```
AZ-A:
  Public Subnet 1  → ALB
  Public Subnet 2  → NAT Gateway
  Private Subnet 1 → App (EC2)
  Private Subnet 2 → DB (RDS)

AZ-B:
  Public Subnet 3  → ALB
  Public Subnet 4  → NAT Gateway
  Private Subnet 3 → App (EC2)
  Private Subnet 4 → DB (RDS)
```

### Why 2 AZs?

A load balancer with only 1 instance behind it defeats the purpose — it won't provide high availability or fault tolerance. Deploying one EC2 per AZ ensures that if one AZ goes down, the other instance continues serving traffic.

---

## Module Design Principles

### Root module vs. child modules

- `terraform.tfvars` (or environment-specific files like `dev.tfvars`) live in the **root module**, not inside child modules
- CIDRs and availability zones belong in root `tfvars` so they can change per environment
- Child modules only define variables and use them for resources — they make no assumptions about the environment
- This makes modules **reusable and environment-agnostic**

### AZ selection belongs in the root module

Modules should be reusable across regions and accounts. The root module orchestrates the environment and decides which AZs to use. The VPC module simply consumes the AZs as input, without making its own assumptions.

### Modules are isolated

Terraform modules are isolated by design. A module cannot directly reference another module's resources — only its **outputs**. If two modules need the same value, each must declare a variable for it. The value itself still lives in one place (tfvars or CLI input). This is not duplication — it's clean API design.

```hcl
# Root module wires things together
module "vpc" { ... }

module "ec2" {
  subnet_ids = module.vpc.private_subnet_ids  # output from VPC module
}
```

**Rule:** `module.<name>.<something>` — the `something` is always an output, never a resource directly.

---

## Variables

### When to use `var.*` vs `module.*`

| Use | When |
|---|---|
| `var.*` | Values that must be decided by the environment (humans decide) |
| `module.*` | Values that already exist, produced by other modules (Terraform created them) |

Mixing both is not only fine — it's the correct design.

### Use `list(string)` for multiple resources

Whenever you have more than one of something (subnets, EC2 instances, security groups), declare the variable as `list(string)`. This makes the module scalable — you can add or remove items without changing any code.

### Variable precedence reminder

Terraform requires a value for every variable that does NOT have a default. If you don't provide one, the plan will fail.

---

## The `count` Meta-Argument

`count` makes modules dynamic and reusable. Without it, each subnet or AZ requires a separate resource block, making the module inflexible and hard to maintain.

```hcl
resource "aws_instance" "app" {
  count     = length(var.subnet_ids)
  subnet_id = var.subnet_ids[count.index]
}
```

- `count` — tells Terraform how many resources to create
- `count.index` — lets each resource pick the corresponding value from a list
- `[*]` (splat operator) — collects an attribute from all instances created with `count` and returns a list

**Important:** `count.index` only works inside a resource/module/data block that has `count` defined. Using it without `count` will throw an error.

---

## Networking

### Route Tables

Every subnet must be associated with a route table — even database subnets. A subnet has no idea where traffic should go unless a route table tells it. Without explicit association, AWS defaults to the VPC's main route table, which may be open to the internet.

| Subnet Type | Route destination |
|---|---|
| Public | Internet Gateway (IGW) |
| Private (App) | NAT Gateway |
| Private (DB) | No internet route needed |

### How many route tables do you need?

- **1 public route table** — shared across all public subnets. The IGW is regional and works across all AZs, so no duplication needed.
- **2 private route tables** — one per AZ. NAT Gateways are AZ-specific. Each private subnet must route to the NAT in its own AZ or traffic crosses AZ boundaries unnecessarily.

All private subnets in the same AZ (app and DB) can share the same private route table. You only need 2 private route tables total, not 4.

### Scope of key resources

| Resource | Scope | Why |
|---|---|---|
| Internet Gateway (IGW) | Regional | Serves all AZs — acts as a central door |
| NAT Gateway | AZ-specific | Must live in a public subnet in the same AZ it serves |
| Route Table | Subnet-bound | Determines whether the subnet uses IGW or NAT |

### Outbound traffic flow (private subnet → internet)

```
EC2 (Private Subnet)
        ↓
Private Subnet Route Table
        ↓
NAT Gateway (Public Subnet, same AZ)
        ↓
Public Subnet Route Table
        ↓
Internet Gateway (IGW)
        ↓
Internet
```

Private subnets are never directly attached to NAT Gateways. Their route tables contain a default route pointing to the NAT in the same AZ, which then forwards traffic through the IGW.

### NAT Gateway setup (3 steps)

1. Create an Elastic IP
2. Create the NAT Gateway and attach the Elastic IP via `allocation_id`
3. Add a route in the private route table pointing outbound traffic (`0.0.0.0/0`) to the NAT Gateway

The NAT Gateway must be placed in a **public subnet** because it needs a path to the IGW.

### ALB vs. NAT — separate subnets

The ALB and NAT Gateway should live in separate public subnets. They serve different purposes and should not depend on each other.

**Cost note:** Using 2 NAT Gateways (one per AZ) eliminates a single point of failure but doubles NAT cost. For dev environments, 1 NAT Gateway is acceptable.

---

## Security Groups

### Security group references vs. CIDR ranges

Using a security group reference as the source is more secure than using a CIDR range.

- **CIDR approach:** Anyone in that subnet can talk to RDS
- **Security group approach:** Only EC2 instances in a specific SG can reach RDS

This is called **least privilege** — the AWS best practice. If you reference the EC2 security group as the source in the RDS security group rule, only those EC2s can connect. Nothing else in the subnet can.

### Security group rules vs. the security group itself

EC2 instances attach to a **security group**, not to individual rules. Rules are automatically applied because they are attached to the SG. When passing `vpc_security_group_ids` to an EC2 module, you only pass the SG ID — not the rules.

---

## RDS

### DB Subnet Group

RDS does not take a single subnet like EC2 does. It requires a **DB Subnet Group** — a list of subnets in different AZs — so AWS can support high availability and failover. The subnet group is just a list of subnet IDs, so Terraform can't create it until the subnets exist.

```hcl
resource "aws_db_subnet_group" "main" {
  name       = "main-db-subnet-group"
  subnet_ids = var.db_subnet_ids  # list of subnets across AZs
}
```

### RDS configuration used

- `db.t3.micro` — low-cost tier, suitable for dev/test (not enterprise workloads)
- 20 GB of allocated storage
- Multi-AZ can be enabled on the instance directly for high availability

### KMS encryption

By default, Secrets Manager encrypts secrets with an AWS-managed key. For enterprise environments, use a **Customer Managed Key (CMK)** so you have full control over access and meet compliance requirements (PCI-DSS, HIPAA, SOC2, FedRAMP).

**Important:** You cannot change the KMS key after DB creation. If you need to change it, you must restore from a snapshot or recreate the database.

---

## Secrets Manager

### Why store credentials as JSON

A single secret can hold multiple fields (host, username, password, port, database name). JSON bundles all related credentials into one secret. If you store a plain string, tools like Ansible that call `from_json` will fail — there is nothing to parse.

```json
{
  "username": "admin",
  "password": "secret123",
  "host": "mydb.rds.amazonaws.com",
  "port": "3306",
  "dbname": "votingapp"
}
```

### Generating passwords with Terraform

Use `random_password` to generate a strong password and store it in Secrets Manager. This ensures the password is never hardcoded, supports automatic rotation, and allows applications to retrieve it dynamically at runtime.

**Never hardcode passwords or secrets in Terraform.** They will appear in plaintext in the state file.

### `aws_secretsmanager_secret` vs `aws_secretsmanager_secret_version`

- `aws_secretsmanager_secret` — the container (name, KMS key, rotation config)
- `aws_secretsmanager_secret_version` — the actual value stored inside it. This changes every time the password rotates.

### Use `.arn` vs `.id`

| Use | When |
|---|---|
| `.id` | Referencing the secret internally within Terraform (e.g., creating a secret version) |
| `.arn` | IAM policies and anywhere a full AWS resource ARN is required |

AWS APIs expect the KMS key ARN or secret ARN, not the name.

### Common error — secret scheduled for deletion

```
InvalidRequestException: You can't create this secret because a secret with
this name is already scheduled for deletion.
```

AWS holds deleted secrets for a recovery window (default 30 days) before permanently deleting them. If you destroyed and re-applied, the secret name is still reserved. Either use a different name or force-delete the secret in the AWS console before re-creating.

---

## EC2 and IAM

### Launch Template + Auto Scaling Group

**Don't use separate `aws_instance` blocks for multiple EC2s.** The problems:

- Requires duplicate resource blocks (harder to maintain)
- If an instance dies, Terraform doesn't automatically replace it
- Adding/removing instances is tedious

Use a **Launch Template** to define the instance configuration once (like a recipe), and an **Auto Scaling Group** to ensure the right number of instances are always running and automatically replaced on failure.

Launch Templates do NOT create instances by themselves — they define the blueprint. The ASG uses the template to launch and maintain instances.

**Benefit:** If you need to update the AMI, you update the Launch Template. The old instances keep running until you choose to replace them. Without a Launch Template, you'd have to destroy and recreate instances.

### Never hardcode AMIs in modules

Always use a `data` source to look up the latest AMI. Hardcoded AMI IDs are region-specific and go stale.

```hcl
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}
```

### IAM Role for EC2

EC2 cannot directly assume an IAM role. It requires an **instance profile** as a bridge.

**Steps to create an IAM role for EC2:**

1. Create the IAM role with a **trust policy** — declares that EC2 is allowed to assume this role
2. Attach a **permission policy** — declares what the role can actually do (e.g., read from Secrets Manager)
3. Create an **instance profile** and attach the role to it
4. Attach the instance profile to the EC2 instance (`iam_instance_profile`)

| Policy type | Purpose |
|---|---|
| Trust policy | Who can assume the role (EC2 in this case) |
| Permission policy | What the role is allowed to do and on which resources |

Without a permission policy, a role can exist and EC2 can assume it, but it cannot access anything.

### Network Interface

For a standard private EC2, you do not manually create a network interface. AWS automatically creates and attaches an ENI when the instance is launched.

---

## Load Balancer

### Setup order

1. Create the Application Load Balancer
2. Create the Target Group
3. Attach EC2 instances to the Target Group using `aws_lb_target_group_attachment`
4. Create the Listener — forwards incoming traffic to the Target Group

### Target Group vs. DB Subnet Group

| Resource | Purpose |
|---|---|
| Target Group | List of servers (EC2/IP/Lambda) the ALB sends traffic to |
| DB Subnet Group | List of subnets where RDS places database instances for Multi-AZ |

Both organize resources, but one is for routing traffic and the other is for database placement.

### Health checks

The load balancer continuously monitors EC2 instances. If an instance fails a health check, the ALB stops sending traffic to it.

---

## Terraform Remote State

Terraform remote state stores the state file centrally to enable team collaboration, state locking, and recovery. Typically stored in an S3 bucket with DynamoDB for locking.

Remote state is about **infrastructure metadata**. Secrets Manager is about **sensitive data**. They solve different problems.

---

## Data Sources

A Terraform `data` source lets you read existing infrastructure without managing or changing it. This is critical in shared environments where resources already exist.

```hcl
data "aws_secretsmanager_secret_version" "db_creds" {
  secret_id = var.secret_arn
}
```

Use `.secret_string` when you need the actual secret value.

---

## Key Lessons Learned

- The `*` splat operator collects an attribute from all resources created with `count` and returns a list — useful for feeding subnet IDs into a DB Subnet Group
- `subnets = var.alb_subnet_ids` on an ALB handles all subnets automatically — no `count.index` needed
- Route tables do not know about AZs. Subnets do. You create route table associations for subnets, and those route tables point to the right NAT or IGW
- You can reuse the same private route table for both app and DB subnets in the same AZ — no need for a separate one per tier
- The VS Code light brown color on a file means it has been changed but not yet committed to Git

---

## Incremental Deployment Strategy

You don't have to deploy everything at once. Test each layer before adding the next:

1. Deploy VPC + subnets + IGW + route tables → verify structure
2. Deploy NAT Gateway → verify private subnets can reach internet
3. Deploy RDS in private DB subnet → verify DB is reachable from app subnet
4. Deploy EC2 in private subnet → verify app can connect to DB
5. Deploy ALB → verify traffic flows from internet to app

---

## Quick Reference — Terraform Commands

| Command | Purpose |
|---|---|
| `terraform fmt` | Formats and prettifies Terraform code |
| `terraform init` | Initializes the working directory and downloads providers |
| `terraform plan` | Shows what changes will be made before applying |
| `terraform apply` | Provisions or updates infrastructure |
| `terraform destroy` | Tears down all managed infrastructure |