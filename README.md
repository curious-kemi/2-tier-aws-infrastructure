
# 🚀 Production-Grade 2-Tier Application Infrastructure on AWS

## 📌 Overview

This project demonstrates the design and implementation of a **secure, scalable, and automated 2-tier application infrastructure on AWS** using Infrastructure as Code, configuration management, and CI/CD practices.

The platform provisions a complete environment for running a web application backed by a database, with a strong emphasis on **security, automation, reliability, and operational excellence**.

---

## 💡 Business Use Case

This platform simulates a real-world voting system where users can securely submit and track votes. 

The infrastructure ensures:
- High availability for user access
- Secure storage of voting data
- Automated deployments for rapid updates
- Protection of sensitive credentials

This reflects how modern organizations build reliable and secure web platforms at scale.
 
 ---

## 🎯 Objectives

* Build a production-style infrastructure using **Terraform**
* Ensure **secure secret management** using AWS Secrets Manager
* Automate server configuration using **Ansible**
* Implement a **CI/CD pipeline** for consistent deployments
* Enforce **security and compliance checks** before deployment
* Design a system with **network isolation and least privilege access**

---

## 🏗️ Architecture Overview

The infrastructure follows a **secure 2-tier architecture**:

* **Application Load Balancer (ALB)** in public subnet
* **EC2 instance (Application Layer)** in private subnet
* **RDS database (Data Layer)** in private subnet
* **AWS Secrets Manager** for secure credential storage
* **NAT Gateway** for outbound internet access from private subnet
* **Security Groups** to enforce strict access control

### 🔄 Traffic Flow

1. User sends request via browser
2. Request hits **Application Load Balancer**
3. ALB routes traffic to **EC2 instance**
4. EC2 retrieves database credentials securely from **Secrets Manager**
5. EC2 connects to **RDS database** in private subnet

---

## 🧰 Tech Stack

| Category                 | Tools                                 |
| ------------------------ | ------------------------------------- |
| Cloud Provider           | AWS                                   |
| Infrastructure as Code   | Terraform                             |
| Configuration Management | Ansible                               |
| CI/CD                    | GitHub Actions / Jenkins              |
| Security                 | AWS Secrets Manager, Pre-commit hooks |
| Networking               | VPC, Subnets, IGW, NAT Gateway        |
| Compute                  | EC2                                   |
| Database                 | RDS (MySQL/PostgreSQL)                |
| Load Balancing           | Application Load Balancer             |

---

## 🔐 Security Design

* ✅ No hardcoded credentials in code or repository
* ✅ All secrets stored in **AWS Secrets Manager**
* ✅ Database deployed in **private subnet (no public access)**
* ✅ EC2 instance access restricted via security groups
* ✅ Pre-commit hooks to detect secrets and misconfigurations
* ✅ IAM roles used for secure service-to-service access

---

## ⚙️ Infrastructure Automation (Terraform)

Infrastructure is fully provisioned using reusable Terraform modules:

* VPC (subnets, routing, gateways)
* EC2 instance (with IAM role)
* RDS database (private access only)
* Application Load Balancer
* Secrets Manager

### Key Benefits:

* Consistent deployments across environments
* Version-controlled infrastructure
* Easy teardown and recreation

---

## 🤖 Configuration Management (Ansible)

Ansible is used to configure the EC2 instance after provisioning:

### Roles:

* **Common Role**: installs base dependencies (git, curl, etc.)
* **Application Role**: installs and configures web server (Apache/Nginx)
* **Jenkins Role**: sets up automation server

### Outcome:

* Fully configured application server
* No manual server setup required

---

## 🔄 CI/CD Pipeline

The CI/CD pipeline is implemented using **GitHub Actions and Jenkins**, combining modern cloud-native workflows with traditional automation capabilities.

### Pipeline Responsibilities:

#### GitHub Actions:
- Triggered on code push
- Validates Terraform configuration
- Runs security scans (Checkov, TFLint, detect-secrets)
- Initiates infrastructure provisioning workflow

#### Jenkins:
- Executes advanced automation tasks
- Runs Ansible playbooks for EC2 configuration
- Handles application deployment to EC2 instance
- Provides flexibility for customizable job pipelines

### Pipeline Flow:
1. Developer pushes code to GitHub
2. GitHub Actions triggers pipeline:
   - Validates code and infrastructure
   - Runs security checks
3. Jenkins executes:
   - Ansible configuration
   - Application deployment
4. Application becomes available via Load Balancer

### Benefits:
- Separation of concerns between CI and CD  
- Flexible and extensible automation workflows  
- Reduced manual intervention and deployment errors  

---

## 🔍 Pre-Commit Hooks

Pre-commit hooks enforce code quality and security:

* Detect secrets in code
* Validate Terraform formatting
* Scan for security misconfigurations

### Tools Used:

* detect-secrets
* tflint
* checkov
* terraform fmt

---

## 📈 Operational Excellence

This project emphasizes real-world operational practices:

* 🔄 Automated deployments via CI/CD
* 🔐 Secure credential management
* 🌐 Network isolation for sensitive resources
* 📦 Infrastructure version control
* ⚙️ Repeatable environment provisioning

---
## 🧪 Application

This project deploys a **Voting App**, a web-based application that allows users to cast and track votes in real time.

### Key Features:
- Users can submit votes through a web interface
- Application stores vote data in an RDS database
- Backend securely retrieves database credentials from AWS Secrets Manager
- No sensitive information is hardcoded in the application

### Architecture Behavior:
- Frontend served via EC2 instance
- Application connects to RDS in a private subnet
- Credentials are dynamically injected at runtime

---

## 📂 Repository Structure

```
.
├── terraform/
│   ├── modules/
│   └── main.tf
├── ansible/
│   ├── roles/
│   └── playbook.yml
├── .github/workflows/
├── .pre-commit-config.yaml
└── README.md
```

---

## 🚀 How to Deploy

### Prerequisites:

* AWS CLI configured
* Terraform installed
* Ansible installed
* Git installed

### Steps:

1. Clone the repository
2. Configure variables (`terraform.tfvars`)
3. Run Terraform:

   ```bash
   terraform init
   terraform apply
   ```
4. CI/CD pipeline will:

   * Configure EC2 via Ansible
   * Deploy the application

---

## 🧠 Key Learnings

* Designed secure cloud infrastructure with network isolation
* Implemented Infrastructure as Code using Terraform
* Automated server configuration using Ansible
* Built CI/CD pipelines with integrated security checks
* Applied DevOps best practices for scalability and reliability

---

## 🎯 Outcome

This project demonstrates the ability to:

* Build and manage **secure cloud infrastructure**
* Automate deployments and configurations
* Implement **DevOps best practices in a real-world scenario**
* Ensure system reliability and operational efficiency

---

## 📌 Future Improvements

* Add containerization (Docker + Kubernetes)
* Implement monitoring (Prometheus + Grafana)
* Add auto-scaling for EC2 instances
* Introduce multi-environment support (dev/staging/prod)

---

## Author

Oluwakemi Oshunkeye
