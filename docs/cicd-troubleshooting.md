# Troubleshooting Log & Build Notes — CI/CD Pipeline (Jenkins)
### 2-Tier AWS Infrastructure (VotingApp)

Real issues encountered while building the Jenkins pipeline — errors, design decisions, and concepts that required working through. Documented so the next person doesn't have to figure these out from scratch.

---

## Issue 1: Used `ansible.builtin.shell` for Package Management — Not Idempotent

**What happened:**
The Ansible role used `ansible.builtin.shell` to install packages and add repositories. The pipeline ran successfully the first time. On subsequent runs, the shell commands ran again even though the packages were already installed — wasting time and occasionally causing errors when commands failed because something already existed.

**What caused it:**
`ansible.builtin.shell` is not idempotent by default. It runs the command every single time the playbook executes, regardless of whether the desired state already exists. Proper Ansible modules like `ansible.builtin.yum` check current state first — if the package is already installed, they skip it.

**The fix:**
Replaced shell commands with proper Ansible modules wherever one existed:

```yaml
# wrong — runs every time
- name: Install Terraform
  ansible.builtin.shell: yum install terraform -y

# right — skips if already installed
- name: Install Terraform
  ansible.builtin.yum:
    name: terraform
    state: present
```

The rule of thumb for choosing between shell and a proper module:

| Task | Use module | Why |
|------|-----------|-----|
| Installing packages | `ansible.builtin.yum` / `apt` | Built-in idempotency |
| Copying files | `ansible.builtin.copy` / `template` | Checks if file changed |
| Managing services | `ansible.builtin.service` | Checks current state |
| Downloading files | `ansible.builtin.get_url` | Checks if file exists |
| Anything else | `ansible.builtin.shell` | Last resort only |

**What I learned:**
Before writing a shell command in Ansible, ask "what happens if this runs twice?" If the answer is "it runs again and might fail or do something unintended," look for a proper module first. Shell is the last resort — only use it when no module exists for what you need.

---

## Issue 2: `detect-secrets scan > .secrets.baseline` Inside the Pipeline — Defeats the Purpose

**What happened:**
The pipeline included a step that ran `detect-secrets scan > .secrets.baseline` on every run. No secrets were ever flagged. The scan always passed.

**What caused it:**
Running `detect-secrets scan > .secrets.baseline` in the pipeline overwrites the baseline on every run. The baseline becomes whatever secrets exist at that moment. On the next run, those same secrets are now "known" — so nothing gets flagged as new. The tool runs but catches nothing.

The baseline is supposed to be a fixed snapshot of known-safe values committed to the repository. New secrets are flagged because they weren't in that snapshot. If the snapshot is rebuilt every run, nothing is ever new.

**The fix:**
Created the baseline once locally and committed it to the repository:

```bash
# run once locally
detect-secrets scan > .secrets.baseline
git add .secrets.baseline
git commit -m "add detect-secrets baseline"
```

The pipeline only audits against the committed baseline — it never regenerates it:

```groovy
sh 'detect-secrets audit .secrets.baseline'
```

**What I learned:**
The baseline is not a pipeline artifact — it's a committed configuration file. Creating it in the pipeline defeats the entire purpose of having a baseline. Pre-commit hooks use the committed baseline to flag anything new. The pipeline verifies the baseline hasn't been tampered with.

---

## Issue 3: `checkov -d` Without the `.` — Checkov Doesn't Know What to Scan

**What happened:**
The checkov command in the pipeline was written as `checkov -d` without specifying a directory. Checkov threw an error and the stage failed.

**What caused it:**
The `-d` flag tells checkov which directory to scan. Without an argument after `-d`, checkov has no target. The `.` means "current directory" — without it, the command is incomplete.

**The fix:**
```groovy
# wrong
sh 'checkov -d'

# right
sh 'checkov -d .'
```

**What I learned:**
Small things like a missing `.` break pipelines completely. When a security scanning tool fails in CI, the failure message usually tells you exactly what's wrong — read it before searching.

---

