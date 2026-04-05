# Troubleshooting Log & Build Notes
### 2-Tier AWS Infrastructure (VotingApp)

Real issues encountered during the build — what broke, what caused it, and how it was fixed. Documented so the next person working on this doesn't have to figure it out from scratch.

---

## Issue 1: Application Could Not Connect to Database — Credentials Were Empty

**What happened:**
Tomcat started successfully and the application deployed without errors. But every database connection failed. No credential error was logged — just a connection failure.

**What caused it:**
The Terraform secret was configured to store the database password as a plain string instead of a JSON object. When Ansible fetched the secret and ran `| from_json` on it, there was nothing to parse — so every field in the template (`db_creds.host`, `db_creds.username`, `db_creds.password`) came out blank. Tomcat loaded `setenv.sh` with empty values and started fine. The failure only showed up when the app tried to actually connect to the database.

**The fix:**
Changed the Terraform secret to store credentials as a JSON object:

```hcl
secret_string = jsonencode({
  username = "admin"
  password = var.db_password
  host     = aws_db_instance.rds_instance.address
  port     = 3306
  dbname   = "votingapp"
})
```

`aws_db_instance.rds_instance.address` pulls the RDS endpoint automatically after Terraform creates the database — no hardcoding needed.

**What I learned:**
The field names in the Secrets Manager JSON have to exactly match the field names in the Jinja2 template. If the secret has `username` but the template says `db_creds.user`, the template renders blank silently — no error. I now define the JSON structure in Terraform first, then write the template to match it.

---

## Issue 2: setenv.sh Was Written to the Wrong Path

**What happened:**
Same symptom as Issue 1 — Ansible ran successfully, Tomcat started, application couldn't connect to the database. This time the credentials in Secrets Manager were correct.

**What caused it:**
The template task was writing `setenv.sh` to `/opt/tomcat/bin/setenv.sh`. But because the role installed Tomcat using `yum`, Tomcat was actually installed under `/usr/share/tomcat/` — not `/opt/tomcat/`. Ansible wrote the file to a path that existed but that Tomcat never looked at. Tomcat started without finding any `setenv.sh`, loaded no credentials, and the app failed to connect.

Tomcat's location depends on how it was installed:

| Install method | Correct path |
|---------------|-------------|
| `yum install tomcat` | `/usr/share/tomcat/bin/setenv.sh` |
| Manual install | `/opt/tomcat/bin/setenv.sh` |

**The fix:**
```yaml
- name: Create environment file
  ansible.builtin.template:
    src: templates/.env.j2
    dest: /usr/share/tomcat/bin/setenv.sh
    mode: '0600'
```

**What I learned:**
Ansible writes files wherever you tell it to — it doesn't check whether the destination makes sense to the application. When a deployment looks successful but the app behaves wrong, check whether config files landed where the application actually looks for them.

---

## Issue 3: Credential Rotation Would Break the Running Application

**What happened:**
This wasn't a runtime failure — I caught it as a design gap while building.

**The problem:**
Tomcat reads `setenv.sh` once at startup and keeps the credentials in memory. If AWS Secrets Manager rotates the database password automatically, AWS updates the secret and RDS accepts the new password — but Tomcat is still using the old one. The app would start failing to connect until Tomcat was restarted.

**Two ways to handle it:**

Option A — Restart Tomcat when rotation happens: Set up a Lambda function that triggers when the secret rotates and restarts Tomcat so it reloads `setenv.sh` with the new credentials.

Option B — Have the app fetch credentials at runtime: Change `DBConnection.java` to call Secrets Manager directly on every connection instead of reading environment variables. More complex but handles rotation automatically.

**Current state:**
Rotation is configured in Secrets Manager. The Lambda trigger isn't implemented yet — noted as a future improvement.

**What I learned:**
Enabling rotation isn't just a Secrets Manager setting — every system that uses the secret needs to be able to handle the credential changing. Tomcat's startup-only credential loading means rotation without a restart mechanism will cause an outage.

---

## Issue 4: Environment Variables Set But Tomcat Couldn't See Them

**What happened:**
`setenv.sh` was written to the correct path with the correct values. Tomcat started. `System.getenv("DB_HOST")` in the Java app returned null.

