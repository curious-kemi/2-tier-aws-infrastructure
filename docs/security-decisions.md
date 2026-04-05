# Security Decisions
### 2-Tier AWS Infrastructure (VotingApp)

This document records the security decisions made during the design and implementation of this infrastructure. Each entry explains the context, the decision, and the tradeoff accepted. The goal is not to claim the implementation is perfect — it is to show that every choice was deliberate.

---

## Decision 1: EC2 IAM Role Over Access Keys

**Context:**
The application server needs to retrieve database credentials from AWS Secrets Manager at runtime. The CI/CD pipeline also needs AWS access to provision infrastructure and run deployments. Both needs require AWS authentication.

**Decision:**
Attach an IAM instance profile to the EC2 instance granting `secretsmanager:GetSecretValue` on the specific secret ARN. Do not use access keys anywhere in the pipeline or on the instance.

**Why not access keys:**
Static access keys stored in environment variables, config files, or CI/CD secrets are themselves credentials that can be leaked. Using access keys to protect other credentials solves half the problem while creating the same problem in a different place. An EC2 IAM role provides temporary credentials automatically rotated by AWS — there is nothing to leak because there is nothing static to steal.

**Tradeoff accepted:**
If the IAM role is misconfigured with excessive permissions, any process running on the EC2 instance can use those permissions. Mitigated by scoping the role to `secretsmanager:GetSecretValue` on the specific secret ARN only — not `secretsmanager:*`, not `*`. The blast radius is bounded to one secret, not the entire AWS account.

---

## Decision 2: Security Group Rule Uses SG ID, Not CIDR

**Context:**
The RDS database needs to allow inbound connections from the EC2 application server on port 3306. The most common approach is to allow the EC2 instance's private IP address or subnet CIDR.

**Decision:**
The RDS security group inbound rule references the EC2 security group ID as the source, not a CIDR range.

**Why not CIDR:**
CIDR-based rules allow any resource within the specified IP range — including future resources that happen to land in that range. If the EC2 instance is replaced, terminated, or the subnet grows, the CIDR rule silently continues to permit access from the new IP addresses. Security group ID-based rules are identity-bound: only resources explicitly assigned the referenced security group can connect. The rule does not degrade as the environment changes.

**Tradeoff accepted:**
Security group ID references create a dependency between security groups that must be managed carefully. If the EC2 security group is deleted and recreated, the RDS inbound rule must be updated. Documented here so the dependency is explicit rather than discovered during an incident.

---

## Decision 3: RDS in Private Subnet, Not Just Security Group Protected

**Context:**
The RDS database must not be reachable from the internet. Two approaches exist: deploy it in a private subnet, or deploy it in a public subnet with a security group that blocks all public access.

**Decision:**
Deploy RDS in a private subnet with no route to the internet gateway. Security group rules are applied in addition, not instead.

**Why not security group only:**
Security groups are correct controls but they are configuration — they depend on rules being maintained accurately over time. A misconfigured rule, an overly broad allow added during an incident, or a human error during a change can expose a database that has a public IP address. A private subnet has no public IP and no route to the internet gateway — there is no path for internet traffic to reach the database regardless of what security group rules say. The subnet provides a structural guarantee that does not degrade with configuration drift.

**Tradeoff accepted:**
Resources in private subnets cannot initiate outbound internet connections directly. A NAT Gateway is required for outbound access (software updates, external API calls). NAT Gateway has a cost. That cost was accepted as the correct tradeoff for structural network isolation.

---

## Decision 4: detect-secrets Baseline Committed to Repository

**Context:**
`detect-secrets` scans for high-entropy strings and known credential patterns before every commit. It needs a way to distinguish known-safe values (test data, example strings, non-sensitive high-entropy values) from genuinely sensitive ones.

**Decision:**
Commit `.secrets.baseline` to the repository. This file records the current known state of high-entropy strings in the codebase. The pre-commit hook compares new commits against this baseline and fails on anything not already recorded.

**Why commit the baseline:**
Without a committed baseline, every developer on the team would need to generate and maintain their own local baseline. New team members would have no starting point. The pre-commit hook would behave differently on different machines. Committing the baseline makes the security posture consistent and auditable — you can see what was deliberately marked as safe and when.

**Tradeoff accepted:**
The baseline can become stale if the codebase changes significantly without being updated. A developer who marks something as safe in the baseline without review defeats the control. Mitigated by treating baseline updates as requiring the same review as any other security-relevant change. The baseline file itself is visible in the repository so any additions are part of the commit history.

