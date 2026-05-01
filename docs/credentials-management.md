# Application Security: Database Credential Management

## The Problem We Started With

The VotingApp had hardcoded database credentials in `application.properties`:

```properties
spring.datasource.url=jdbc:mysql://localhost:3306/votingapp
spring.datasource.username=root
spring.datasource.password=mypassword
```

**Two security problems:**
1. Credentials visible in code — anyone with repo access sees the password
2. Static credentials — no rotation, manual updates required

---

## Thought Process: Evaluating Solutions

### Option 1 — Environment Variables via Ansible
**Idea:** Ansible fetches from Secrets Manager, writes to `setenv.sh`, app reads via `System.getenv()`

**Why we considered it:**
- Simple code change
- No AWS SDK needed
- Good for learning concepts

**Why we moved on:**
- Credentials loaded into memory once at startup
- Rotation requires Tomcat restart → potential downtime
- Manual intervention needed after rotation
- Credentials sit in memory for long periods → larger attack window

---

### Option 2 — AWS SDK directly in Java
**Idea:** Java code calls Secrets Manager SDK directly

**Why we considered it:**
- Fetches fresh credentials at runtime
- Handles rotation automatically
- No environment variables needed

**Why we moved on:**
- Not Spring Boot native
- More code to write and maintain
- Caching must be managed manually
- Why reinvent what Spring already provides?

---

### Option 3 — AWS SDK + Caching Library
**Idea:** AWS SDK with TTL based caching to reduce API overhead

**Why we considered it:**
- Reduces API calls
- Handles rotation within TTL window
- More efficient than raw SDK

**Why we moved on:**
- Still not Spring Boot native
- Managing TTL adds complexity
- Spring Cloud AWS handles this better natively

---

### Option 4 — Spring Cloud AWS (chosen solution)
**Idea:** Spring Boot native integration with Secrets Manager

**Why this won:**
- Spring Boot native — framework handles everything
- No hardcoded credentials ✅
- Auto refresh on rotation — zero downtime ✅
- No restart needed ✅
- Minimal code changes ✅
- AWS and Spring maintain it ✅
- Production standard for Spring Boot apps ✅

---

## What We Discovered Along the Way

### The app was Spring Boot — not plain Java/Tomcat

Initially assumed plain Java/Tomcat app based on README. Examining actual code revealed:
- `application.properties` → Spring Boot specific
- `MySpringBootVotingAppFinalApplication.java` → Spring Boot entry point
- Spring Data JPA already managing database connections

**Lesson:** Always examine actual code before building infrastructure around it. README can be misleading.

### Spring Boot has embedded Tomcat

Spring Boot packages Tomcat inside the `.jar` — no separate Tomcat installation needed. This changed our Ansible `app_server` role significantly.

### Bootstrap phase disabled in Spring Boot 2.4+

Originally planned to use `bootstrap.properties` for Secrets Manager config. Discovered Spring Boot 2.4+
disabled bootstrap phase by default in favor of `spring.config.import`.

**Lesson:** Always check framework version compatibility before implementing. Documentation saves time.

---

## Implementation

### Step 1 — Added Spring Cloud AWS to `pom.xml`

```xml
<dependency>
    <groupId>io.awspring.cloud</groupId>
    <artifactId>spring-cloud-aws-secrets-manager-config</artifactId>
    <version>2.4.4</version>
</dependency>
<dependency>
    <groupId>io.awspring.cloud</groupId>
    <artifactId>spring-cloud-aws-autoconfigure</artifactId>
    <version>2.4.4</version>
</dependency>
```

### Step 2 — Updated `application.properties`

```properties
spring.config.import=aws-secretsmanager:db_credentials
spring.datasource.url=jdbc:mysql://${host}:3306/votingapp
spring.datasource.username=${username}
spring.datasource.password=${password}
```

### How it works

```
App starts
       ↓
spring.config.import triggers
       ↓
Spring Cloud AWS fetches db_credentials from Secrets Manager
       ↓
Maps JSON fields to variables:
host     → ${host}
username → ${username}
password → ${password}
       ↓
Spring Boot configures datasource automatically
       ↓
JDBC connects to RDS
       ↓
App serves users
```

---

## Security Benefits Achieved

| Problem | Solution | Result |
|---------|----------|--------|
| Hardcoded credentials | Spring Cloud AWS | Zero credentials in code ✅ |
| Manual rotation | Auto refresh | Zero downtime rotation ✅ |
| Long credential exposure | Dynamic fetching | Minimal memory exposure ✅ |
| Git history exposure | Never in code | Clean git history ✅ |

---

## Credential Flow

```
AWS Secrets Manager (encrypted at rest)
       ↓
Spring Cloud AWS fetches at startup
       ↓
Spring Boot configures datasource
       ↓
JDBC connects to RDS
       ↓
App serves users
       ↓
Credentials rotate in Secrets Manager
       ↓
Spring Cloud AWS auto refreshes
       ↓
Zero downtime
```

---

## Lessons Learned

1. **Read the actual code** — don't trust README alone
2. **Use framework native solutions** — Spring Cloud AWS over raw SDK for Spring Boot
3. **Check version compatibility** — Spring Boot 2.4+ changed bootstrap behavior
4. **Minimize credential exposure time** — dynamic fetching beats static environment variables
5. **Defense in depth** — Secrets Manager + Spring Cloud AWS + IAM role = multiple security layers