## Issue 4: tflint Pre-Commit Hook Missing Config File Argument

**What happened:**
tflint ran in the pre-commit hook but wasn't using the `.tflint.hcl` configuration file. AWS-specific rules weren't being applied — tflint was running with default settings only.

**What caused it:**
The `.pre-commit-config.yaml` entry for tflint didn't pass the `--config` argument pointing to the config file. Without it, tflint ignores the config file and runs with defaults.

**The fix:**
```yaml
# wrong — no config specified
- id: terraform_tflint

# right — config file explicitly passed
- id: terraform_tflint
  args:
    - --args=--config=terraform/.tflint.hcl
```

**What I learned:**
Most tools need a configuration file to work at full capability. The pattern is always: install → read docs → create config file → then use. I skipped the config step for tflint initially and got basic functionality instead of the AWS-aware scanning the project needed. Always check whether a tool has a config file before assuming it's working correctly.

---

## Issue 5: `terraform fmt` Without `-recursive` — Missed Files in Nested Modules

**What happened:**
`terraform fmt -check` passed in the pipeline. But Terraform files inside module subdirectories had formatting issues that weren't caught.

**What caused it:**
Without `-recursive`, `terraform fmt` only checks files in the current directory. Module files in subdirectories are ignored entirely. In a project with a `modules/` directory, the most important files weren't being checked.

**The fix:**
```groovy
# wrong — only checks current directory
sh 'terraform fmt -check'

# right — checks all subdirectories too
sh 'terraform fmt -check -recursive'
```

**What I learned:**
`-recursive` is easy to forget and has no obvious failure mode — the command succeeds and reports no issues, which looks like everything is fine. Always use `-recursive` for any Terraform command that should apply to the whole project, not just the root.

---

## Issue 6: `terraform plan` Output Not Archived — Gets Overwritten

**What happened:**
The pipeline saved the Terraform plan to a file called `tfplan`. When the pipeline ran again before the plan was reviewed and applied, the previous plan was overwritten. There was no way to know what had changed between runs.

**What caused it:**
Without archiving, `tfplan` lives only in the Jenkins workspace for that run. If another pipeline run starts, the workspace gets reused and the file is overwritten. The plan that was reviewed may not be the plan that gets applied.

**The fix:**
Added `archiveArtifacts` after the plan stage to permanently save it in Jenkins:

```groovy
stage('Plan') {
    steps {
        sh 'terraform -chdir=terraform/ plan -input=false -out=tfplan.txt'
        archiveArtifacts artifacts: 'tfplan.txt'
    }
}
```

**What I learned:**
In production you never blindly apply Terraform. You save the plan, review it, and apply that exact saved plan. Archiving it in Jenkins means the reviewed plan is the applied plan — no surprises from infrastructure that changed between plan and apply.

---

## Issue 7: Saved Plan as Binary `tfplan` Instead of Human-Readable `tfplan.txt`

**What happened:**
The plan was saved and archived but opening the file showed binary output — unreadable. There was no way to review what Terraform was about to do.

**What caused it:**
`terraform plan -out=tfplan` saves a binary plan file. It's machine-readable but not human-readable. To review what will change before approving the apply, you need a text version.

**The fix:**
Changed the output filename to `.txt` so Jenkins renders it as readable text:

```groovy
sh 'terraform -chdir=terraform/ plan -input=false -out=tfplan.txt'
```

Then apply the saved plan:
```groovy
sh 'terraform -chdir=terraform/ apply -input=false -auto-approve tfplan.txt'
```

**What I learned:**
The plan file exists so humans can review it. A binary file that can't be read defeats the purpose of separating plan and apply. Name it `.txt` so it's readable when archived in Jenkins.

---

## Issue 8: Tools Installed But Config Files Not Created First

**What happened:**
tflint and detect-secrets were installed and called in the pipeline. tflint didn't apply AWS-specific rules. detect-secrets had nothing to compare against. Both tools ran but weren't doing their full job.

**What caused it:**
I installed and ran the tools before creating their configuration files. Both tools need config files to work properly:

