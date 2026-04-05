# Security Best Practices

## Overview

Security was not an afterthought in this project — it was built into every layer of the infrastructure from the beginning. The approach follows **defense in depth** — multiple security controls so if one fails, others catch it.

---

## 1. Secrets Management

### Problem
Hardcoded database credentials in application code is one of the most common causes of data breaches. Anyone with code access can see the password.

### Solution
- Credentials stored exclusively in AWS Secrets Manager
- Ansible fetches credentials at runtime and injects them as environment variables via `setenv.sh`
- Application reads credentials via `System.getenv()` — never touching the codebase
- `detect-secrets` scans every commit and pipeline run for accidentally committed credentials

### Result
Zero credentials exist anywhere in the codebase or git history.

---

## 2. Network Isolation

### Problem
Databases exposed to the internet are vulnerable to direct attack, brute force attempts and unauthorized access.

### Solution
- RDS deployed in private subnet — no public internet access
- EC2 only accessible through Application Load Balancer
- Security groups enforce least privilege — only necessary traffic allowed
- NAT Gateway handles outbound traffic from private subnet

### Result
Database is completely isolated from internet. Only the application can reach it.

---

## 3. Infrastructure Security Scanning

### Problem
Misconfigured infrastructure is a leading cause of cloud security incidents. Manual reviews miss issues.

### Solution
Four tools run in both pre-commit hooks and CI/CD pipeline:

| Tool | Purpose |
|------|---------|
| `detect-secrets` | Scans for hardcoded credentials |
| `checkov` | Scans Terraform for security misconfigurations |
| `tflint` | Validates AWS specific configurations |
| `terraform fmt` | Enforces consistent formatting |

Two layers of scanning:
- **Pre-commit hooks** → catch issues before commit
- **Pipeline security scan** → catch anything that slipped through

### Result
Security issues are caught before they reach infrastructure. Defense in depth applied to the deployment pipeline itself.

---

## 4. Terraform Plan Approval Gate

### Problem
Applying Terraform without reviewing the plan risks unintended infrastructure changes reaching production.

### Solution
- Plan and apply separated into distinct pipeline stages
- Human readable plan output printed to Jenkins console
- Manual approval gate pauses pipeline before apply
- Saved plan file applied — guaranteeing reviewed changes are exactly what gets executed

### Result
Every infrastructure change is reviewed and explicitly approved before execution. Full audit trail of who approved what and when.

---

## 5. Credential Rotation Consideration

### Problem
Static credentials that never rotate are a persistent security risk. If compromised, attacker has indefinite access.

### Current Implementation
Secrets Manager configured with rotation capability. Tomcat reads credentials from `setenv.sh` on startup — requires restart after rotation to load fresh credentials.

### Production Enhancement
Two approaches for automatic rotation:

1. **Lambda trigger** — triggers on secret rotation event, restarts Tomcat to reload fresh credentials
2. **Dynamic fetching** — `DBConnection.java` modified to fetch credentials directly from Secrets Manager on each database connection — eliminating restart requirement entirely

---

## Defense in Depth Summary
```
Code level       → detect-secrets, no hardcoded credentials
Network level    → private subnets, security groups
Infrastructure   → checkov, tflint scanning
Pipeline level   → approval gates, security scan stage
Access level     → IAM roles, least privilege
```

Every layer catches what the previous layer missed.