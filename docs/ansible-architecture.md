# Ansible Configuration Management — Architecture Document
### 2-Tier AWS Infrastructure (VotingApp)

---

## Why Ansible

Ansible was chosen over alternatives like Chef or Puppet for one specific reason: it is agentless. The EC2 application server lives in a private subnet with no direct internet exposure. An agent-based tool would require either opening additional inbound ports or running a management daemon on every instance — both of which increase attack surface. Ansible connects over SSH using the existing pipeline connection. No additional ports. No additional processes running on the server.

The secondary reason is declarative state. Tasks define what the server should look like, not the sequence of commands to get it there. This makes the playbooks idempotent — running them twice produces the same result as running them once. That property matters in a CI/CD context where a failed deployment might be retried automatically.

---

## Control Node and Managed Nodes

The pipeline runner (Jenkins) acts as the Ansible control node. It SSHes into the EC2 instance after Terraform provisions it and runs the playbook against it.

| Role | Machine |
|------|---------|
| Control node | Jenkins runner (executes `ansible-playbook`) |
| Managed node | EC2 application server (private subnet) |

The EC2 instance never initiates a connection outward for configuration purposes. The control node connects inward over SSH. This is consistent with the principle of least exposure — the managed node has no management-plane ports open beyond what SSH requires.

---

## Role Structure

Roles separate concerns. Each role owns exactly one responsibility and can be reused across environments without modification.

```
ansible/
├── roles/
│   ├── common/       # Base dependencies: git, curl, wget, unzip
│   ├── app_server/   # Tomcat install, credential injection, .war deployment
│   └── jenkins/      # Jenkins install and service configuration
└── site.yml          # Orchestrates which roles run on which hosts
```

The `site.yml` playbook is the only place where `hosts:` and `become: true` are declared. Role task files contain tasks only — no playbook wrapper. This keeps roles portable and prevents privilege escalation from being buried inside a role where it is easy to miss.

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

## Secrets Retrieval — How It Actually Works

The EC2 instance has an IAM role attached with `secretsmanager:GetSecretValue` permission scoped to the specific secret ARN. When Ansible runs on the EC2 instance, boto3 (the AWS SDK for Python) automatically picks up the instance's temporary IAM credentials from the EC2 metadata service. No `aws configure`. No environment variables. No access keys anywhere.

```yaml
- name: Fetch database credentials from Secrets Manager
  ansible.builtin.set_fact:
    db_creds: "{{ lookup('amazon.aws.secretsmanager_secret', 'prod/db/credentials') | from_json }}"
```

- `lookup(...)` — fetches the secret as a raw JSON string
- `| from_json` — parses it into an Ansible variable dict
- `set_fact` — stores the result for use in subsequent tasks

Credentials are stored as JSON in Secrets Manager so a single secret holds all related values (host, username, password, port, database name) rather than creating separate secrets for each field. This also means rotation updates one secret, not five.

**`no_log: true` is set on every task that touches credentials.** Without it, Ansible prints task output to logs — including variable values. One missed `no_log` directive is enough to write a plaintext password to a CI/CD log file.

---

## Credential Injection — The setenv.sh Approach

Tomcat reads `setenv.sh` once at startup and loads all exported variables into its process environment. The application reads them from there on every database connection.

A Jinja2 template generates `setenv.sh` dynamically from the values retrieved out of Secrets Manager:

```jinja2
export DB_HOST={{ db_creds.host }}
export DB_USER={{ db_creds.username }}
export DB_PASSWORD={{ db_creds.password }}
export DB_NAME={{ db_creds.dbname }}
```

The rendered file is written to `/usr/share/tomcat/bin/setenv.sh` with mode `0600` — owner read/write only. No other process on the instance can read it.

The field names in the template (`db_creds.host`, `db_creds.username`, etc.) must exactly match the JSON key names stored in the Secrets Manager secret. A mismatch renders empty values silently — the app starts, connects to nothing, and fails in a way that looks like a network issue rather than a credential issue.

---

## app_server Role — Task Sequence and Rationale

Order matters here. Each task depends on the previous one completing successfully.