| Tool | Config file | What it does |
|------|------------|-------------|
| tflint | `.tflint.hcl` | Enables AWS provider rules |
| detect-secrets | `.secrets.baseline` | Defines what's already known so new secrets get flagged |
| terraform | `terraform.tfvars` | Provides variable values |
| ansible | `ansible.cfg` | Sets connection and behavior defaults |

**The fix:**
Created config files before running the tools:

```hcl
# terraform/.tflint.hcl
plugin "aws" {
  enabled = true
  version = "0.27.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
```

```bash
# create baseline locally once
detect-secrets scan > .secrets.baseline
```

**What I learned:**
The pattern for any new tool is: install → read docs → create config file → then use. Skipping the config step gives you a tool that runs but doesn't do what you need. Config files also belong in the repository — if they're only configured on the server, the next person who clones the repo gets inconsistent behavior.

---

## Issue 9: Hardcoded EC2 IP in `hosts.ini` — Breaks When Terraform Creates New Instances

**What happened:**
The Ansible inventory file `hosts.ini` had the EC2 IP address hardcoded. When Terraform destroyed and recreated the infrastructure, the EC2 got a new IP address. Ansible couldn't connect because it was still trying to reach the old IP.

**What caused it:**
AWS assigns private IP addresses dynamically. Every time an EC2 instance is created, it may get a different IP. A hardcoded IP in `hosts.ini` is only valid for the lifetime of that specific instance — the moment it's replaced, the inventory is wrong.

**The fix:**
Switched to AWS EC2 dynamic inventory — an Ansible plugin that queries the AWS API at runtime to discover instance IPs automatically:

```yaml
# ansible/inventory/aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
filters:
  tag:Environment: dev
  instance-state-name: running
```

Ansible uses this file to discover running instances matching the filters instead of reading a static IP list.

**What I learned:**
Static inventory files work for fixed infrastructure. In cloud environments where instances are created and destroyed by Terraform, static inventory is fragile — it's always one `terraform apply` away from being wrong. Dynamic inventory is the correct solution for any infrastructure that changes.

---

## Issue 10: Two EC2 Instances Deployed But Ansible Only Configured One

**What happened:**
Terraform deployed two EC2 instances across two AZs. The Ansible playbook only ran against one of them. The second instance was running but not configured — no Tomcat, no application, no credentials.

**What caused it:**
The static `hosts.ini` only had one IP address. Even after switching to dynamic inventory, the playbook needed to target the correct group to reach both instances.

**The fix:**
With dynamic inventory, instances are grouped automatically by tags. Tagged both EC2 instances with `Environment: dev` in Terraform, then targeted that group in the playbook:

```yaml
# site.yml
- hosts: tag_Environment_dev
  become: true
  roles:
    - common
    - app_server
```

Dynamic inventory creates host groups from AWS tags automatically — `tag_Environment_dev` targets every running instance tagged `Environment: dev`.

**What I learned:**
When using dynamic inventory, tags are how you target groups of instances. The tag you set in Terraform becomes the group name in Ansible. Plan your tagging strategy before you write the playbook — the tag names need to match.

---

## Issue 11: Pipeline Stage Order — Why the Sequence Matters

**What I had to work through:**
The pipeline stages weren't obviously ordered at first. I had to think through what each stage depends on before it can run.

**The correct order and why:**

```
1. Build        → produce the .war file first
      ↓            (nothing else can run without the compiled app)
2. Security Scan → catch problems before touching infrastructure
      ↓            (cheaper to fail here than after AWS resources exist)
3. Infrastructure → provision EC2, RDS, networking
      ↓            (EC2 must exist before you can configure it)
4. Configure    → install Tomcat, inject credentials, configure server
      ↓            (Tomcat must be installed before you can deploy to it)
5. Deploy       → copy .war to Tomcat
                  (everything must be ready before the app can run)
```

Each stage is a gate. If Build fails, there's no .war to deploy. If Security Scan fails, no AWS costs are incurred. If Infrastructure fails, there's nowhere to configure. Order is not arbitrary.