**What caused it:**
The variables in `setenv.sh` were set without the `export` keyword:

```bash
DB_HOST=mydb.rds.amazonaws.com   # Tomcat can't see this
```

In bash, a variable without `export` stays private to the shell script that sets it. Tomcat runs `setenv.sh` as a child process — without `export`, the variable never enters Tomcat's environment. The Java app calls `System.getenv()` which reads Tomcat's environment, finds nothing, and returns null.

**The fix:**
```jinja2
export DB_HOST={{ db_creds.host }}
export DB_USER={{ db_creds.username }}
export DB_PASSWORD={{ db_creds.password }}
export DB_NAME={{ db_creds.dbname }}
```

**What I learned:**
Use `export` when another process needs to read the variable. Without it, the variable only exists inside the script itself. In `setenv.sh`, `export` is always needed because Tomcat is the one that needs to read the values.

---

## Issue 5: `hosts:` and `become:` Inside the Role Caused Parse Errors

**What happened:**
Ansible threw parse errors when running `site.yml`. The role task files looked fine but wouldn't parse correctly.

**What caused it:**
The role's `tasks/main.yml` had `hosts: app_servers` and `become: true` at the top — copied from the structure of a playbook. A role's task file is just a list of tasks, not a playbook. Ansible expects tasks in that file, not play-level directives. When it found `hosts:` where it expected a task, it threw a parse error.

**The fix:**
Removed `hosts:` and `become:` from all role task files. They belong in `site.yml`:

```yaml
# site.yml
- hosts: app_servers
  become: true
  roles:
    - common
    - app_server
```

Role task files only contain tasks — nothing else.

**What I learned:**
Roles define what to do. The playbook defines where and with what privileges. Keeping them separate is what makes roles reusable — the same role can be applied to different hosts by changing `site.yml` without touching the role itself.

---

## Issue 6: Jenkins Install Failed — Package Not Found

**What happened:**
The `ansible.builtin.yum` task to install Jenkins failed with "no package jenkins available."

**What caused it:**
Jenkins isn't in Amazon Linux's default package repositories. `yum` can only install packages from repositories it knows about. Without first adding the Jenkins repository, `yum` has no idea Jenkins exists.

**The fix:**
Added repository setup before the install task:

```yaml
- name: Add Jenkins repository
  ansible.builtin.get_url:
    url: https://pkg.jenkins.io/redhat-stable/jenkins.repo
    dest: /etc/yum.repos.d/jenkins.repo

- name: Import Jenkins GPG key
  ansible.builtin.rpm_key:
    key: https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
    state: present

- name: Install Jenkins
  ansible.builtin.yum:
    name: jenkins
    state: present
```

**What I learned:**
For any software not in the default repositories, you have to add the repository before you can install the package. The official installation docs always have the correct repository URL and GPG key — use those, not adapted examples from tutorials that might be outdated.

---

## Issue 7: Missing GPG Key Made the Pipeline Hang Silently

**What happened:**
The Jenkins repository was added correctly but I skipped the GPG key import. The install task didn't fail — it just ran forever without producing any output or completing.

**What caused it:**
Without the GPG key, `yum` can't verify the package signature and prompts "Is this ok [y/N]?" In a terminal you'd see the prompt. In a CI/CD pipeline there's no one to answer it — the task just waits indefinitely. The pipeline looked like it was running but was actually frozen.

**The fix:**
Added the GPG key import task before the install:

```yaml
- name: Import Jenkins GPG key
  ansible.builtin.rpm_key:
    key: https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
    state: present
```

**What I learned:**
If a pipeline job runs for a long time without any output and never finishes, it's usually waiting for interactive input that will never come. The GPG key step is easy to skip because it feels optional — it's not. Always import the key before installing from a third-party repository.

---

## Issue 8: Used the Wrong Module for Installation vs. Service Management

**What happened:**
Ansible threw errors about unexpected parameters — the module name looked right but the task wasn't working.

**What caused it:**
I used `ansible.builtin.yum` where I should have used `ansible.builtin.service` and vice versa. They're completely separate modules for completely different things:

- `yum` — installs or removes packages
- `service` — starts, stops, or enables services

They don't share parameters and can't substitute for each other.

**The fix:**
Two separate tasks — one to install, one to manage the service:

```yaml
- name: Install Tomcat
  ansible.builtin.yum:
    name: tomcat
    state: present

- name: Start Tomcat and enable on boot
  ansible.builtin.service:
    name: tomcat
    state: started
    enabled: true
```

**What I learned:**
Installing software and starting it are always two separate tasks in Ansible. Also — `enabled: true` is easy to forget but important. Without it, the service won't start automatically after a reboot.

---

## Issue 9: YAML Indentation Errors Broke Playbook Parsing

**What happened:**
Ansible threw errors like "mapping values are not allowed here" or "unexpected key." The error messages weren't obvious about what was wrong.

**What caused it:**
YAML is indentation-sensitive. A task or parameter indented at the wrong level gets interpreted as something different — a sub-key of the element above it instead of its own item. The error messages describe what Ansible found rather than pointing directly at the indentation problem.

Correct:
```yaml
- name: Install Tomcat
  ansible.builtin.yum:
    name: tomcat
    state: present
```

Incorrect (module indented one level too deep):
```yaml
- name: Install Tomcat
    ansible.builtin.yum:
      name: tomcat
      state: present
```

**The fix:**
Consistent 2-space indentation throughout. Used VS Code's YAML extension to catch issues before running the playbook.

**What I learned:**
When Ansible throws a parse error that isn't immediately obvious, check indentation first — especially around module names and parameters. A YAML linter catches these before you even run the playbook.

---

## Issue 10: Short Module Names Caused Ambiguity Warnings

**What happened:**
Deprecation warnings appeared when running the playbook. In some cases modules didn't resolve as expected.

**What caused it:**
Using short module names like `set_fact` or `yum` instead of fully qualified names like `ansible.builtin.set_fact`. When multiple collections are installed — including `amazon.aws` alongside the built-in modules — short names can be ambiguous. Ansible has to guess which collection you mean.

**The fix:**
Always use fully qualified module names:

```yaml
# before
- set_fact:
    db_creds: "{{ secret_raw.stdout | from_json }}"

# after
- ansible.builtin.set_fact:
    db_creds: "{{ secret_raw.stdout | from_json }}"
```

**What I learned:**
Fully qualified names remove any ambiguity about which collection a module comes from. It also makes the playbook easier to read — you know exactly where the module lives without checking installed collections.

---

## Issue 11: Lookup Plugin Not Found — Collection Wasn't Installed

**What happened:**
Ansible threw "lookup plugin not found: amazon.aws.secretsmanager_secret" even though the syntax was correct.

**What caused it:**
`amazon.aws` is an external collection — it doesn't come with Ansible by default. It has to be installed separately before any of its plugins can be used.

**The fix:**
```bash
ansible-galaxy collection install amazon.aws
```

Added a `requirements.yml` to the repo so the dependency is documented:

```yaml
collections:
  - name: amazon.aws
```

Then in the pipeline:
```bash
ansible-galaxy collection install -r requirements.yml
```

**What I learned:**
A plugin name with a dot-separated prefix like `amazon.aws.secretsmanager_secret` means it comes from an external collection that needs to be installed first. Putting it in `requirements.yml` means anyone cloning the repo knows what to install.

---

## Issue 12: boto3 Not Installed — AWS Lookup Failed at Runtime

**What happened:**
The `amazon.aws` collection was installed. The plugin was found. The task still failed with "boto3 required for this module."