| Step | Task | Why |
|------|------|-----|
| 1 | Install Tomcat via `yum` | Application runtime must exist before anything else |
| 2 | Start Tomcat, enable on boot | Service must be running before deploying to it |
| 3 | Fetch credentials from Secrets Manager | Credentials must exist before the template can render |
| 4 | Render `setenv.sh` from template | Environment file must exist before Tomcat can use it |
| 5 | Copy `.war` file to `/usr/share/tomcat/webapps/` | Application binary must be present before restart |
| 6 | Restart Tomcat | Forces Tomcat to reload `setenv.sh` and serve the new `.war` |

Step 6 is the one people miss. Tomcat reads `setenv.sh` at startup only. Deploying a new `.war` does not trigger a credential reload. Without the explicit restart, an updated secret would not take effect until the next unrelated restart — which in production might be weeks away.

---

## jenkins Role — Task Sequence and Rationale

Jenkins is not in the default Amazon Linux repositories. The role adds the official Jenkins repository before attempting to install, following the same pattern you would use for any software not in the default package manager.

| Step | Task | Why |
|------|------|-----|
| 1 | Install Java | Jenkins is a Java application — it will not start without a JVM |
| 2 | Add Jenkins yum repo via `get_url` | Package manager cannot find Jenkins without knowing where to look |
| 3 | Import Jenkins GPG key | Package manager will reject unsigned packages without the key |
| 4 | Install Jenkins | Now that the repo and key exist, `yum install jenkins` succeeds |
| 5 | Start Jenkins, enable on boot | Service must be running for the pipeline to use it |

The GPG key step is the one most tutorials skip. Without it, `yum` will prompt interactively for confirmation — which hangs a non-interactive CI/CD pipeline indefinitely.

---

## Credential Rotation — Known Limitation

Tomcat reads `setenv.sh` once at startup. If AWS Secrets Manager rotates the database password automatically, the following happens:

1. AWS updates the secret value
2. RDS accepts the new password
3. Tomcat is still holding the old password in memory
4. Every database connection attempt fails until Tomcat restarts

This is a real operational gap. Two remediation approaches:

**Option A — Lambda-triggered restart:** A Lambda function subscribed to the Secrets Manager rotation event SSHes into EC2 and restarts Tomcat. Simple, but requires Lambda + SSM access to the instance.

**Option B — Runtime credential fetch:** The application calls Secrets Manager on every database connection instead of reading from environment variables. Always uses the current secret. Adds latency and requires application code changes.

This project uses Option A as the intended path. Automatic rotation is configured in Secrets Manager but the Lambda trigger was not implemented in the current scope — noted as a future improvement.

---

## How the .war File Reaches the Server

The compiled application binary does not live in the repository. It is produced by the CI/CD pipeline and handed off to Ansible for deployment.

```
Developer pushes code to GitHub
        ↓
Jenkins pulls source code
        ↓
Jenkins runs: mvn package
        ↓
Maven compiles and produces: target/VotingApp.war
        ↓
Ansible copies .war from Jenkins runner to EC2
        ↓
Tomcat serves the application
```

The `ansible.builtin.copy` module transfers the file from the control node (Jenkins runner) to the managed node (EC2). `src` is where the file is after the Maven build. `dest` is where Tomcat looks for deployable applications.

---

## File Permission Decisions

| File | Mode | Reason |
|------|------|--------|
| `setenv.sh` | `0600` | Contains database credentials — owner read/write only |
| `.war` file | `0644` | No sensitive content — Tomcat needs to read it |
| Ansible playbooks | Default | Source-controlled, no secrets ever written to them |

`0600` on `setenv.sh` is not optional. On a shared EC2 instance, any process running as a different user could read a `0644` secrets file. The IAM role already limits who can retrieve the secret from AWS — `0600` limits who can read it once it has been written to disk.

---

## Security Controls Applied

| Control | Implementation |
|---------|---------------|
| No static credentials | IAM role on EC2 instance; boto3 uses instance metadata |
| No secrets in logs | `no_log: true` on all credential-handling tasks |
| No secrets in files (at rest) | `setenv.sh` generated at runtime from Secrets Manager, `0600` permissions |
| No secrets in repo | detect-secrets pre-commit hook + `.secrets.baseline` |
| Least privilege | IAM role scoped to specific secret ARN, not `secretsmanager:*` |