**What I learned:**
Security scans run before infrastructure because failing a scan after Terraform has already created resources means you have to either clean up or deploy insecure infrastructure. Failing before Terraform runs costs nothing. This is the "shift left" principle in practice — catch problems as early in the pipeline as possible.

---

## Issue 12: Separated Plan and Apply With a Human Approval Gate

**The design:**
Early versions of the pipeline ran `terraform plan` and `terraform apply` in the same stage with no review step. Whatever Terraform planned would be applied immediately.

**Why that's a problem:**
In a real environment, Terraform might plan to destroy a database or replace an EC2 instance. Without reviewing the plan first, that happens automatically. In production you never blindly apply — you review the plan and approve it explicitly.

**The fix:**
Split into two stages with an `input` step between them:

```groovy
stage('Plan') {
    steps {
        sh 'terraform -chdir=terraform/ plan -input=false -out=tfplan.txt'
        archiveArtifacts artifacts: 'tfplan.txt'
    }
}

stage('Approval') {
    steps {
        input message: 'Review the plan above. Approve to apply?'
    }
}

stage('Apply') {
    steps {
        sh 'terraform -chdir=terraform/ apply -input=false -auto-approve tfplan.txt'
    }
}
```

The `input` step pauses the pipeline and displays a prompt in the Jenkins UI. A human reviews the archived plan and clicks approve before apply runs.

**What I learned:**
Separating plan and apply is standard practice for any infrastructure that matters. The approval gate exists because Terraform changes are often irreversible — a deleted database doesn't come back. The plan is the safety check. The approval is the confirmation that someone actually read it.

---

## Issue 13: `.war` Path Hardcoded — Switched to Runtime Variable

**What happened:**
The Ansible copy task had the `.war` path hardcoded. This broke when the Jenkins workspace path was different in a new environment and when the file didn't exist yet at the time the playbook was written.

**What caused it:**
The `.war` file doesn't exist until Maven builds it during the Build stage. Its path includes `${WORKSPACE}` — a Jenkins environment variable that resolves to the actual workspace directory at runtime. This path is different per Jenkins installation and can't be known in advance.

**The fix:**
Passed the path to Ansible as a runtime variable using `-e`:

```groovy
stage('Deploy') {
    steps {
        sh """
        ansible-playbook -i ansible/inventory/aws_ec2.yml ansible/site.yml \
          -e "war_file=${WORKSPACE}/target/VotingApp.war"
        """
    }
}
```

Ansible receives `war_file` as a variable and uses it in the copy task:

```yaml
- name: Deploy application
  ansible.builtin.copy:
    src: "{{ war_file }}"
    dest: /usr/share/tomcat/webapps/VotingApp.war
```

**What I learned:**
Runtime values — things that only exist after a previous step runs or that change between environments — should be passed at runtime, not hardcoded. The same principle as Secrets Manager: credentials aren't hardcoded because they change. The `.war` path isn't hardcoded because it only exists after the build and the path changes per environment.

---

## Issue 14: Static `hosts.ini` Can't Handle Dynamic Infrastructure — Switched to AWS Dynamic Inventory

**The problem:**
Terraform creates EC2 instances with IP addresses that aren't known until `terraform apply` completes. Even if you added a step to write the IP to `hosts.ini` after Terraform runs, the file would be wrong the next time infrastructure was rebuilt with different IPs. With two EC2 instances behind an Auto Scaling Group, the IPs could change at any time — not just during pipeline runs.

**The fix:**
Replaced `hosts.ini` with the `amazon.aws.aws_ec2` dynamic inventory plugin:

```yaml
# ansible/inventory/aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
filters:
  tag:Environment: dev
  instance-state-name: running
hostnames:
  - private-ip-address
```

At runtime, Ansible queries the AWS API, finds all running instances tagged `Environment: dev`, and builds the inventory automatically. No hardcoded IPs. No file to maintain.