**What caused it:**
The `amazon.aws` collection uses boto3 (AWS's Python SDK) under the hood to make API calls. Installing the Ansible collection doesn't install boto3 — they're separate packages. boto3 has to be installed on whatever machine is running `ansible-playbook`.

**The fix:**
```bash
pip install boto3
```

Added to the pipeline before the Ansible step:
```yaml
- name: Install boto3
  run: pip install boto3
```

**What I learned:**
Ansible collections that talk to cloud providers need the cloud provider's SDK installed separately. When a task fails with "[service] library required," the fix is a `pip install` on the machine running Ansible — not a change to the playbook.

---

## Issue 13: Wasn't Sure Where the .war File Would Be After the Build

**What happened:**
When writing the Ansible copy task, I wasn't sure where the `.war` file would exist on the Jenkins machine after Maven built it — or whether it needed to go through S3 first.

**How it works:**
Maven always puts build output in a `target/` folder inside the project directory. After Jenkins runs `mvn package`, the file is at `target/VotingApp.war` on the Jenkins machine. No S3 needed — `ansible.builtin.copy` can transfer it directly from Jenkins to EC2 over SSH.

**The fix:**
```yaml
- name: Deploy application
  ansible.builtin.copy:
    src: target/VotingApp.war
    dest: /usr/share/tomcat/webapps/VotingApp.war
```

`src` = where the file is on the machine running Ansible (Jenkins)
`dest` = where it needs to go on the EC2 instance

**What I learned:**
`ansible.builtin.copy` moves files from the machine running Ansible to the remote server. The Maven build always puts the `.war` in `target/` — that's standard Maven behavior, not project-specific.

---

## Issue 14: Task Output Wasn't Available to the Next Task

**What happened:**
A task fetched the raw secret from Secrets Manager. The next task tried to parse it but the variable was undefined.

**What caused it:**
I forgot to use `register` on the fetch task. In Ansible, each task runs independently — output isn't automatically shared between tasks. Without `register`, the secret was fetched and immediately thrown away.

**The fix:**
```yaml
- name: Fetch raw secret
  ansible.builtin.shell: >
    aws secretsmanager get-secret-value
    --secret-id prod/db/credentials
    --query SecretString
    --output text
  register: secret_raw
  no_log: true

- name: Parse secret
  ansible.builtin.set_fact:
    db_creds: "{{ secret_raw.stdout | from_json }}"
  no_log: true
```

`secret_raw.stdout` holds the text output of the shell command.

**What I learned:**
Any time you need output from one task in a later task, use `register` to capture it. And always add `no_log: true` to tasks that handle secrets — without it, Ansible prints the output including the secret value to the console and pipeline logs.

---

## Issue 15: Credentials Showed Up in Plaintext in the Pipeline Log

**What happened:**
During early runs, the database password appeared in plaintext in the Ansible output and in the Jenkins pipeline log.

**What caused it:**
Ansible logs task parameters and registered variable contents by default. Without `no_log: true`, a task that fetches or stores a secret will print it to whatever log is capturing the output.

**The fix:**
Added `no_log: true` to every task in the credential chain — not just the fetch:

```yaml
- name: Fetch credentials
  ansible.builtin.shell: ...
  register: secret_raw
  no_log: true

- name: Parse credentials
  ansible.builtin.set_fact:
    db_creds: "{{ secret_raw.stdout | from_json }}"
  no_log: true

- name: Render credential file
  ansible.builtin.template:
    src: templates/.env.j2
    dest: /usr/share/tomcat/bin/setenv.sh
    mode: '0600'
  no_log: true
```

**What I learned:**
`no_log: true` has to go on every task that touches the secret — not just the first one. Each task logs independently. A `set_fact` that parses a secret will still print the parsed values if it doesn't have its own `no_log: true`.

---

## Issue 16: Considered Ansible Vault, Chose Secrets Manager Instead

**What happened:**
Not a failure — a decision I had to think through. Ansible Vault can encrypt variable files and is built into Ansible. I evaluated whether to use it instead of AWS Secrets Manager.

**Why I went with Secrets Manager:**
Vault encrypts secrets but you still need to store the vault password somewhere — which in a CI/CD pipeline means another pipeline secret or environment variable. That's the same problem shifted one level up.

With Secrets Manager and an EC2 IAM role, there's no password to store anywhere. AWS handles the encryption and the EC2's IAM role controls access. The application can also retrieve credentials directly without Ansible being involved at all.

**What I learned:**
Ansible Vault makes more sense for secrets that Ansible itself needs (like SSH keys for managed nodes). For application secrets that a running service needs at runtime, Secrets Manager with an IAM role is cleaner because it doesn't require passing a vault password through the pipeline.

---

## Issue 17: `group_vars` Variables Weren't Available on All Hosts

**What happened:**
Variables defined in a `group_vars` file were undefined on some hosts where I expected them to be available.

**What caused it:**
`group_vars` file names map directly to inventory group names. A variable in `group_vars/app_servers.yml` is only available to hosts in the `[app_servers]` group. Hosts in other groups can't see it.

```
group_vars/
  all.yml          # available to every host
  app_servers.yml  # only hosts in [app_servers]
  jenkins.yml      # only hosts in [jenkins]
```

**The fix:**
Matched file names exactly to inventory group names. Moved shared variables to `all.yml`.

**What I learned:**
`group_vars` file names aren't labels — they have to match the group names in the inventory exactly. When a variable is unexpectedly undefined, check whether the target host is in the group whose file defines that variable.

---

## Issue 18: Variable Was Being Overridden Without Me Realizing

**What happened:**
A task was using a different value than what was set in `defaults/main.yml`. The defaults file looked correct but the value wasn't being used.

**What caused it:**
`defaults/main.yml` is the lowest priority in Ansible's variable system — it's designed to be overridden. The same variable was defined at a higher priority somewhere else (in `group_vars` or the playbook's `vars:` block) and that value was winning silently.

Ansible's precedence order (lowest to highest):
1. `defaults/main.yml`
2. `group_vars/`
3. `host_vars/`
4. `vars:` in the playbook
5. `-e` extra vars on the command line

**The fix:**
Searched for the variable name across all files and found the duplicate definition. Removed the one that was unintentionally overriding the default.

**What I learned:**
When a variable resolves to an unexpected value, search every file for that variable name — not just the one you think is setting it. Running `ansible -m debug -a "var=variable_name" -i inventory hostname` shows you exactly what value a variable resolves to on a specific host.

---

## Issue 19: VS Code File Colors Looked Like Errors

**What happened:**
Terraform files appeared in light brown/orange in VS Code during development. I wasn't sure if something was wrong.

**What it actually means:**
They're Git status indicators, not error indicators:

| Color | Meaning |
|-------|---------|
| Green | New file not yet added to Git |
| Brown/Orange | File changed but not committed |
| Red | File deleted but deletion not committed |

**What I learned:**
Modified files during active development are normal. The color is just a reminder to review what changed before committing — which is also what the pre-commit hooks are there to catch if something sensitive accidentally ended up in the diff.

---

## Issue 20: Wasn't Sure How Ansible Knows Which Machine Is the Control Node

**What happened:**
After writing the playbook, I realized it didn't specify which machine was the control node or which machines were the managed nodes — that information wasn't in the YAML.

**How it works:**
- Control node = whatever machine runs `ansible-playbook`
- Managed nodes = servers listed in the inventory file

```ini
# inventory
[app_servers]
ec2-1.compute.amazonaws.com

[jenkins_servers]
ec2-2.compute.amazonaws.com
```

The playbook's `hosts: app_servers` tells Ansible to run those tasks on every server listed under `[app_servers]`. The inventory file is passed when you run the command:

```bash
ansible-playbook -i inventory site.yml
```

**What I learned:**
The playbook and inventory are always separate files that work together at runtime. The playbook says what to do. The inventory says where. In this project, Jenkins is the control node — it's the machine that runs `ansible-playbook` and SSHes into the EC2 instances to configure them.

---

## General Takeaways

**Silent failures are the hardest to debug.**
Issues 1, 2, and 4 all had the same symptom — application couldn't connect to the database — but three completely different root causes. When a deployment succeeds but the app behaves wrong, work backward through each layer: is the config file there? Does it have the right values? Is the application actually reading it?

**Read the error message before searching.**
Most of the errors above said exactly what was wrong once I read them carefully. "No package jenkins available" means the repo isn't registered. "boto3 required" means install boto3. "lookup plugin not found" means install the collection. The error message is usually the diagnosis — searching before reading it just wastes time.

**Test pre-commit hooks by intentionally breaking something.**
Don't assume a hook works because it's configured. Try committing a fake secret, an unformatted Terraform file, or a checkov violation and confirm the hook actually blocks it.