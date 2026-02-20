# 2-tier Application Infrastructure on AWS


## 📌 Project Overview

The goal of this project was to deploy a secure full-stack voting app that allows users to cast votes on different options and view real-time results, which requires a web server and database.

## ⚠️  Challenges

1. Database credentials are often hardcoded in code or config files, which is a security risk.
2. Databases exposed to internet are vulnerable to attacks.
3. Manual Deployments lead to inconsistences and errors.
3. No automated security checks before code reaches production.

## 🛠️ Solution
As a DevSecOps engineer, i deployed a secure 2-tier application infrastructure on AWS using Terraform so that the application can run securely with proper network isolation and secret management. 

# Why this Solution?
AWS Secrets Manager stores database passwords securely and rotates them automatically
Private subnets keep databases isolated from internet
Terraform modules ensure consistent deployments across environments
Pre-commit hooks catch security issues before code is committed
CI/CD pipelines automate deployments and reduce human error


