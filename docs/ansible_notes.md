# Ansible — Configuration Management Notes
### 2-Tier AWS Project (VotingApp)

---

## What is Ansible?

Ansible is an open-source automation tool used to configure servers, install software, and deploy applications. It is **agentless** — meaning no software needs to be installed on the servers you manage. It connects over SSH.

Ansible is **declarative**: you define *what the final state should be*, not *how to get there*. For example, you don't write "run this command to install Apache" — you write "Apache should be installed."

---

## Control Node vs. Managed Nodes

The playbook YAML itself doesn't define which machine is the control node or the managed nodes. Ansible learns this from two things:

| Concept | Definition |
|---|---|
| **Control node** | The machine where you run `ansible-playbook` (your local machine or a CI/CD runner) |
| **Managed nodes** | The servers listed in your **inventory file** — these are the machines Ansible configures |

---

## Inventory File

The inventory file tells Ansible which servers to connect to and how to reach them. At minimum it contains the IP address or hostname of your managed nodes.

```ini
[app_servers]
ec2-1.compute.amazonaws.com

[jenkins]
ec2-2.compute.amazonaws.com
```

---

## Ansible Roles

Roles are a way to organize playbooks into reusable units. Each role handles one concern (e.g., installing Jenkins, configuring the app server).

```
roles/
  app_server/
    tasks/
    vars/
    defaults/
    handlers/
    meta/
    files/
    templates/
  jenkins/
    tasks/
    ...
  common/
    tasks/
    ...
```

**Key rule:** No `hosts:` or `become:` inside a role's `tasks/main.yml`. Those belong in `site.yml` (the main playbook). Inside a role you write tasks directly — no playbook wrapper.

---

## The Main Playbook (site.yml)

The main playbook orchestrates all roles:

```yaml
- hosts: app_servers
  become: true
  roles:
    - common
    - app_server

- hosts: jenkins
  become: true
  roles:
    - common
    - jenkins
```

---

## Common Ansible Modules

| Goal | Module |
|---|---|
| Install a package | `ansible.builtin.yum` / `ansible.builtin.apt` |
| Start or stop a service | `ansible.builtin.service` |
| Copy a local file to server | `ansible.builtin.copy` |
| Download a file from the internet | `ansible.builtin.get_url` |
| Clone a Git repository | `ansible.builtin.git` |
| Run a shell command | `ansible.builtin.shell` / `ansible.builtin.command` |
| Manage Linux users | `ansible.builtin.user` |
| Render a template file | `ansible.builtin.template` |
| Set a variable at runtime | `ansible.builtin.set_fact` |

> **Best practice:** Always use the fully qualified module name (e.g., `ansible.builtin.yum` not just `yum`) to avoid ambiguity.

---

## The `state` Keyword

`state` tells Ansible what condition you want a resource to be in. This is what makes Ansible declarative.

```yaml
- name: Install Apache
  ansible.builtin.yum:
    name: httpd
    state: present   # ensure it is installed

- name: Start Apache
  ansible.builtin.service:
    name: httpd
    state: started   # ensure it is running
    enabled: true    # ensure it starts on boot
```

---

## Templates (Jinja2)

Ansible templates let you generate config files dynamically with variables filled in at runtime. You write a `.j2` file — Ansible generates the real file on the server.

**You only write the `.j2` — Ansible creates the actual file automatically.**

**Example — `.env.j2` template:**

```jinja2
export DB_HOST={{ db_creds.host }}
export DB_USER={{ db_creds.username }}
export DB_PASSWORD={{ db_creds.password }}
export DB_NAME={{ db_creds.dbname }}
```

**Example — task to render it:**

```yaml
- name: Create environment file
  ansible.builtin.template:
    src: templates/.env.j2
    dest: /usr/share/tomcat/bin/setenv.sh
    mode: '0600'
```

The field names in the template (e.g., `.host`, `.username`) must exactly match the field names stored in your secret in AWS Secrets Manager.

---

## File Permissions (mode)

| Situation | Mode |
|---|---|
| File contains secrets | `0600` — owner read/write only |
| Regular config file, no secrets | `0644` — everyone can read |
| Executable script | `0755` — everyone can execute |

---

## AWS Secrets Manager Integration

### Why secrets are stored as JSON

A single secret in AWS Secrets Manager can hold multiple values (host, username, password, port, database name). JSON bundles all related credentials into one secret instead of creating a separate secret for each field.

When fetched, you receive one JSON string and parse it to extract individual values.

### How Ansible retrieves secrets

Ansible uses **lookup plugins** to dynamically fetch data from external sources at runtime. The `amazon.aws.secretsmanager_secret` lookup plugin connects to AWS Secrets Manager and retrieves the secret.

```yaml
- name: Fetch database credentials
  ansible.builtin.set_fact:
    db_creds: "{{ lookup('amazon.aws.secretsmanager_secret', 'prod/db/credentials') | from_json }}"
```

- `lookup(...)` — fetches the secret value as a raw JSON string
- `| from_json` — parses the string into a usable Ansible variable
- `set_fact` — stores the parsed result as a variable for use in later tasks

> **Important:** Install the `amazon.aws` collection via `ansible-galaxy` before using this lookup plugin.

### IAM Role — no credentials needed

When your EC2 instance has an IAM role attached, AWS automatically provides temporary credentials. Ansible (via `boto3`) picks these up automatically. You do not need to run `aws configure`, set environment variables, or hardcode any keys.

**The flow is:**

```
Ansible SSHes into EC2
        ↓
Runs AWS CLI / boto3 command
        ↓
EC2's IAM role grants permission to Secrets Manager
        ↓
Secret is returned
```

Ansible is the messenger. The EC2 is the one actually talking to Secrets Manager.

