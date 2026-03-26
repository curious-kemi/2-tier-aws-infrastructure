# Terraform Plan Management

## Problem

Running `terraform apply` directly without saving the plan creates a risk — infrastructure state can change between the plan and apply steps, meaning what gets applied may differ from what was reviewed. This introduces unreviewed changes into production infrastructure.

## Solution

I separated plan and apply into distinct pipeline stages with a manual approval gate between them.

In the plan stage I generate and save an execution plan to a file:
```bash
terraform -chdir=terraform/ plan -input=false -out=tfplan
terraform -chdir=terraform/ show tfplan
```

I archive the binary plan as a Jenkins artifact and print the human readable output to the Jenkins console for review.

I then configured the pipeline to pause and wait for explicit human approval before proceeding.

In the apply stage I execute the exact saved plan — not a new one:
```bash
terraform -chdir=terraform/ apply -input=false -auto-approve tfplan
```

## Result

By applying the saved plan I guarantee that what was reviewed is exactly what gets applied. Every infrastructure change I make has an explicit approval and audit trail — aligning with change management best practices I developed through my SOC experience and preventing unauthorized infrastructure modifications.

# Terraform Plan Artifact Management

## Problem

Without archiving the Terraform plan, the `tfplan` file is saved in the Jenkins workspace and gets overwritten every time the pipeline runs. If a new pipeline run triggers before the previous plan is applied, the original reviewed plan is lost — meaning the wrong plan could get applied.

## Solution

I archive the plan file as a Jenkins artifact after every plan stage:
```groovy
archiveArtifacts artifacts: 'tfplan'
```

Jenkins archives artifacts per build number — meaning each pipeline run has its own permanently saved plan:

- Build #1 → its own `tfplan` archived
- Build #2 → its own `tfplan` archived separately
- Neither overwrites the other

This guarantees that the plan reviewed in build #1 is exactly what gets applied in build #1 — regardless of how many pipeline runs happen after it.

## Result

Every pipeline run has a permanently saved, independently archived plan file. I can apply exactly the plan that was reviewed — no risk of overwriting or applying the wrong plan. Combined with the manual approval gate, every infrastructure change is traceable back to a specific reviewed and approved plan.