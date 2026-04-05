# Troubleshooting Log & Build Notes — Terraform
### 2-Tier AWS Infrastructure (VotingApp)

Real issues encountered while building the Terraform infrastructure — errors, design decisions that required working through, and concepts that weren't obvious until they broke something. Documented so the next person doesn't have to figure these out from scratch.

---

## Issue 1: `CreateSecret` Failed — Secret Already Scheduled for Deletion

**What happened:**
```
Error: creating Secrets Manager Secret (rds_credentials): InvalidRequestException:
You can't create this secret because a secret with this name is already
scheduled for deletion.
```

**What caused it:**
AWS Secrets Manager has a minimum recovery window of 7 days when you delete a secret. If you run `terraform destroy` and then `terraform apply` again with the same secret name, AWS rejects the creation because the old secret is still in a "pending deletion" state — it hasn't actually been deleted yet. From Terraform's perspective, the secret doesn't exist. From AWS's perspective, it does.

**The fix:**
Two options:

Option A — Wait for the recovery window to pass (7 days minimum). Not practical during active development.

Option B — Force immediate deletion via the AWS CLI:
```bash
aws secretsmanager delete-secret \
  --secret-id rds_credentials \
  --force-delete-without-recovery
```

Then run `terraform apply` again.

Option C — Add `recovery_window_in_days = 0` to the secret resource so Terraform destroys it immediately on `terraform destroy`:
```hcl
resource "aws_secretsmanager_secret" "database_cred" {
  name                    = "rds_credentials"
  recovery_window_in_days = 0
}
```

**What I learned:**
Secrets Manager's recovery window exists to prevent accidental permanent deletion. But during development when you're frequently destroying and recreating infrastructure, it blocks `terraform apply`. Setting `recovery_window_in_days = 0` in the resource is fine for dev — in production you'd want to keep the recovery window as a safety net.

---

## Issue 2: Secret Stored as Plain String — Ansible `from_json` Fails

**What happened:**
The Terraform secret was configured with a plain password string as the `secret_string` value. Ansible fetched the secret, ran `| from_json` on it, and failed because there was no JSON to parse.

**What caused it:**
Secrets Manager can store any string. If you store a plain password like `"MyPassword123"`, Ansible receives exactly that string. `| from_json` expects a JSON object with named fields. A plain string has no fields — so `db_creds.host`, `db_creds.username`, and `db_creds.password` all came back empty. The application started but couldn't connect to the database.

**The fix:**
Changed the secret to store a JSON object using `jsonencode`:

```hcl
resource "aws_secretsmanager_secret_version" "database_cred_version" {
  secret_id = aws_secretsmanager_secret.database_cred.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.rds_instance.address
    port     = 3306
    dbname   = var.db_name
  })
}
```

`aws_db_instance.rds_instance.address` retrieves the RDS endpoint automatically after Terraform creates the database — no hardcoding needed.

**What I learned:**
The field names in the JSON object must exactly match the field names in the Ansible Jinja2 template. If the secret has `username` but the template references `db_creds.user`, the template renders blank silently with no error. Define the JSON structure in Terraform first, then write the template to match it.

---

## Issue 3: Used a Single Subnet for RDS — Should Be a DB Subnet Group

**What happened:**
The initial RDS configuration pointed to a single private subnet directly. Terraform threw an error — RDS doesn't accept a single subnet ID the way EC2 does.

**What caused it:**
RDS requires a DB Subnet Group, which is a named collection of subnets across multiple AZs. AWS needs this to support high availability and Multi-AZ failover. If one AZ goes down, RDS can fail over to a subnet in another AZ. A single subnet can't provide that.

**The fix:**
Created a DB Subnet Group resource and referenced it in the RDS instance:

```hcl
resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "rds-subnet-group"
  subnet_ids = var.db_subnet_ids  # list of subnets across multiple AZs
}

resource "aws_db_instance" "rds_instance" {
  db_subnet_group_name = aws_db_subnet_group.rds_subnet_group.name
  # ...
}
```