**What I learned:**
Dynamic inventory is the correct approach for cloud infrastructure where instance IPs aren't fixed. Static inventory files are maintenance burden in any environment where instances are created and destroyed by automation. If Terraform is managing your EC2 instances, Ansible should be discovering them dynamically — not reading a file that was accurate when it was written but may not be now.

---

## Issue 15: `agent any` — What It Means and Why It Matters

**What I had to work through:**
The Jenkinsfile starts with `agent any` and I wasn't sure what it did or whether it mattered.

**How it works:**
Jenkins can have multiple agent machines (also called nodes or workers) available to run pipeline jobs. `agent any` tells Jenkins to run the pipeline on whichever agent is available. If only one agent exists, it always uses that one. If multiple agents exist, Jenkins picks any free one.

```groovy
pipeline {
    agent any  // run on any available agent
    stages {
        // ...
    }
}
```

**What I learned:**
For a single-machine setup, `agent any` is fine. In larger setups with multiple agents, you'd specify `agent { label 'terraform' }` to ensure the pipeline runs on an agent that has the right tools installed. `agent any` is the simple starting point — just be aware it assumes all agents have the same tools available.

---

## Issue 16: Jenkins vs Ansible — Which Tool Does What

**What I had to work through:**
It wasn't immediately clear where Jenkins ended and Ansible began, or why both were needed.

**How they fit together:**

```
Jenkins = the coordinator
  - Triggers when code is pushed
  - Runs the pipeline stages in order
  - Calls other tools (Maven, Terraform, Ansible, security scanners)
  - Decides what runs and when

Ansible = the server configurator
  - Called BY Jenkins
  - SSHes into EC2 instances
  - Installs software, copies files, manages services
  - Jenkins doesn't configure servers — it tells Ansible to
```

Jenkins orchestrates. Ansible executes. Jenkins is not a configuration management tool — it's a pipeline automation tool that calls configuration management tools.

**What I learned:**
Each tool has one job. Mixing them up — trying to configure servers from Jenkins directly using shell commands, or trying to build the pipeline logic in Ansible — creates fragile automation that's hard to maintain. Jenkins calls Ansible. Ansible configures the server. That separation is intentional.

---

## Issue 17: `sh` in Jenkinsfile — How It Maps to Terminal Commands

**What I had to work through:**
The Jenkinsfile uses `sh '...'` throughout and it wasn't clear exactly what that meant or how it related to what you'd type in a terminal.

**How it works:**
`sh` in a Jenkinsfile tells Jenkins to open a terminal on the agent machine and run the command inside the quotes. It's identical to SSHing into the server and typing the command manually — Jenkins just does it automatically as part of the pipeline.

```groovy
sh 'mvn package'         // same as typing: mvn package
sh 'terraform fmt -check' // same as typing: terraform fmt -check
sh 'checkov -d .'        // same as typing: checkov -d .
```

Any command that works in a terminal on the Jenkins machine works inside `sh '...'`.

**What I learned:**
If you can run a command in a terminal, you can put it in `sh '...'` in a Jenkinsfile. The Jenkins machine must have the tool installed — `sh 'terraform ...'` fails if Terraform isn't installed on the Jenkins EC2. The pipeline is only as capable as the tools available on the machine running it.

---

## Issue 18: Everything Runs on the Same EC2 — Why Amazon Linux Commands Matter

**What I had to work through:**
I wasn't sure why the instructions for installing tools on Jenkins specified Amazon Linux commands (`yum`) rather than the more commonly documented Ubuntu commands (`apt`).

**How it works:**
Jenkins runs on an EC2 instance. That EC2 instance runs Amazon Linux as its operating system. When the Jenkins pipeline runs `sh 'yum install terraform'`, it's running that command on the Amazon Linux EC2 — not on some separate machine.

```
EC2 instance = Amazon Linux OS
    └── Jenkins = program running on that OS
          └── Pipeline = runs commands on that same OS
                └── Tools (Terraform, Ansible, checkov) = installed on that same OS
```

Everything runs on the same machine. Amazon Linux uses `yum`. Ubuntu uses `apt`. Using the wrong package manager fails immediately.