---

## Decision 5: Credential Injection via setenv.sh, Not Application Code Changes

**Context:**
The VotingApp needs database credentials at runtime. Options: modify the application to call Secrets Manager directly, pass credentials as environment variables injected by the pipeline, or generate a configuration file from Secrets Manager values at deployment time.

**Decision:**
Ansible renders a `setenv.sh` file from a Jinja2 template populated with values retrieved from Secrets Manager at deployment time. Tomcat reads this file at startup and exposes the values as environment variables to the application.

**Why not pipeline-injected environment variables:**
Environment variables set by the pipeline exist at pipeline runtime, not on the server. To persist them to the EC2 instance, they would need to be written to a file or passed through SSH — which is effectively what `setenv.sh` does, except without the Secrets Manager retrieval step being handled securely by Ansible with `no_log: true`.

**Why not application code changes:**
Modifying the application to call Secrets Manager directly is the most robust long-term approach (it handles rotation automatically). However, it requires changes to the application source code and adds the AWS SDK as an application dependency. For this project, the goal was to externalize credentials without modifying application logic. `setenv.sh` achieves this: the application reads environment variables the same way it always has, and the infrastructure layer handles where those values come from.

**Tradeoff accepted:**
`setenv.sh` is loaded once at Tomcat startup. If Secrets Manager rotates the database password, Tomcat continues using the old value until it is restarted. This is a known gap documented in the Ansible architecture notes. The full solution requires either a rotation-triggered Lambda restart or migrating to runtime Secrets Manager calls in the application. Current scope does not include the Lambda trigger — flagged as a future improvement.

---

## Decision 6: CI Pipeline Fails on HIGH Severity checkov Findings

**Context:**
`checkov` scans Terraform code for security misconfigurations before `terraform plan` runs. It produces findings at CRITICAL, HIGH, MEDIUM, and LOW severity levels. A threshold must be set for what severity level fails the pipeline.

**Decision:**
The pipeline fails on HIGH and CRITICAL severity findings. MEDIUM and LOW produce warnings but do not block the apply.

**Why not fail on everything:**
Failing on MEDIUM and LOW in a real-world codebase produces enough noise that engineers begin adding `#checkov:skip` annotations reflexively without reviewing the finding. The control becomes theatrical. HIGH and CRITICAL represent findings with concrete, exploitable security impact — exposed databases, overly permissive IAM policies, unencrypted storage. These are the findings that matter.

**Why not fail on CRITICAL only:**
HIGH severity findings regularly include controls like logging disabled, public S3 buckets, and unrestricted egress rules — each of which has caused real incidents. Treating them as warnings normalizes the misconfigurations they represent.

**Tradeoff accepted:**
MEDIUM findings are suppressed from blocking the pipeline. Some MEDIUM findings are genuinely important in specific contexts. Any MEDIUM finding suppressed by this threshold should be reviewed manually during the PR process. This is a process control, not a technical one — it depends on reviewers actually looking at the checkov warning output.

---

## Decision 7: Customer-Managed KMS Key Over AWS-Managed Key for Secrets Manager

**Context:**
Secrets Manager encrypts secrets by default using an AWS-managed key. No additional configuration is required — it works out of the box. The alternative is to create a Customer-Managed Key (CMK) in KMS and explicitly assign it to the secret.

**Decision:**
Create a CMK in KMS and assign it to the Secrets Manager secret rather than using the AWS-managed default.

**Why not AWS-managed key:**
With an AWS-managed key, AWS controls the key entirely — you cannot restrict which IAM principals can use it for decryption, you cannot audit key usage independently, and you cannot customize the rotation schedule. Any IAM principal with `secretsmanager:GetSecretValue` permission can decrypt the secret without any additional key-level control.

With a CMK, the key itself has a resource policy. You can restrict `kms:Decrypt` to specific IAM roles only — so even if an IAM policy is misconfigured to allow `secretsmanager:GetSecretValue` too broadly, the CMK policy provides a second independent control that prevents decryption. Two independent controls are harder to misconfigure simultaneously than one.

CMKs also meet compliance requirements that AWS-managed keys do not — PCI-DSS, HIPAA, SOC2, and FedRAMP all require customer-controlled encryption keys for sensitive data.