The DB Subnet Group can't be created until the subnets exist — Terraform handles this dependency automatically when you reference `var.db_subnet_ids` from the VPC module output.

**What I learned:**
RDS and EC2 handle subnet assignment differently. EC2 takes a single `subnet_id`. RDS takes a `db_subnet_group_name` that points to a group of subnets. The subnet group is what enables Multi-AZ — without it, you can't use high availability on the database.

---

## Issue 4: `count.index` Used Without Defining `count`

**What happened:**
Terraform threw an error referencing `count.index` inside a resource that didn't have a `count` argument defined.

**What caused it:**
`count.index` is only available inside a resource, module, or data block that has `count` set. It gives you the current iteration number (0, 1, 2...) so you can pick the corresponding item from a list. Without `count`, Terraform doesn't know what iteration you're on — `count.index` is undefined.

**The fix:**
Always pair `count.index` with a `count` argument:

```hcl
resource "aws_instance" "app" {
  count     = length(var.subnet_ids)   # defines how many to create
  subnet_id = var.subnet_ids[count.index]  # picks the right subnet for each
}
```

**What I learned:**
`count` tells Terraform how many copies to create. `count.index` lets each copy pick the corresponding item from a list. You can't use one without the other. `length(var.subnet_ids)` is a clean way to tie the count to the number of subnets so the module scales automatically — add a subnet, get another instance, without changing any code.

---

## Issue 5: Didn't Know Two Separate Private Route Tables Were Needed for Multi-AZ

**What happened:**
I initially created one private route table and associated all private subnets with it. Instances in private subnets in AZ-B couldn't reach the internet even though a NAT Gateway existed.

**What caused it:**
NAT Gateways are AZ-specific. A NAT Gateway in AZ-A can only reliably serve traffic from subnets in AZ-A. If a private subnet in AZ-B has a route pointing to the NAT Gateway in AZ-A, traffic crosses AZs — which adds latency, costs cross-AZ data transfer fees, and breaks if AZ-A goes down.

The correct setup is one private route table per AZ, each pointing to the NAT Gateway in its own AZ:

```
AZ-A private route table → NAT Gateway in AZ-A
AZ-B private route table → NAT Gateway in AZ-B
```

Public route tables don't have this problem because the Internet Gateway is regional — it serves all AZs from a single resource.

**The fix:**
Created two private route tables, one per AZ, each with a route to its own NAT Gateway:

```hcl
# AZ-A private route table
resource "aws_route_table" "private_rt_a" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_a.id
  }
}

# AZ-B private route table
resource "aws_route_table" "private_rt_b" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_b.id
  }
}
```

App and DB subnets in the same AZ can share the same route table — so two route tables total covers both AZs, not four.

**What I learned:**

| Resource | Scope | Why |
|----------|-------|-----|
| Internet Gateway | Regional | Serves all AZs from one resource |
| NAT Gateway | AZ-specific | Must live in same AZ as the private subnet it serves |
| Route table | Subnet-bound | Determines whether subnet uses IGW or NAT |

You only need 2 private route tables for 2 AZs — one per AZ. App subnets and DB subnets in the same AZ can share the same private route table because they both route outbound traffic the same way.

---

## Issue 6: Module Tried to Reference Another Module's Resource Directly

**What happened:**
The EC2 module tried to reference a resource inside the VPC module directly. Terraform threw an error saying the reference was invalid.

**What caused it:**
Terraform modules are isolated — you cannot access resources inside another module from outside it. The only values a module exposes are the ones explicitly declared in its `outputs.tf`. Everything else is invisible to the outside world.

**The fix:**
Added the needed value as an output in the VPC module:

```hcl
# modules/vpc/outputs.tf
output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}
```

Then passed it through the root module to the EC2 module:

```hcl
# root main.tf
module "ec2" {
  source     = "./modules/ec2"
  subnet_ids = module.vpc.private_subnet_ids  # root collects and passes
}
```

**What I learned:**
Modules are black boxes. You only get what the module chooses to expose through outputs. The root module is the one that collects outputs from one module and passes them as inputs to another — modules never talk to each other directly. This keeps modules decoupled and reusable.

```
module.vpc → output → root module → input → module.ec2
                  ↑ the only path
```

---

## Issue 7: NAT Gateway Route Missing From Private Route Table

**What happened:**
NAT Gateway was created and running. EC2 instances in private subnets still couldn't reach the internet.

**What caused it:**
Creating a NAT Gateway doesn't automatically make private subnets use it. The private route table needs an explicit route that sends outbound internet traffic to the NAT Gateway. Without that route, private subnet instances have nowhere to send traffic destined for the internet — the request goes nowhere.

```hcl
# this route was missing
route {
  cidr_block     = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.nat.id
}
```

**The fix:**
Added the default route to the private route table pointing to the NAT Gateway. Also confirmed the NAT Gateway itself was in a public subnet with a route to the Internet Gateway — NAT needs a path to the IGW to function.

Outbound traffic flow for private subnet instances:
```
EC2 (private subnet)
  → private route table
  → NAT Gateway (public subnet)
  → public route table
  → Internet Gateway
  → Internet
```

**What I learned:**
NAT Gateway existing and being in a public subnet isn't enough. The private subnet's route table must explicitly point to it. Three things must all be true for private subnet internet access to work: NAT Gateway exists in a public subnet, the public subnet has a route to IGW, and the private subnet has a route to the NAT Gateway.

---

## Issue 8: Deployed 2 EC2 Instances Across 2 AZs Instead of 1

**This was a design decision, not an error.**

**The reasoning:**
A load balancer distributing traffic to a single instance doesn't actually provide high availability — if that one instance goes down, the load balancer has nowhere to route traffic and the app is down. The load balancer only serves its purpose when there are multiple healthy targets.

Placing one EC2 instance in each AZ means that if an entire AZ goes down, the other instance in the other AZ keeps serving traffic. The load balancer detects the unhealthy instance via health checks and stops sending it traffic automatically.

**What I learned:**
High availability requires at least two instances in different AZs. One instance behind a load balancer is just a load balancer with extra complexity — it doesn't add resilience.

---

## Issue 9: AZ Selection Was Inside the VPC Module — Moved to Root

**This was a design decision made after thinking through reusability.**

**The problem with AZ selection inside the VPC module:**
If the VPC module hardcodes which AZs to use, it can only work in regions that have those specific AZs. A module that works in `us-east-1` might break in `eu-west-1` because the AZ names are different.

**The fix:**
Moved AZ selection to the root module's `tfvars`:

```hcl
# terraform.tfvars
availability_zones = ["us-east-1a", "us-east-1b"]
```

The VPC module accepts them as a variable and uses whatever it receives:

```hcl
# modules/vpc/variables.tf
variable "availability_zones" {
  type = list(string)
}
```

**What I learned:**
Modules should be environment-agnostic — they shouldn't make assumptions about which region or AZ they're running in. Environment-specific decisions (which AZs, which CIDRs, which instance types) belong in `tfvars` at the root level. The module just consumes whatever it's given.

---

## Issue 10: CIDRs Hardcoded in Module — Moved to Root tfvars

**The problem:**
CIDRs hardcoded inside the VPC module meant the module could only create one specific network layout. Deploying to a different environment with different IP ranges required editing the module itself.

**The fix:**
Moved all CIDRs to `terraform.tfvars` and passed them into the module as variables:

```hcl
# terraform.tfvars
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.3.0/24", "10.0.4.0/24"]
db_subnet_cidrs      = ["10.0.5.0/24", "10.0.6.0/24"]
```