> **Best practice:** Always add `no_log: true` to tasks that handle secrets to prevent sensitive data from appearing in Ansible output logs.

---

## The `register` Keyword

`register` captures the output of a task and stores it in a variable for use in later tasks.

```yaml
- name: Fetch secret
  ansible.builtin.shell: >
    aws secretsmanager get-secret-value
    --secret-id MY_SECRET
    --query SecretString
    --output text
  register: secret_raw
```

Breaking down the AWS CLI command:
- `get-secret-value` — retrieves the secret contents
- `--secret-id MY_SECRET` — the name or ARN of the secret
- `--query SecretString` — extracts only the secret value, filtering out metadata
- `--output text` — returns plain text, removing JSON formatting and quotes

---

## Variable Precedence

Ansible has a priority system for variables (lowest → highest):

1. `defaults/main.yml` — easily overridden, meant for default values
2. `group_vars/` — variables shared across groups of hosts
3. `host_vars/` — variables specific to one host
4. `vars:` in the playbook
5. `-e` extra vars at the command line — highest priority

---

## `group_vars`

`group_vars` lets you define variables once and reuse them across multiple hosts or groups, keeping your playbooks clean and DRY.

---

## app_server Role — Full Task List

These are the tasks required to configure the EC2 instance to run the VotingApp:

1. Install Tomcat (`yum`)
2. Start Tomcat and enable on boot (`service`)
3. Fetch and parse database credentials from Secrets Manager (`set_fact` + `lookup`)
4. Create `setenv.sh` environment file from template so Tomcat loads credentials at startup (`template`)
5. Copy the built `.war` file to the server (`copy`)
6. Restart Tomcat so it picks up new credentials and the deployed app (`service`)

**Note on Tomcat install path:**
- Installed via `yum install tomcat` → `/usr/share/tomcat/bin/setenv.sh`
- Installed manually → typically `/opt/tomcat/bin/setenv.sh`

---

## jenkins Role — Full Task List

1. Install Java (Jenkins dependency)
2. Add the Jenkins yum repository using `get_url`
   - URL: `https://pkg.jenkins.io/redhat-stable/jenkins.repo`
   - Destination: `/etc/yum.repos.d/jenkins.repo`
3. Import the Jenkins GPG key
4. Install Jenkins (`yum`)
5. Start Jenkins and enable on boot (`service`)

> **Why add the repo first?** Jenkins is not in the default Amazon Linux repositories. You must tell the system where to find it before you can install it.

**The pattern for any new software:**
1. Find the official installation docs
2. Locate the exact commands they provide
3. Translate those shell commands into Ansible tasks

---

## How the `.war` File Gets to the Server

The `.war` (Web Application Archive) is the compiled, packaged version of the Java app. It does not exist in the repository — it is built by the CI/CD pipeline.

```
Developer pushes code to GitHub
        ↓
Jenkins pulls the code
        ↓
Jenkins runs: mvn package
        ↓
Maven compiles Java and produces: target/VotingApp.war
        ↓
Ansible copies .war to EC2
        ↓
Tomcat serves the application
```

The `ansible.builtin.copy` module copies files from the Ansible control node to the remote managed node.

```yaml
- name: Deploy application
  ansible.builtin.copy:
    src: target/VotingApp.war
    dest: /usr/share/tomcat/webapps/VotingApp.war
```

- `src` — where the file is now (on the Ansible/Jenkins machine)
- `dest` — where it needs to go (on the EC2 server)

---

## How Tomcat Handles Credentials

Tomcat reads `setenv.sh` **once at startup** and loads all `export` variables into memory. It uses those credentials for every database connection until it is restarted.

```bash
export DB_PASSWORD=secret123
```

`export` makes the variable available to external processes (like your Java app). Without `export`, the variable stays private to the shell script and Tomcat cannot see it.

**Rule of thumb:**
- Another app needs to read it → use `export`
- Only the script itself needs it → no `export` needed

### Credential Rotation Warning

If you enable automatic secret rotation in AWS Secrets Manager:
- AWS updates the password and RDS gets the new value
- But Tomcat is still holding the old password in memory
- The app will fail to connect

**Solutions:**
- **Option 1:** Trigger a Lambda on rotation that SSHes into EC2 and restarts Tomcat
- **Option 2:** Have the app call Secrets Manager dynamically on every database connection (more complex, always fresh)

---

## Security Best Practices Applied

- No secrets in code, config files, or the Git repository
- All credentials stored in AWS Secrets Manager only
- EC2 uses an IAM role — no static AWS credentials anywhere
- `setenv.sh` uses file mode `0600` (owner-only access)
- `no_log: true` on tasks that handle secrets
- Pre-commit hooks (`detect-secrets`, `checkov`, `tflint`) block accidental secret commits

---

## Core Principle — DRY (Don't Repeat Yourself)

| Practice | How it applies |
|---|---|
| Define rules once | `.gitignore`, security groups, IAM policies |
| Set up automation once | CI/CD pipeline handles all future deploys |
| Secure things once | Secrets Manager + IAM role |
| Write automation once | Ansible roles are reusable across environments |

---

## Full Pipeline Flow

```
Code pushed to GitHub
        ↓
CI/CD pipeline starts
        ↓
Terraform provisions EC2 and RDS
        ↓
Pipeline retrieves EC2 IP
        ↓
Ansible runs and configures EC2
        ↓
Jenkins is installed and running on EC2
        ↓
Jenkins handles all future builds and deployments
```

---

## Quick Reference — The 80/20 Workflow

1. Write your inventory file (server IP addresses)
2. Write your playbook (`site.yml`)
3. Use built-in modules to install, copy, and manage services
4. Use templates (`.j2`) for any file that needs dynamic values
5. Run: `ansible-playbook -i inventory site.yml`