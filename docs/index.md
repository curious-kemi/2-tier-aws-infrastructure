# Documentation Index
### 2-Tier AWS Infrastructure (VotingApp)

This folder contains detailed documentation on every layer of the project. The README covers what was built and why. These documents cover how it was built — the decisions made, the problems encountered, and what was learned.

---

## Where to start

**If you want to understand the security posture of this project:**
→ Start with [Security Decisions](security-decisions.md)

Nine documented decisions — each with context, reasoning, and the tradeoff accepted. Covers IAM design, network isolation, secrets management, KMS key strategy, credential scanning, and an honest accounting of what this project does not prevent.

**If you want to understand the infrastructure design:**
→ Start with [Ansible Architecture](ansible-architecture.md)

Covers how configuration management is structured, how credentials flow from Secrets Manager to the application, why specific tools and approaches were chosen, and where the known operational gaps are.

**If you want to see what actually happened during the build:**
→ Start with the troubleshooting logs

These are real problems encountered during the build — errors, design decisions that required working through, and concepts that weren't obvious until they broke something. Every issue includes what happened, what caused it, the fix, and what was learned.

---

## Documents

### [Security Decisions](security-decisions.md)
Nine security decisions made during design and implementation. Each entry follows the same format: context, decision, why not the alternative, tradeoff accepted. Ends with an honest gaps table — what this project does not prevent and what the remediation path would be.

**Key decisions covered:**
- EC2 IAM role over static access keys — and why scoping to a specific ARN matters
- Security group references over CIDRs between tiers — least privilege at the network level
- RDS in private subnet plus security groups — structural control over configuration-only control
- CMK over AWS-managed key — compliance alignment and second independent access gate
- `random_password` — why `tfvars` passwords end up in the state file in plaintext
- detect-secrets baseline committed to the repo — consistency and auditability
- Two independent scan layers — why both pre-commit hooks and CI scans are necessary
- Credential injection via `setenv.sh` — tradeoffs vs. runtime Secrets Manager calls
- checkov severity threshold — why failing on HIGH/CRITICAL only, and what that misses

---

### [Ansible Architecture](ansible-architecture.md)
How the configuration management layer is designed and why specific decisions were made. Written as an architecture document — not a tutorial on what Ansible is, but an explanation of what this project does and why.

**Key topics covered:**
- Why Ansible was chosen over agent-based tools for private subnet EC2 instances
- How credentials flow from Secrets Manager through Ansible to the application
- Role structure and why play-level directives belong in the playbook, not the role
- The `setenv.sh` approach — how Tomcat loads credentials and what breaks on rotation
- `no_log: true` — why it must apply to the entire credential chain, not just the fetch task
- Security controls applied at the configuration management layer

---

### [Terraform Troubleshooting](terraform-troubleshooting.md)
24 real issues encountered while building the Terraform infrastructure — including actual error messages, design decisions made under constraints, and architectural concepts that required working through.

**Notable issues:**
- `CreateSecret` 400 error — secret pending deletion blocks recreation (with the actual error message)
- Secret stored as plain string — why `from_json` fails silently and how to diagnose it
- Single subnet for RDS — why RDS requires a DB subnet group, not a subnet ID
- Two private route tables required for multi-AZ — NAT Gateway is AZ-specific, IGW is regional
- Module isolation — why modules can't reference each other's resources directly
- CMK vs AWS-managed key — compliance and access control reasoning
- Single vs two NAT Gateways — cost decision with documented tradeoff
- Trust policy vs permission policy — two distinct IAM concepts and why both are required

---

### [Ansible Troubleshooting](ansible-troubleshooting.md)
20 real issues encountered while building the Ansible configuration management layer.

**Notable issues:**
- Secret stored as plain string — same root cause as Terraform Issue 2, different failure surface
- Wrong Tomcat path — how install method determines file location and why Ansible can't validate this
- Credential rotation gap — why Tomcat's startup-only credential load breaks on rotation
- Missing `export` in `setenv.sh` — why `System.getenv()` returns null even when the file is correct
- `no_log: true` not applied to the full chain — credentials printed to pipeline logs
- `amazon.aws` collection not installed — lookup plugin present but not found
- boto3 not installed — collection installed but SDK missing on control node
- Ansible Vault evaluated and rejected — why Secrets Manager is the right tool for runtime credentials

---

### [CI/CD Troubleshooting](cicd-troubleshooting.md)
24 real issues encountered while building the Jenkins pipeline.

**Notable issues:**
- `detect-secrets` baseline regenerated in pipeline — why this defeats the entire purpose
- `checkov -d` without `.` — small omission, complete stage failure
- `terraform fmt` without `-recursive` — nested module files not checked
- Plan not archived — overwritten before review, plan and apply become disconnected
- Pipeline stage order — why security scans run before infrastructure, not after
- Plan/apply separation with human approval gate — why blind apply is unacceptable
- Static `hosts.ini` — why dynamic inventory is required for cloud infrastructure
- Two EC2 instances, one configured — how dynamic inventory and tag-based targeting fixes this
- `${WORKSPACE}` — why the `.war` path must be passed at runtime, not hardcoded

---

## How the documents relate

```
README
  └── What was built, architecture overview, security summary, known gaps
        │
        ├── Security Decisions
        │     └── Why every security choice was made — the reasoning behind the README claims
        │
        ├── Ansible Architecture
        │     └── How the configuration layer works in detail
        │
        └── Troubleshooting Logs (Terraform · Ansible · CI/CD)
              └── What actually happened during the build — errors, fixes, and lessons
```

The README makes claims. The security decisions document justifies them. The troubleshooting logs prove the project was actually built.

---

## A note on the troubleshooting logs

These documents include foundational issues alongside complex ones — YAML indentation errors alongside multi-AZ routing decisions. That's intentional. The value isn't in the sophistication of each individual problem. It's that every problem was diagnosed independently, understood at the root cause level, and fixed correctly. The logs are a record of how the system was understood, not just that it was built.