**What I learned:**
`tfvars` is where environment-specific values live. The module defines the structure. The root module provides the values. This is what makes a module reusable — you can call it with different `tfvars` for dev, staging, and prod without touching the module code.

---

## Issue 11: Used CIDR Rules Between Tiers — Switched to Security Group References

**The problem:**
The initial RDS security group allowed inbound traffic from the private subnet CIDR range. That means anything in that CIDR — including any future resource that lands in that subnet — can reach the database.

**The fix:**
Changed the RDS security group inbound rule to reference the EC2 security group ID instead of the CIDR:

```hcl
resource "aws_security_group_rule" "rds_from_ec2" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = var.ec2_security_group_id  # SG reference
  security_group_id        = aws_security_group.rds_sg.id
}
```

**What I learned:**
CIDR-based rules allow traffic from an IP range — any resource in that range qualifies. Security group references allow traffic only from resources explicitly assigned that security group. If a new EC2 instance is added to the subnet but shouldn't have database access, a CIDR rule would allow it anyway. A security group reference wouldn't. This is what least privilege looks like at the network level.

---

## Issue 12: Single NAT Gateway Instead of Two — Cost Decision With Known Tradeoff

**The decision:**
Best practice is one NAT Gateway per AZ. If the NAT Gateway's AZ goes down, private subnets in other AZs lose internet access. Two NAT Gateways eliminates that single point of failure.

However, NAT Gateway pricing is per hour plus per GB of data processed. Two NAT Gateways doubles the hourly cost. For a dev/learning environment, that cost isn't justified.

**Decision made:**
Single NAT Gateway for this project. Documented here so it's an explicit choice, not an oversight.

**What I learned:**
This is a real tradeoff that production teams make — some accept the single-AZ NAT risk to save cost, others require two for compliance or availability requirements. Knowing the tradeoff exists is more important than always picking the expensive option.

---

## Issue 13: Used CMK Instead of AWS-Managed Key for Secrets Manager

**The decision:**
Secrets Manager encrypts secrets by default using an AWS-managed key. You don't have to create anything — it just works. But with an AWS-managed key, you have no control over key rotation schedule and limited ability to audit or restrict access at the key level.

A Customer Managed Key (CMK) gives you full control: you control rotation, you control which IAM principals can use the key, and you can audit every use via CloudTrail. CMKs also meet compliance requirements like PCI-DSS, HIPAA, SOC2, and FedRAMP that require customer-controlled encryption.

```hcl
resource "aws_kms_key" "secrets_key" {
  description             = "CMK for RDS credentials secret"
  deletion_window_in_days = 10
  enable_key_rotation     = true
}

resource "aws_secretsmanager_secret" "database_cred" {
  name       = "rds_credentials"
  kms_key_id = aws_kms_key.secrets_key.arn
}
```

**One important constraint:**
You cannot change the KMS key on an existing RDS instance after creation. If you want to switch keys, you have to restore from a snapshot or recreate the database.

**What I learned:**
AWS-managed keys are fine for personal projects. In an enterprise or compliance context, CMKs are the standard because they give you auditability and control. The IAM policy for anything that needs to decrypt the secret must reference the CMK ARN — AWS APIs use the ARN as the unique identifier, not the key alias or name.

---

## Issue 14: Used Individual `aws_instance` Blocks — Switched to Launch Template + ASG

**The problem with individual `aws_instance` blocks:**
Two separate `aws_instance` resources means two separate blocks of nearly identical code. If you need to update the AMI or instance type, you update it in two places. If one instance fails, Terraform doesn't replace it — Terraform manages declared state, not desired runtime state. You'd have to manually intervene.

**The fix:**
Switched to a Launch Template + Auto Scaling Group:

```hcl
resource "aws_launch_template" "app" {
  name_prefix   = "app-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_profile.name
  }
}

resource "aws_autoscaling_group" "app" {
  desired_capacity    = 2
  min_size            = 2
  max_size            = 4
  vpc_zone_identifier = var.private_subnet_ids

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
}
```