**What I learned:**
Before installing any tool in an Ansible role or pipeline script, confirm which OS the target machine runs and which package manager it uses. Amazon Linux → `yum`. Ubuntu/Debian → `apt`. The installation commands in official documentation often default to Ubuntu — always verify against your actual OS.

---

## Issue 19: `-input=false` — Prevents Terraform From Hanging in CI

**What I had to work through:**
Terraform commands in the pipeline occasionally hung indefinitely waiting for input that never came.

**What caused it:**
Terraform prompts for confirmation or missing variable values when run interactively. In a CI/CD pipeline, there's no human to provide input — Terraform waits indefinitely and the pipeline hangs.

**The fix:**
Added `-input=false` to all Terraform commands in the pipeline:

```groovy
sh 'terraform -chdir=terraform/ plan -input=false -out=tfplan.txt'
sh 'terraform -chdir=terraform/ apply -input=false -auto-approve tfplan.txt'
```

`-input=false` tells Terraform to fail immediately if it needs input rather than waiting for it. This converts a silent hang into a visible failure — which is much easier to debug.

**What I learned:**
Any tool that can prompt for interactive input will hang a CI/CD pipeline if not told otherwise. Always check whether a tool has a non-interactive flag and use it in pipeline commands. For Terraform: `-input=false`. For apt: `-y`. For pip: `--yes`. A hung pipeline looks like it's running — it produces no output and doesn't fail, which makes it harder to diagnose than an immediate failure.

---

## Issue 20: Single Dash vs Double Dash — Terraform vs tflint Flag Conventions

**What I had to work through:**
Terraform uses `-chdir` (single dash) but tflint uses `--chdir` (double dash). Using the wrong one for either tool produces a confusing error.

**Why they're different:**
Different tools follow different conventions. Terraform follows Go's flag convention (single dash). tflint follows the POSIX/GNU convention (double dash for long flags). There's no universal standard across CLI tools.

```groovy
// Terraform — single dash
sh 'terraform -chdir=terraform/ plan'

// tflint — double dash
sh 'tflint --chdir=terraform/'
```

**What I learned:**
When a flag that worked for one tool doesn't work for another, check the tool's own documentation rather than assuming the convention is universal. Most tools print usage help with the correct flag format when you run them with `--help`.

---

## Issue 21: `${WORKSPACE}` — Why the `.war` Path Must Be Passed at Runtime

**What I had to work through:**
I wasn't sure why the `.war` file path couldn't just be hardcoded somewhere.

**Why it can't be hardcoded:**
`${WORKSPACE}` is a Jenkins environment variable that resolves to the actual workspace directory path at runtime. That path looks something like `/var/lib/jenkins/workspace/VotingApp/` — but it's different per Jenkins installation, per job name, and per environment.

More importantly, `target/VotingApp.war` doesn't exist until the Build stage runs Maven. You can't reference a file path for a file that doesn't exist yet. The path must be constructed and passed at the moment the Deploy stage runs — after the file has been created.

```groovy
// ${WORKSPACE} resolves at runtime to the actual path
sh "ansible-playbook ... -e 'war_file=${WORKSPACE}/target/VotingApp.war'"
```

**What I learned:**
Runtime values are for things that change between environments or don't exist until a previous step runs. Hardcoded values are for things that never change. The `.war` path is a runtime value because it depends on where Jenkins is installed and when Maven finishes. The same principle applies everywhere in the pipeline — if a value can change, don't hardcode it.

---

## Issue 22: Pre-Commit Hooks and Pipeline Scans Are Two Separate Things

**What I had to work through:**
I initially thought setting up security scans in the pipeline meant I didn't also need pre-commit hooks — or vice versa.

**Why both are needed:**

**Pre-commit hooks** run locally before every `git commit`:
- Fast — runs in seconds
- Catches problems before they reach the repository
- Only the developer sees the failure
- Prevents secrets and misconfigurations from ever being committed

