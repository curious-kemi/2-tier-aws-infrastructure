# VotingApp Project: Problems, Security Lessons & Technical Learnings

A structured breakdown of every problem encountered, root cause, solution, and key lessons learned while building the 2-tier VotingApp on AWS using Terraform, Ansible, Jenkins, Spring Boot, and AWS Secrets Manager.

---

## Table of Contents

1. [Project Architecture Overview](#architecture)
2. [Infrastructure Problems (Terraform)](#terraform)
3. [Configuration Problems (Ansible)](#ansible)
4. [Security Issues & How They Were Resolved](#security)
5. [Secrets Management Integration](#secrets)
6. [Jenkins & CI/CD Pipeline Problems](#jenkins)
   - [Jenkins Multi-Repo & Workspace Problems](#jenkins-workspace)
7. [Spring Boot App Deployment Problems](#springboot)
8. [Pre-Commit & Code Scanning Problems](#precommit)
9. [Architectural Decisions & Patterns Learned](#patterns)
10. [Tool Roles Summary](#toolroles)

---

## 1. Project Architecture Overview {#architecture}

**Stack:** Terraform → Ansible → Jenkins → Spring Boot → AWS RDS → Secrets Manager

**Two deployment layers (learned the hard way):**

| Layer | What it creates | Who runs it |
|---|---|---|
| Bootstrap | VPC, Jenkins EC2, IAM roles | Run once manually |
| Platform | RDS, ALB, App EC2, Secrets Manager | Jenkins runs automatically |

**Key insight:** Mixing these into one Terraform deployment creates a circular dependency where Jenkins both runs Terraform and is created by Terraform.

---

## 2. Infrastructure Problems (Terraform) {#terraform}

### Problem: Circular Dependency — Secrets Manager ↔ RDS
**What happened:** The secret stored `host = module.rds.rds_address`, but RDS needed a password from Secrets Manager to be created. Terraform couldn't resolve the dependency loop.

**Root cause:** Treating the host address as a secret when it is actually public metadata.

**Solution:** Separate the secret from the host address.
- `random_password` generates password independently
- RDS uses `random_password.db_password.result` directly
- Secrets Manager stores the password *after* RDS is created
- Host is exposed via SSM Parameter Store, not Secrets Manager

**Lesson:** RDS does not need to know its own address to be created. Secrets Manager should only hold the password during initial creation. The host is not a secret — it's infrastructure metadata.

---

### Problem: RDS Rejected Password Characters
**What happened:** `random_password` generated a password containing `/` and `@`, which AWS RDS physically rejects.

**Solution:** Add `override_special` to restrict which special characters are allowed:
```hcl
override_special = "!#$%&*()-_=+[]<>:?"
```
Or use `special = false` for fully alphanumeric passwords.

**Lesson:** `override_special` replaces the entire default special character set. Think of it like restricting an alphabet — only the listed characters are eligible.

---

### Problem: Secret Name Conflict on Re-Deploy
**What happened:** AWS keeps deleted secrets in a "scheduled for deletion" state for 7–30 days. Re-running Terraform failed because the name `db_credentials` was still reserved.

**Solution:** Force-delete the old secret via CLI:
```bash
aws secretsmanager delete-secret --secret-id db_credentials --force-delete-without-recovery
```

---

### Problem: Hardcoded AMI IDs
**What happened:** AMI ID was hardcoded in `tfvars`. It is region-specific, becomes outdated, and breaks if you deploy to a different region.

**Solution:** Use a `data` source to dynamically fetch the latest AMI matching your criteria instead of hardcoding the ID.

**Lesson:** Hardcoded AMI IDs tell you nothing and break silently. Let Terraform find the latest image automatically.

---

### Problem: `terraform.tfvars` Naming
**What happened:** The variable file was given a custom name. Terraform did not automatically load it, prompting for all variable values at `plan` time.

**Solution:** The file must be named exactly `terraform.tfvars`. Terraform only auto-loads files with that name or `*.auto.tfvars`.

---

### Problem: Module Outputs Not Visible at Root
**What happened:** EC2 module had outputs defined, but `terraform output` showed nothing.

**Root cause:** The output chain was broken — module output existed but was never re-exported in root `outputs.tf`.

**The required chain:**
```
EC2 module output → root outputs.tf → visible to terraform output
```

**Lesson:** Every module output must be re-exported at root to be visible. Cross-module communication always goes through outputs and variables — never direct resource references. Modules are black boxes; you can only see what they expose.

---

### Problem: Wrong Resource Reference Across Modules
**What happened:** Root tried to reference `aws_instance.jenkins.public_ip` directly — a resource that lives inside a module.

**Solution:**
```hcl
# ❌ Wrong — can't reach inside a module
value = aws_instance.jenkins.public_ip

# ✅ Correct — go through the module's output
value = module.ec2_instance.jenkins_public_ip
```

---

### Problem: Jenkins IAM Role Created Before the Secret Exists
**What happened:** Bootstrap creates Jenkins EC2 and its IAM role, but the SSH key secret doesn't exist until Platform runs. The IAM role can't reference a specific ARN for something that doesn't exist yet.

**Solution:** Scope the IAM policy with a wildcard ARN tied to a naming convention:
```json
"Resource": "arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:prod/ssh/*"
```
Bootstrap creates the role with the wildcard. When Platform later creates `prod/ssh/ansible-key`, Jenkins already has permission. No circular dependency.

---

### Problem: Jenkins Can't Access S3 Backend State File
**What happened:** Jenkins runs Terraform in the pipeline but had no IAM permission to read/write the S3 state bucket.

**Solution:** Add an IAM policy to the Jenkins EC2 role:
```json
{
  "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket"],
  "Resource": ["arn:aws:s3:::your-state-bucket", "arn:aws:s3:::your-state-bucket/*"]
}
```

---

### Problem: SSH Key Pair — Terraform State Contains Private Key
**What happened:** Using `tls_private_key` in Terraform to generate the EC2 key pair stores the private key in the state file in plain text.

**Solution:** Encrypt the S3 backend using `encrypt = true`. This ensures the state file (and any sensitive values it contains) is encrypted at rest.

**Lesson:** Remote backend + encryption is mandatory when Terraform manages private keys or secrets.

---

## 3. Configuration Problems (Ansible) {#ansible}

### Problem: Wrong Package Manager for the AMI
**What happened:** Ansible tasks used `ansible.builtin.yum`, but the EC2 AMI was Ubuntu, which uses `apt`.

**Solution:** Match the package manager to the OS:

| OS | Package Manager | Default Username |
|---|---|---|
| Amazon Linux | `yum` | `ec2-user` |
| Ubuntu | `apt` | `ubuntu` |
| RHEL / CentOS | `yum` | `ec2-user` |
| Debian | `apt` | `admin` |

**Production approach:** Use `ansible.builtin.package` — it auto-detects the OS and uses the correct manager. For OS-specific package names, use `when: ansible_os_family == "Debian"` conditionals.

---

### Problem: Wrong SSH Username
**What happened:** `hosts.ini` used `ec2-user` but the AMI was Ubuntu. SSH authentication failed because Ubuntu's default user is `ubuntu`.

**Solution:** Update all references — `hosts.ini`, `aws_ec2.yml` dynamic inventory, and `votingapp.service.j2`:
```ini
[jenkins_server]
JENKINS_IP ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/key.pem
```

---

### Problem: `ansible-galaxy` Running Inside the Playbook
**What happened:** A task inside the playbook tried to run `ansible-galaxy collection install amazon.aws`. This failed because playbooks are for configuring servers — not for setting up Ansible itself.

**Root cause:** Two separate phases were mixed:

| Phase | What it is | Where it runs |
|---|---|---|
| Setup phase | Install Ansible tools, collections | Control node (your machine or Jenkins) |
| Deployment phase | Configure servers via playbook | Target EC2 |

**Solution:** Run `ansible-galaxy collection install amazon.aws` as a separate step *before* running the playbook, not inside it.

---

### Problem: `.pem` File Not in `~/.ssh`
**What happened:** The key pair was in the Downloads folder. Ansible couldn't authenticate.

**Solution:** Move the `.pem` file to `~/.ssh` and set correct permissions:
```bash
mv ~/Downloads/key.pem ~/.ssh/key.pem
chmod 400 ~/.ssh/key.pem
```

---

### Problem: App Keeps Stopping After Ansible Finishes
**What happened:** Running the app with `java -jar app.jar` ran it in the foreground. When Ansible finished, the process died.

**Solution:** Manage the app as a `systemd` service. This ensures:
- Runs in background
- Survives Ansible finishing
- Restarts automatically on reboot
- Manageable with `systemctl start/stop/restart`

**Rule:** Any long-lived process on a Linux server needs systemd.

---

### Problem: App Directory Doesn't Exist Before Copy
**What happened:** Ansible tried to copy the `.jar` to `/opt/votingapp/` but the directory didn't exist yet. The copy task failed.

**Solution:** Create the directory first using `ansible.builtin.file` with `state: directory`.

---

### Problem: Ansible Restarting the Service on Every Run
**What happened:** A regular restart task ran every time Ansible ran, even when nothing changed.

**Solution:** Use a handler instead. Handlers only fire when a task reports a change (e.g., the `.jar` was actually updated). This is idempotent behavior.

---

### Problem: `daemon_reload` Not Set When Creating Service
**What happened:** After creating the systemd service file, the service failed to start because systemd didn't know the file existed yet.

**Solution:** Always set `daemon_reload: true` the first time a service file is created or modified. This tells systemd to re-read all service files before acting.

---

### Problem: Using EC2 Dynamic Inventory Without IAM Permission
**What happened:** EC2 dynamic inventory (`aws_ec2.yml`) fetches instances by querying AWS tags. The IAM role was missing the `ec2:DescribeTags` permission.

**Solution:** Add a second statement to the IAM policy:
```json
{
  "Effect": "Allow",
  "Action": ["ec2:DescribeTags", "ec2:DescribeInstances"],
  "Resource": "*"
}
```

**Security note:** EC2 Describe actions must use `Resource: "*"` because they are list operations — there is no specific ARN to target. This is an AWS constraint, not a mistake.

---

## 4. Security Issues & How They Were Resolved {#security}

### Issue: Jenkins Port 8080 Exposed Publicly
**Risk:** An attacker can brute-force the admin password, gain access to your full CI/CD pipeline, deploy malicious code, access AWS credentials, and destroy infrastructure.

**Current approach (learning project):** Jenkins EC2 accessed via direct SSH. Security group restricts port 8080 to administrator IP only.

**Production standard:**
- Jenkins in a private subnet
- Access via AWS Systems Manager Session Manager (no port 22 needed)
- VPN + SSO + MFA for Jenkins UI
- No public IP on Jenkins at all

**Interview answer:** *"For this learning project Jenkins EC2 is accessed directly via SSH. In production Jenkins would sit in a private subnet accessed via AWS Systems Manager Session Manager — eliminating the need for open SSH ports entirely."*

---

### Issue: Using `Resource: *` in IAM Policies
**Rule:** Never use `*` for Resource when you can be specific.

| Permission Type | Resource |
|---|---|
| Secrets Manager read | Specific secret ARN ✅ |
| EC2 Describe (list ops) | Must be `*` ✅ — AWS constraint |
| S3 bucket actions | Specific bucket ARN ✅ |
| S3 object actions | Specific bucket + `/*` ✅ |

**Multiple statements in one policy:** Yes — one policy is a rulebook. Each statement is one rule with its own `Action`, `Effect`, and `Resource`. They are independent blocks.

---

### Issue: Hardcoded Database Credentials in Code
**Risk:** Credentials in code end up in Git history forever. Even after removal, they remain in past commits.

**Solution:** Spring Cloud AWS + `spring.config.import` — Spring Boot fetches credentials at startup from Secrets Manager. No credentials in code, no credentials in Ansible, no credentials in environment files.

---

### Issue: SSH Key Stored in Plain Text in Terraform State
**Risk:** Anyone with access to the state file has the private key.

**Solution:** S3 remote backend with `encrypt = true`.

---

### Issue: SSH Key Access Timing Problem (Plugin Limitation)
**Problem:** The AWS Secrets Manager Credentials Provider plugin loads credentials at Jenkins startup — before the pipeline runs. But the SSH key didn't exist until Terraform ran during the pipeline.

**Root cause:** Plugin reads secrets at startup, not dynamically at runtime.

**Solution:** Split the pipeline into two stages:
1. Stage 1 — Terraform creates the key and stores it in Secrets Manager
2. Stage 2 (separate run) — Jenkins reads the key from Secrets Manager and runs Ansible

This works because Terraform is idempotent — it will not recreate the key if it already exists on subsequent runs.

---

## 5. Secrets Management Integration {#secrets}

### How Spring Boot Connects to Secrets Manager

**Full flow:**
```
Terraform creates secret
     ↓
IAM role grants EC2 read access
     ↓
App starts on EC2
     ↓
spring.config.import triggers
     ↓
Spring Cloud AWS calls Secrets Manager
     ↓
EC2 IAM role authenticates (no hardcoded AWS keys)
     ↓
Secret fetched and parsed
     ↓
${host}, ${username}, ${password} populated
     ↓
JDBC connects to RDS
```

**Key rule:** Field names in the Terraform `jsonencode()` secret must exactly match the `${variable}` names in `application.properties`.

---

### Credential Refresh Approaches Compared

| Approach | No Hardcoding | Auto Rotation | No Restart | Spring Native | Complexity |
|---|---|---|---|---|---|
| Hardcoded | ❌ | ❌ | ✅ | ✅ | Low |
| `System.getenv()` | ✅ | ❌ | ❌ | ✅ | Low |
| AWS SDK + cache | ✅ | ✅ | ✅ | ❌ | High |
| Spring Cloud AWS | ✅ | ✅ | ✅ | ✅ | Medium |
| Secrets Manager JDBC driver | ✅ | ✅ | ✅ | ❌ | Low |

**Winner for Spring Boot:** Spring Cloud AWS — production standard, framework native, no restart needed, auto refresh on rotation.

---

### Secrets Manager JDBC Driver — Tradeoffs

**Pros:** Zero downtime rotation, built-in TTL caching (default 1 hour), minimal code changes, no extra libraries.

**Cons:**
- AWS vendor lock-in — can't easily switch to Vault or Azure Key Vault
- Limited database support (MySQL, PostgreSQL, MariaDB, Oracle limited)
- Less transparent — hard to debug when it fails
- Not Spring Boot native — better for plain Java/Tomcat apps
- Must be configured carefully with HikariCP connection pools

---

### Spring Boot Config Import Note (v2.4+)

In Spring Boot 2.4+, the bootstrap phase is disabled by default. Use `spring.config.import` instead:
```properties
spring.config.import=aws-secretsmanager:db_credentials
```

If you need to use bootstrap for legacy compatibility, add the `spring-cloud-starter-bootstrap` dependency to `pom.xml`.

---

## 6. Jenkins & CI/CD Pipeline Problems {#jenkins}

### Problem: Jenkins Role vs. Jenkinsfile Confusion

These are completely different things:

| | Jenkins Role (Ansible) | Jenkinsfile |
|---|---|---|
| What it is | Ansible role | Pipeline config |
| Language | YAML | Groovy |
| When it runs | Once — setup | Every code push |
| Job | Install Jenkins on EC2 | Define pipeline stages |
| Lives in | `ansible/roles/jenkins/` | Project root |

**Chicken and egg:** Jenkins runs Ansible, but Ansible installs Jenkins. Solution: run the Jenkins role *manually once* via Ansible from your local machine. After that, Jenkins owns all automation.

---

### Problem: Jenkins GPG Key / Java Version Mismatch
**What happened:** Incorrect Java version or outdated GPG key during Jenkins installation caused the Ansible role to fail.

**Lesson:** Always verify that the Java version and the GPG key in the Ansible role match the Jenkins version being installed. Check the official Jenkins install docs for current key URLs.

---

### Problem: EC2 Security Group Not Allowing Port 8080
**What happened:** Jenkins was running but the browser couldn't reach it.

**Lesson:** AWS security groups are default deny for inbound. You must explicitly allow port 8080 from your IP. After setup, restrict access to administrator IP only.

---

### AWS Secrets Manager Credentials Provider Plugin

**How it works:**
1. Install the plugin in Jenkins
2. Add the required tags to secrets in Secrets Manager so the plugin knows what credential type each secret is (e.g., SSH key, username/password, secret text)
3. Jenkins reads secrets at startup and makes them available as credentials in pipelines
4. The credential is loaded into memory for the duration of the pipeline block, then discarded — never written to disk

**Tag requirement:** Without the correct Jenkins-specific tags on the secret, credentials will not appear in Jenkins. Check the plugin documentation for exact required tags.

**Field name requirement:** The `jsonencode()` in Terraform must use the exact field names the plugin expects (e.g., `privateKey` for SSH credentials — verify in plugin docs).

**Single-field vs. multi-field secrets:** Not every secret needs `jsonencode()`. The AWS CLI example for an SSH key credential uses a raw string, not JSON:
```bash
aws secretsmanager create-secret --name 'ssh-key' \
  --secret-string 'file://id_rsa' \
  --tags 'Key=jenkins:credentials:type,Value=sshUserPrivateKey' 'Key=jenkins:credentials:username,Value=joe'
```
**Rule:** Single-field secrets (just a private key, just a token) → raw string. Multi-field secrets (host + username + password) → JSON, so the plugin/app can extract individual fields.

---

### Problem: SSH Key Doesn't Exist Yet When the Plugin Tries to Load It (Resolved)
**What happened:** The plan was for Terraform to create the SSH private key and store it in Secrets Manager, then have the Jenkins credentials plugin retrieve it for Ansible. But the plugin loads credentials at Jenkins **startup** — before the pipeline runs. The key didn't exist yet at that point because Terraform hadn't run.

**First instinct — split the pipeline:** Considered splitting into two pipeline runs so Terraform could create the key in one run before the plugin needed it in another. But the plugin doesn't continuously watch Secrets Manager in real time, and since Terraform is idempotent (it won't recreate an existing key), splitting added complexity without actually solving the timing problem.

**Actual resolution — stage ordering inside one pipeline:** No split needed. The fix was recognizing *when* the plugin actually reads the credential versus when it loads its credential list:
- `withCredentials` is scoped to the **Configure** stage
- The **Apply** stage (Terraform) runs *before* Configure
- By the time `withCredentials` tries to retrieve the credential in the Configure stage, Terraform has already created the secret with the correct tags in the Apply stage
- The plugin retrieves it at that moment — not at pipeline start

```groovy
node {
    withCredentials([sshUserPrivateKey(credentialsId: 'kola-key', keyFileVariable: 'KEY', usernameVariable: 'UBUNTU')]) {
        // Ansible steps run here, after Apply has already created the secret
    }
}
```

**Critical detail:** The `credentialsId` value must exactly match the secret name set in the `aws_secretsmanager_secret` Terraform resource.

**Lesson:** The plugin doesn't load *at Jenkins startup* in the way that blocks this pattern — it loads when `withCredentials` is evaluated in the pipeline. Sequencing stages correctly (Apply → Configure) solves the dependency without architectural changes.

---

## 6b. Jenkins Multi-Repo & Workspace Problems {#jenkins-workspace}

### Problem: No Source Code to Build
**What happened:** Jenkins ran `mvn package` to build the `.jar`, but the main repo only contained Terraform, Ansible, and the Jenkinsfile — no Java source, no `pom.xml`. The build failed immediately because there was nothing to compile.

**Cascading failure:** Because the `.jar` was never created, the Configure stage also failed — Ansible tried to copy `${WORKSPACE}/target/${APP_NAME}.jar`, a file that didn't exist. One missing piece broke two stages.

**Solution:** Use the `git` step (or `checkout scm`) inside the Jenkinsfile to pull the forked application repo during the Build stage, rather than assuming the source lives in the same repo as the infrastructure code.

---

### Problem: Checking Out a Second Repo Overwrote the Workspace
**What happened:** Using the `git` step to check out the forked app repo replaced the entire current workspace — destroying the Terraform/Ansible files that other stages still needed.

**Solution:** Use the `dir()` step to checkout the second repo into a named subdirectory instead of the workspace root:
```groovy
dir('app') {
    git url: 'https://github.com/forked-repo.git'
}
```
This keeps the infrastructure code and application code physically separated within the same workspace. The Configure stage's Ansible path was then updated to reflect the new nested `.jar` location (e.g., `app/target/votingapp.jar`).

**Lessons learned:**
- **Workspace is shared across all stages** — what one stage does affects every stage after it.
- **`git checkout` replaces wherever it runs** — be deliberate about where in the workspace a checkout happens, or it silently destroys files needed later.
- **File paths are relative to where the command runs** — `mvn package` puts the jar in `target/` relative to its execution directory; moving where it runs moves where every downstream reference needs to point.
- **Sketch the expected workspace layout after each stage before writing pipeline code** — this catches collisions before they cost debugging time.

**The bigger concept:** A pipeline is a sequence of state changes on a shared workspace. Every stage inherits exactly the state the previous stage left behind. Without deliberate control over that state, stages break each other in ways that are hard to trace back to a root cause.

**Interview angle:** Mentioning deliberate workspace management (e.g., always checking out a second repo into a named subdirectory) signals real pipeline experience — the kind that comes from being burned by a workspace collision, not from following a tutorial.

---

### Problem: Jenkinsfile Not Found — Case Sensitivity Mismatch
**What happened:** Jenkins failed immediately, unable to find the Jenkinsfile.

**Root cause:** macOS and Windows filesystems are case-insensitive — `jenkinsfile` and `Jenkinsfile` look identical to the local OS. The file was created locally with a capital `J`, but when pushed, GitHub (Linux-based, case-sensitive) had actually stored it as `jenkinsfile` from an earlier commit. A normal rename in Finder or VS Code doesn't register as a change to Git on a case-insensitive system, since Git sees no filename difference — so the bad casing persisted on GitHub even after "fixing" it locally.

**Solution:** Force Git to explicitly track the case change:
```bash
git mv jenkinsfile Jenkinsfile
git commit -m "Fix Jenkinsfile casing"
git push
```

**Lesson:** Always verify exact filenames on GitHub after pushing — especially convention-named files tools look for by exact string match: `Jenkinsfile`, `Dockerfile`, `Makefile`. A case-insensitive local rename will not propagate as a real change.

---

## 7. Spring Boot App Deployment Problems {#springboot}

### How Ansible Deploys a Spring Boot App

```
1. Install Java on EC2
      ↓
2. Create app directory (/opt/votingapp/)
      ↓
3. Copy .jar to EC2
      ↓
4. Create systemd service file
      ↓
5. daemon_reload
      ↓
6. Enable and start the service
      ↓
7. App starts — embedded Tomcat launches
      ↓
8. spring.config.import fetches credentials
      ↓
9. JDBC connects to RDS
      ↓
10. App serves users
```

**Note:** Spring Cloud AWS handles credentials at startup. Ansible no longer needs to fetch secrets, write `setenv.sh`, or install Tomcat separately.

---

### .jar File Name Is Case-Sensitive
**Lesson:** Look inside `pom.xml` to find the exact artifact name. The `.jar` filename must match exactly what Maven produces — Ansible will fail silently with a wrong name.

---

### Using Variables for Reusability
Define variables in `roles/app_server/defaults/main.yml`:
```yaml
app_name: votingapp
app_dir: /opt/votingapp
app_port: 8080
```
Then reference them everywhere with `{{ app_name }}`. Change one value and it updates across all tasks and templates.

**Always use spaces inside Jinja2 braces:** `{{ variable }}` — never `{{variable}}`.

---

## 8. Pre-Commit & Code Scanning Problems {#precommit}

### Problem: Wrong Filename
**What happened:** File was named `pre-commit-config.yaml` instead of `.pre-commit-config.yaml`. The leading dot is mandatory — it marks it as a hidden configuration file and is what the pre-commit tool specifically looks for.

**Fix:**
```bash
mv pre-commit-config.yaml .pre-commit-config.yaml
```

---

### Problem: Hook Version Outdated
**Error:** `CalledProcessError: command: git checkout v3.2.510 return code: 1`

**Root cause:** The hook version tag no longer existed in the upstream repository.

**Solution:** Run `pre-commit autoupdate` to let the tool update all hook versions to their latest stable tags.

**Rule:** Trust the automation for the environment. You manage the versions. Use `pre-commit autoupdate` to upgrade — never change version numbers by hand.

---

### Problem: TFLint Not Installed Locally
**What happened:** The pre-commit TFLint hook failed because TFLint was not installed on the local machine.

**Root cause:** Unlike Python or Node hooks, Terraform hooks in `pre-commit-terraform` require local binaries. The pre-commit framework does not manage Terraform tool installation.

**Solution:** Install TFLint locally, then run `tflint --init` to install the AWS/Azure plugins.

---

## 9. Architectural Decisions & Patterns Learned {#patterns}

### Plan Module Dependencies Before Writing Code
Map which modules need data from other modules before writing a single line. The Secrets Manager ↔ RDS circular dependency was predictable if the dependency graph had been drawn first.

### Root `main.tf` Is the Orchestrator
Modules should not reach into each other. Root passes values down as variables and receives values back as outputs. It is the only thing connecting modules together.

### Separate Infrastructure Concerns Into Playbooks
```
ansible/
├── playbook.yml     ← app servers only
├── jenkins.yml      ← Jenkins server only
├── monitoring.yml   ← monitoring
```
Each server type gets its own playbook. App servers don't have Jenkins installed. Jenkins doesn't have the app deployed. This is least privilege applied to configuration management.

### Data Sources for Cross-Stack References
When the Platform layer needs VPC/subnet IDs from the Bootstrap layer, use `terraform_remote_state` data sources. The state file belongs to the root module — not to child modules.

```
Stack that creates something → defines outputs
Stack that uses it → reads those outputs via terraform_remote_state
```

### State File Organization Convention
```
{environment}/{component}/terraform.tfstate
```
Example: `prod/platform/terraform.tfstate`, `prod/bootstrap/terraform.tfstate`

---

## 10. Tool Roles Summary {#toolroles}

| Tool | Job | Touches Credentials? |
|---|---|---|
| Terraform | Builds infrastructure, creates secrets | Creates secrets |
| Ansible | Configures servers, deploys app | ❌ No (Spring handles it) |
| Jenkins | Orchestrates everything | ❌ No |
| Spring Cloud AWS | Fetches credentials at app runtime | ✅ Yes |
| IAM role | Grants EC2 permission to access Secrets Manager | Enables access |
| Secrets Manager | Encrypted credential store | Stores credentials |
| SSM Parameter Store | Stores non-secret config (e.g., DB host) | Stores public metadata |

---

## Quick Reference: Debugging Commands

```bash
# Verbose SSH debugging
ssh -vvv -i ~/.ssh/key.pem ubuntu@EC2_IP

# Check your public IP
curl ifconfig.me
ipconfig getifaddr en0  # macOS

# Terraform validation before deploy
terraform validate
terraform plan

# Test Ansible syntax before running
ansible-playbook -i inventory/aws_ec2.yml playbook.yml --syntax-check

# Pre-commit on all files
pre-commit run --all-files

# Update all pre-commit hook versions
pre-commit autoupdate

# Show all files including hidden
ls -a
```

---

*Compiled from real troubleshooting sessions building the VotingApp on AWS. Every problem here was hit, debugged, and solved.*