**What I learned:**
Launch Templates are reusable instance configurations — like a recipe. The ASG uses that recipe to maintain the desired number of running instances and automatically replaces any that fail health checks. Updating the AMI in the Launch Template and cycling the ASG replaces instances without downtime, which isn't possible with individual `aws_instance` blocks.

---

## Issue 15: Created Four Route Tables — Only Two Needed

**What happened:**
I initially planned one route table per subnet type per AZ — one for app subnets in AZ-A, one for DB subnets in AZ-A, one for app subnets in AZ-B, one for DB subnets in AZ-B. That's four private route tables.

**Why only two are needed:**
App subnets and DB subnets in the same AZ route outbound traffic the same way — through the NAT Gateway in their AZ. Since the routing behavior is identical, they can share the same route table. One private route table per AZ is enough.

```
AZ-A: app subnets + DB subnets → share private_rt_a → NAT Gateway A
AZ-B: app subnets + DB subnets → share private_rt_b → NAT Gateway B
```

Public subnets across both AZs share a single public route table because the IGW is regional.

**What I learned:**
Route tables are about routing behavior, not about subnet type. If two subnets route traffic the same way, they can share a route table. Creating separate route tables for app vs. DB subnets adds maintenance overhead without any security or routing benefit.

---

## Issue 16: Used `random_password` for DB Password — Stored in Secrets Manager

**The design:**
Database passwords should never be hardcoded in Terraform files or `tfvars`. If they are, they appear in plaintext in the Terraform state file, which is stored wherever your backend is (S3, Terraform Cloud, etc.) and is readable by anyone with access to that backend.

```hcl
resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%^&*()-_=+[]{}|;:,.<>?"
}

resource "aws_secretsmanager_secret_version" "database_cred_version" {
  secret_id = aws_secretsmanager_secret.database_cred.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.rds_instance.address
    port     = 3306
    dbname   = var.db_name
  })
}
```

Terraform generates the password, stores it in Secrets Manager, and the application retrieves it from there at runtime. The password never appears in any config file or pipeline variable.

**What I learned:**
Even with `random_password`, the value still ends up in the Terraform state file. This is why state files should be stored in an encrypted S3 bucket with access logging enabled — not committed to the repository and not stored locally.

---

## Issue 17: Confused EIP With EC2 — EIP Is for the NAT Gateway

**What happened:**
I wasn't sure why an Elastic IP was being created separately and what it attached to.

**How it works:**
A NAT Gateway needs a public IP address to send traffic to the internet. That public IP is an Elastic IP (EIP). You create the EIP first, then attach it to the NAT Gateway via `allocation_id`. The EIP is not for the EC2 instance — EC2 instances in private subnets don't have public IPs at all.

```hcl
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id  # must be in a public subnet
}
```

**What I learned:**
NAT Gateway needs: a public subnet (with IGW route), and an EIP (for its public IP). Create the EIP first, then reference its ID when creating the NAT Gateway.

---

## Issue 18: Confused `aws_secretsmanager_secret` With `aws_secretsmanager_secret_version`

**What happened:**
I wasn't clear on the difference between the two resources and when to use each.

**How they work:**
- `aws_secretsmanager_secret` — creates the secret container. This is the named object in Secrets Manager. It doesn't hold a value yet.
- `aws_secretsmanager_secret_version` — stores the actual value inside that container. Every time you change the value, a new version is created.

```hcl
# the container
resource "aws_secretsmanager_secret" "database_cred" {
  name = "rds_credentials"
}

# the value inside the container
resource "aws_secretsmanager_secret_version" "database_cred_version" {
  secret_id     = aws_secretsmanager_secret.database_cred.id
  secret_string = jsonencode({ ... })
}
```