**CI pipeline scans** run in Jenkins on every push:
- Runs on the shared codebase after code is pushed
- Catches problems that slipped past the pre-commit hook
- Visible to the whole team
- Provides a centralized quality gate

They serve different purposes at different points:
```
Developer commits code
    ↓
Pre-commit hook runs (local, fast, first line of defense)
    ↓
Code pushed to GitHub
    ↓
Jenkins pipeline runs (centralized, comprehensive, second line of defense)
```

**What I learned:**
Pre-commit hooks and CI scans are not redundant — they're complementary. Pre-commit hooks catch problems immediately with a fast feedback loop. CI scans catch anything that slipped through and provide a shared quality gate. Removing either one creates a gap. Both need to be set up and both need to actually be tested to confirm they work.

---

## Issue 23: `shell` Module Can Be Made Idempotent With `creates` Flag

**What I had to work through:**
tflint is a Go binary with no package manager — `yum install tflint` doesn't work. The only option is to download and install it using shell commands. But shell isn't idempotent.

**The fix:**
Used the `creates` argument to make the shell task idempotent:

```yaml
- name: Install tflint
  ansible.builtin.shell: |
    curl -L https://github.com/terraform-linters/tflint/releases/download/v0.50.0/tflint_linux_amd64.zip \
    -o /tmp/tflint.zip && \
    unzip /tmp/tflint.zip -d /usr/local/bin/
  args:
    creates: /usr/local/bin/tflint  # skip if this file already exists
```

`creates: /usr/local/bin/tflint` tells Ansible: "if this file already exists, skip the task." The task only runs if tflint isn't already installed.

**What I learned:**
Shell can be idempotent — just not automatically. When you have to use shell, add `creates` (skip if file exists) or `removes` (skip if file doesn't exist) to make it behave like a proper module. `/usr/local/bin/` is the standard location for manually installed binaries on Linux — not managed by any package manager, just placed there directly.

---

## Issue 24: Config Files Need to Be in the Repo, Not Configured on the Server

**What I had to work through:**
My first instinct for tool configuration was to set it up on the Jenkins server directly. This worked once but broke when the infrastructure was rebuilt.

**Why server-only configuration breaks:**
If a tool is configured manually on a server:
- Rebuilding the server loses the configuration
- A new team member cloning the repo can't replicate the environment
- The pipeline behaves differently on different machines
- There's no record of what configuration was applied

**The fix:**
Committed all config files to the repository:

```
.secrets.baseline          # detect-secrets known state
terraform/.tflint.hcl      # tflint AWS ruleset config
.pre-commit-config.yaml    # pre-commit hook definitions
ansible/ansible.cfg        # Ansible connection settings
```

The pipeline uses these files directly from the repository — no server-specific configuration needed.

**What I learned:**
Everything that controls how a tool behaves should be in the repository. If someone clones the repo and runs the pipeline, it should work identically to how it works in any other environment. Config files in the repo make that possible. Config files only on the server make it impossible.

---

## General Takeaways

**The pipeline is only as good as the tools installed on it.**
Every `sh '...'` command in the Jenkinsfile requires that tool to be installed on the Jenkins EC2. If the tool isn't there, the command fails. Before adding a new tool to the pipeline, add its installation to the Ansible Jenkins role so it's installed automatically when the server is configured.

**Security scans belong before infrastructure, not after.**
Running checkov and tflint after `terraform apply` means you're scanning infrastructure that's already been created — possibly with misconfigurations already in place. Running scans before apply means a failing scan stops the pipeline before any AWS costs are incurred or any insecure resources exist.

**Test the pipeline by breaking it intentionally.**
The pre-commit hooks and pipeline scans are only useful if they actually catch things. After setting them up, test them by intentionally introducing a violation — a fake secret, an unformatted Terraform file, a missing tflint config. If the hook doesn't catch it, the hook isn't working. Don't assume it works because it's configured.

**Separate plan and apply. Always.**
In any environment where Terraform manages real infrastructure, plan and apply should be separate stages with a review step between them. `terraform apply` without reviewing the plan first is how databases get accidentally deleted.