**Tradeoff accepted:**
CMKs have a cost ($1/month per key plus per-API-call charges). The key must be managed — if it is accidentally deleted or disabled, the secret becomes inaccessible and cannot be recovered. KMS key deletion has a minimum 7-day waiting period specifically to prevent accidental permanent loss. For this project, the compliance and access control benefits justify the cost and management overhead.

---

## Decision 8: `random_password` for DB Credentials — Never in tfvars or State File (Plaintext)

**Context:**
The RDS database requires a password at creation time. The most straightforward approach is to set the password in `terraform.tfvars` and pass it as a variable. The alternative is to generate it programmatically.

**Decision:**
Use Terraform's `random_password` resource to generate the database password at apply time. Store only the generated value in Secrets Manager — never in `tfvars`, never hardcoded, never as a plain variable.

**Why not `tfvars`:**
Any value in `terraform.tfvars` is a plaintext file that can be committed to the repository accidentally. Even with `.gitignore` protection, the file exists on disk and in CI/CD environments where it must be present for the pipeline to run. More critically, every Terraform variable — including passwords passed via `tfvars` — is written to the Terraform state file in plaintext. The state file is not a secret file by default. Anyone with read access to the S3 bucket storing the state has the database password.

`random_password` generates the credential at apply time, writes it directly to Secrets Manager, and the application retrieves it from there. The password never exists in any file that a human reads or commits.

**Tradeoff accepted:**
The generated password is still written to the Terraform state file — `random_password` results are stored in state. This is mitigated by storing state in an S3 bucket with encryption enabled, versioning enabled, and access restricted to the pipeline role only. The state file itself must be treated as a sensitive artifact. Rotating the database password requires a Terraform apply to regenerate — not a Secrets Manager rotation trigger.

---

## Decision 9: Two Independent Scan Layers — Pre-Commit Hooks and CI Pipeline

**Context:**
Security scanning could be implemented in the CI pipeline only, relying on the pipeline to catch misconfigurations and secrets before they reach production. The alternative is to add pre-commit hooks that run locally before code is committed.

**Decision:**
Both layers are implemented independently. Pre-commit hooks run `detect-secrets`, `tflint`, `checkov`, and `terraform fmt` locally before every commit. The CI pipeline runs the same scans centrally on every push.

**Why both, not just CI:**
A CI pipeline scan catches problems after code has been pushed to the shared repository. A secret committed to GitHub — even briefly, even to a private repository — is potentially exposed. GitHub's history is permanent. Removing a secret from current code does not remove it from commit history. Pre-commit hooks prevent the secret from reaching the repository at all.

Pre-commit hooks also provide immediate feedback — the developer sees the failure in seconds, before context is lost, before a PR is open, before anyone else has pulled the branch.

**Why both, not just pre-commit:**
Pre-commit hooks run on the developer's local machine. They can be bypassed with `git commit --no-verify`. A new team member might not have the hooks installed. The CI pipeline is the centralized, non-bypassable gate — it runs regardless of local hook configuration and provides a consistent quality baseline across all contributors.

**The layered model:**
```
Developer commits → pre-commit hook (local, fast, first line of defense)
Code pushed → CI pipeline scan (centralized, enforced, second line of defense)
```

**Tradeoff accepted:**
Running the same scans twice adds pipeline time. Pre-commit hooks add friction to the commit workflow. Both are accepted tradeoffs — the cost of a false positive from a scan is seconds of developer time. The cost of a missed secret in production is a credential rotation incident.

---

## What This Project Does Not Prevent

Honest accounting of gaps within the current scope:

| Gap | Impact | Planned Remediation |
|-----|--------|-------------------|
| Secrets rotation not tested under active connections | Tomcat holds old credentials after rotation; app fails to connect | Lambda trigger on rotation event to restart Tomcat |
| No CloudTrail → alerting pipeline | API-level activity is logged but not monitored | CloudTrail → CloudWatch → SNS alert on suspicious calls |
| ASG deployed but rotation not load-tested | Instance replacement behavior under active connections unverified | Load test ASG replacement cycle with active traffic |
| No WAF on the ALB | Application-layer attacks reach EC2 directly | AWS WAF with managed rule groups |
| MEDIUM checkov findings not blocking | Some valid findings suppressed from pipeline gate | Periodic manual review of MEDIUM findings |

These are not oversights — they are scope decisions made against time and complexity constraints. They are documented here so the next engineer (or next sprint) knows exactly where to start.