**What I learned:**
Think of the secret as a folder and the secret version as the file inside it. The secret persists — it has a name, ARN, and settings. The version holds the actual credential value and changes whenever the value is rotated or updated. When referencing the secret in IAM policies, use the secret's ARN. When reading the value in Ansible, you get the current version's `secret_string`.

---

## Issue 19: Used `.id` Where `.arn` Was Needed in IAM Policy

**What happened:**
An IAM policy resource block used `aws_secretsmanager_secret.database_cred.id` in the `Resource` field. The policy was created but permissions didn't work as expected.

**What caused it:**
IAM policy `Resource` fields require a full ARN — a globally unique identifier that includes the account ID, region, and resource name. `.id` in Terraform returns the resource's local identifier, which for Secrets Manager is the secret name — not the ARN. AWS couldn't match the policy resource to the actual secret.

**The fix:**
```hcl
# wrong
resource = aws_secretsmanager_secret.database_cred.id

# correct
resource = aws_secretsmanager_secret.database_cred.arn
```

**The rule:**
- Use `.id` when referencing a resource internally within Terraform (creating a secret version, linking resources together)
- Use `.arn` in IAM policies and anywhere AWS needs a globally unique resource identifier

**What I learned:**
When Terraform documentation shows a resource has both `.id` and `.arn` attributes, they're not interchangeable. `.id` is Terraform's internal reference. `.arn` is what AWS APIs expect when you need to identify a resource globally.

---

## Issue 20: `count` and `count.index` — How Modules Scale Dynamically

**What I had to work through:**
Using `count` to create multiple subnets and EC2 instances from a single resource block wasn't immediately obvious. The connection between `count`, `count.index`, and list variables took some working through.

**How it works:**
```hcl
# creates one subnet per CIDR in the list
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]
  vpc_id            = var.vpc_id
}
```

- `count = length(var.private_subnet_cidrs)` — creates one resource for each item in the list
- `count.index` — gives the current iteration number (0, 1, 2...)
- `var.private_subnet_cidrs[count.index]` — picks the corresponding item from the list

To reference all instances of a resource created with `count`, use the splat operator `[*]`:
```hcl
output "private_subnet_ids" {
  value = aws_subnet.private[*].id  # returns a list of all subnet IDs
}
```

**What I learned:**
`count` makes a single resource block act as a loop. The list length drives how many resources are created. Adding a new item to the list creates a new resource automatically — no new resource blocks needed. This is what makes modules reusable across environments with different numbers of AZs or subnets.

---

## Issue 21: Module Isolation — Values Must Flow Through Outputs, Not Direct References

**What I had to work through:**
When the EC2 module needed subnet IDs from the VPC module, my first instinct was to reference the VPC module's resources directly. Terraform doesn't allow this.

**How it actually works:**
```
Wrong:  module.ec2 → directly reads aws_subnet.private inside module.vpc
Right:  module.vpc → outputs private_subnet_ids → root module → passes to module.ec2
```

The root module is the coordinator — it collects outputs from one module and passes them as inputs to another:

```hcl
# root main.tf
module "vpc" {
  source = "./modules/vpc"
  # ...
}

module "ec2" {
  source     = "./modules/ec2"
  subnet_ids = module.vpc.private_subnet_ids  # root passes vpc output to ec2 input
}
```

**The distinction between `var.*` and `module.*`:**
- `var.*` — values that humans decide (instance type, environment name, CIDR ranges)
- `module.*` — values that Terraform already created (subnet IDs, security group IDs, RDS endpoint)

**What I learned:**
Modules don't talk to each other. The root module is the only one that has visibility into all module outputs and can wire them together. This is intentional — it keeps modules self-contained and reusable outside of this specific project.

---

## Issue 22: Route Table Scope — Why IGW Is Regional but NAT Is AZ-Specific

**What I had to work through:**
Understanding why public subnets can share one route table but private subnets need one per AZ.

**How it works:**

| Resource | Scope | Implication |
|----------|-------|-------------|
| Internet Gateway | Regional | One IGW serves all AZs — public subnets share one route table |
| NAT Gateway | AZ-specific | Each private subnet should route to NAT in the same AZ |
| Route table | Subnet-bound | Determines where subnet traffic goes |

Public subnets in AZ-A and AZ-B both route to the same IGW → they share one public route table.

Private subnets in AZ-A should route to NAT-A. Private subnets in AZ-B should route to NAT-B. Routing AZ-B traffic through NAT-A crosses AZ boundaries, adds latency, and creates a dependency on AZ-A's availability → separate private route tables per AZ.

**What I learned:**
The question to ask for each route table is: "do all the subnets sharing this route table route traffic identically?" If yes, they can share. If not, they need separate route tables.

---

## Issue 23: EC2 Cannot Directly Assume an IAM Role — Needs Instance Profile

**What I had to work through:**
When giving EC2 access to Secrets Manager, I initially tried to attach the IAM role directly to the instance. Terraform requires an instance profile as an intermediate step.

**How it works:**
EC2 instances don't assume IAM roles directly. They use an Instance Profile — a container that holds one IAM role and acts as the bridge between EC2 and IAM.

```hcl
# 1. Create the IAM role
resource "aws_iam_role" "ec2_role" {
  name = "ec2-secrets-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# 2. Attach permissions to the role
resource "aws_iam_role_policy" "secrets_access" {
  role = aws_iam_role.ec2_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.database_cred.arn
    }]
  })
}

# 3. Create the instance profile
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-instance-profile"
  role = aws_iam_role.ec2_role.name
}

# 4. Attach to EC2
resource "aws_instance" "app" {
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name
  # ...
}
```

**What I learned:**
The instance profile is the bridge between EC2 and IAM. You can't skip it even though it feels like an extra step. The IAM role defines what permissions exist. The instance profile is how EC2 accesses those permissions.

---

## Issue 24: Trust Policy vs. Permission Policy — Two Different Things

**What I had to work through:**
IAM roles have two separate policies that do different things. I initially conflated them.

**How they work:**

**Trust policy** — answers "who is allowed to assume this role?"
```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```
This says EC2 is allowed to assume this role. Without this, EC2 can't use the role at all.

**Permission policy** — answers "what is this role allowed to do?"
```json
{
  "Statement": [{
    "Effect": "Allow",
    "Action": "secretsmanager:GetSecretValue",
    "Resource": "arn:aws:secretsmanager:..."
  }]
}
```
This says the role can call `GetSecretValue` on a specific secret. Without this, EC2 can assume the role but can't actually do anything with it.

**What I learned:**
Both policies are required. A role with only a trust policy can be assumed but has no permissions — useless. A role with only a permission policy can never be assumed — also useless. Trust policy controls who. Permission policy controls what.

---

## General Takeaways

**Module design decisions have long-term consequences.**
Hardcoding values inside modules (AZs, CIDRs, AMIs) makes them work once and break everywhere else. Keeping environment-specific values in `tfvars` and passing them in as variables is the habit worth building from the start — retrofitting it later is more work than doing it right the first time.

**The state file is sensitive infrastructure.**
`random_password` generates credentials that end up in the state file. The state file should live in an encrypted S3 bucket with versioning enabled, not committed to the repository and not stored locally. Treat the state file with the same care as the credentials it contains.

**Test incrementally, not all at once.**
Deploying VPC first, verifying connectivity, then adding NAT and EC2, then RDS made it much easier to isolate which layer a problem was coming from. Deploying everything at once and debugging a failure means any of twenty resources could be the problem. Deploying in layers means the failure surface is small and obvious.

**Explicit is better than implicit.**
Terraform's defaults (main route table, default VPC, automatic subnet association) exist but are rarely what you want in a production-style setup. Explicitly creating and associating every resource — route tables, subnet associations, security group rules — means the infrastructure does exactly what you declared, not what AWS defaulted to.