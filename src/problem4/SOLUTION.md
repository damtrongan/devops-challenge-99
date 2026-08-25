# Solution: CI/CD Pipelines for Backend (EC2) and Frontend (S3)

## What "production ready" means here

I took it to mean, in priority order:

1. **Nothing broken reaches an environment users hit.** Tests, lint, and a dependency vulnerability scan gate every deploy.
2. **No long-lived AWS credentials in GitHub.** Both pipelines assume an AWS IAM role via OIDC (`aws-actions/configure-aws-credentials` + `role-to-assume`) - no static access keys stored as secrets.
3. **What's deployed is exactly what was tested**, and it's traceable to a commit. The backend builds one immutable image (tagged by short SHA) and *promotes* that same image from staging to production rather than rebuilding.
4. **A human explicitly approves production.** Staging deploys automatically on merge to `main`; production only deploys off a published GitHub Release, gated by a GitHub Environment with required reviewers.
5. **Failure is detected and reversible.** Both pipelines run a post-deploy health check; the backend automatically rolls back to the previously running image if the new one fails its check.
6. **Least-privilege, scoped IAM.** Sample policies (`iam/`) grant only the specific ECR repo / S3 bucket / CloudFront distribution / SSM document each pipeline needs - not account-wide access.

I did *not* treat "production ready" as "handles infinite scale" - this is a two-service product, not a platform. Over-engineering (multi-region, blue/green EC2 fleets, canary analysis) would cost more than it returns here; see "What was deliberately left out" below.

---

## Assumptions

Since there's no real AWS account and no existing app source in this repo, I had to assume a plausible shape for both apps and their infrastructure. These are documented here rather than guessed silently:

| Area | Assumption | Why |
|---|---|---|
| Repo layout | Backend lives in `backend/`, frontend in `frontend/`, both as npm projects with `package-lock.json` | Matches the task's two-app description; path filters (`paths: ["backend/**"]`) keep each pipeline from running on unrelated changes |
| Backend runtime | Node.js/Express app, packaged as a Docker image, run via `docker compose` on the EC2 instance(s) at `/opt/app/docker-compose.yml` | "Deployed to EC2" is compatible with either a bare process or a container; I chose a container because it makes the artifact immutable and the promotion (build once, deploy the same image to staging then production) trivial to reason about |
| Backend health | Exposes `GET /status` returning 200 when healthy | Standard convention, used for both deploy verification and (implicitly) instance-level health checks |
| Backend access from CI | AWS Systems Manager (`ssm:SendCommand`), not SSH | No inbound SSH port needs to stay open on the fleet, and it removes SSH key management from the pipeline entirely |
| Backend image registry | Amazon ECR, one repository per app | Native to the AWS account, integrates with OIDC-scoped IAM without extra tooling |
| Frontend build | A standard SPA build (`npm run build` → `frontend/dist/`) | Framework-agnostic (Vite/CRA/etc. all fit this shape) |
| Frontend hosting | S3 bucket behind CloudFront | S3 alone can't serve HTTPS on a custom domain; CloudFront is the de facto pairing and gives me a place to put the CDN cache-invalidation step "production ready" implies |
| Environments | Two: `staging` and `production`, each with its own AWS resources (bucket, EC2 fleet tag, CloudFront distribution) referenced via GitHub Environment variables/secrets | Lets `staging` auto-deploy freely while `production` carries the approval gate, without duplicating workflow logic |
| Release process | `main` is protected and only reachable via reviewed PRs; a GitHub Release tag is the trigger for a production promotion | Common, low-ceremony pattern - no extra release-management tooling required |
| Config values | Region, bucket names, ECR repo, instance tags, CloudFront distribution IDs live in GitHub **Environment variables** (`vars.*`); only the IAM role ARN is a **secret** | None of those identifiers are sensitive; treating them as secrets would just make the workflow harder to read for no security benefit |

---

## How the pipelines work

### Backend (`.github/workflows/backend.yml`)

```
PR / push to main ─▶ test ─▶ security-scan ─▶ (push to main only) build-and-push ─▶ deploy-staging ─▶ health check
                                                        │
                                                        ▼
                                            image tagged by short SHA, pushed to ECR
                                                        │
                              GitHub Release published ▼
                                              deploy-production (environment: production, manual approval)
                                                        │
                                     resolve the SAME image tag from the release commit's SHA
                                                        │
                                        deploy via SSM ─▶ health check ─▶ rollback to previous tag on failure
```

- **`test`**: checkout, `npm ci`, lint, unit tests, build - on every PR and push to `main`.
- **`security-scan`**: `npm audit --audit-level=high`, gating the pipeline on known high/critical vulnerabilities.
- **`build-and-push`**: only on push to `main` (i.e. after a PR merges). Assumes the AWS role via OIDC, builds the Docker image, tags it with the 12-character commit SHA (plus a convenience `:latest`), pushes both to ECR.
- **`deploy-staging`**: takes that exact image tag, deploys it to the staging EC2 fleet over SSM (`scripts/deploy-backend.sh`), then polls `/status` (`scripts/healthcheck.sh`). Fully automatic - staging is meant to be cheap to update.
- **`deploy-production`**: triggered only by a **published GitHub Release**. It checks out the release's target commit, recomputes that same short-SHA tag (it does not rebuild), and gates behind the `production` GitHub Environment. Before deploying, it captures the tag currently running in production (`scripts/get-current-tag.sh`); if the new deploy or its health check fails, it redeploys that captured tag automatically.

The deliberate design choice here is **build once, promote the same artifact** - staging and production run byte-identical images. Rebuilding for production would risk a different result (e.g. a dependency update landing between builds) even from the "same" source, which defeats the point of having tested staging first.

### Frontend (`.github/workflows/frontend.yml`)

```
PR / push to main ─▶ test+build ─▶ (push to main only) deploy-staging ─▶ CloudFront invalidation ─▶ smoke test
                                                    │
                       GitHub Release published ─────────────────▶ deploy-production (rebuild from release commit)
                                                                        │
                                                        S3 sync ─▶ CloudFront invalidation ─▶ smoke test
```

- **`test`**: checkout, `npm ci`, lint, unit tests, `npm run build`, then uploads `dist/` as a workflow artifact.
- **`deploy-staging`**: downloads that same artifact (built once, in this same run), assumes the AWS role, and `aws s3 sync`s it to the staging bucket. Hashed assets get `Cache-Control: public, max-age=31536000, immutable`; `index.html` gets `no-cache, no-store, must-revalidate` - otherwise a client with a cached `index.html` would keep requesting JS/CSS bundles that a later deploy has deleted. Then invalidates the CloudFront paths for `/` and `/index.html` (not the whole distribution - the hashed assets don't need it) and runs a smoke test.
- **`deploy-production`**: triggered by a published Release. Unlike the backend, this job **rebuilds** from the release's exact commit rather than reusing a cross-run artifact.

**Why the frontend rebuilds but the backend doesn't:** GitHub Actions artifacts aren't easily shared across separate workflow *runs* without extra API plumbing (the staging build and the later production release are different triggers, hence different runs). For the backend that gap is closed by pushing an immutable, addressable image to ECR - the production job just references it by tag. A static frontend build via `npm ci` (which installs exactly what `package-lock.json` pins) is deterministic enough that rebuilding from the same commit reliably reproduces the same output, so I accepted the simpler rebuild rather than adding artifact-passing machinery for comparatively low risk. This is a real tradeoff, not an oversight - a stricter pipeline could instead publish `frontend/dist` to S3/ECR-style storage and have production pull that exact artifact, the same way the backend does.

---

## Supporting files

- `scripts/deploy-backend.sh` - sends the deploy command to the tagged EC2 fleet via SSM `AWS-RunShellScript`, polls for completion, surfaces command output on failure.
- `scripts/get-current-tag.sh` - reads the image tag currently running on the production instance, used as the rollback target.
- `scripts/healthcheck.sh` - generic HTTP polling health check, shared by both pipelines.
- `iam/github-oidc-trust-policy.json` - trust policy for the deploy role, scoped by `sub` claim to this repo's `staging`/`production` GitHub Environments (not just the repo generally - this stops a workflow run outside those environments from assuming the role at all).
- `iam/backend-deploy-policy.json` - permissions scoped to the specific ECR repository, plus SSM `SendCommand`/`GetCommandInvocation` conditioned on an `Application=backend` resource tag.
- `iam/frontend-deploy-policy.json` - permissions scoped to the specific S3 bucket and CloudFront distribution ARNs.

**Known limitation in the IAM samples:** `ec2:DescribeInstances` (used by `get-current-tag.sh` to resolve an instance ID) doesn't support resource-level permissions in IAM - a tag `Condition` on it restricts nothing in practice; AWS only lets you allow-or-deny the API call as a whole. I left the condition in the JSON to document *intent*, but the real boundary enforced there is "this role can call `DescribeInstances` at all," not "only for backend instances." A tighter real-world fix would be a Lambda/SSM-parameter lookup that's actually scoped, or just accepting `Resource: "*"` for that one read-only call and relying on the SSM `SendCommand` tag condition (which *is* enforced) to bound anything that actually mutates the fleet.

---

## What I deliberately left out, and why

- **Actually running against AWS.** Per the task, there's no real account. Every AWS-touching step is implemented with correct syntax and real CLI/action usage, but will fail at `configure-aws-credentials` (no `AWS_DEPLOY_ROLE_ARN` secret) if run as-is. That's expected, not a bug.
- **Database migrations.** The task only mentions "an HTTP API," with no datastore specified. If the real backend has one, a migration step (with a documented rollback story) belongs between `build-and-push` and `deploy-*` - I didn't invent a schema to bolt this onto speculatively.
- **Blue/green or canary deploys for the backend.** `docker compose up -d --no-deps app` briefly interrupts the container being replaced. For a single EC2 instance (or a small fixed fleet) behind a load balancer, a production-grade version would deploy to instances one at a time and deregister/re-register each from the target group around the swap. I left this as a known gap rather than implementing an ASG/target-group rotation script for infrastructure that (per the task) doesn't exist to test against - adding that complexity without being able to verify it would be worse than stating the gap plainly.
- **Slack/Teams deploy notifications.** Easy to bolt on (`if: always()` step posting to a webhook secret) but there's no real channel to post to here, so I didn't add a step that would only ever no-op.
- **Dependabot / automated dependency PRs.** Complements `npm audit` well but is a repo-config concern, not a pipeline concern - left out of scope.
- **A dedicated `ci.yml` separate from the deploy workflows.** I combined CI (test/lint) and CD (deploy) per app into one workflow file, gated by job-level `if:` conditions on the triggering event. This keeps the trigger logic (paths, branches, release) in one place per app instead of duplicated across files; the tradeoff is a slightly longer file per app.
- **Terraform/CloudFormation for the AWS resources themselves** (the S3 bucket, CloudFront distribution, EC2 fleet, ECR repo, IAM roles). The task asked for the *pipelines*, not the infrastructure they deploy to; I documented the IAM policies those pipelines need but didn't provision the resources they reference.

---

## Required manual setup (documented, not automated)

For these workflows to run for real, a repo owner would need to:

1. Create an OIDC identity provider for `token.actions.githubusercontent.com` in the AWS account (one-time, account-wide).
2. Create the IAM role from `iam/*.json` and set its ARN as the `AWS_DEPLOY_ROLE_ARN` secret - **scoped per GitHub Environment** (`staging` and `production` can use different roles/accounts if desired).
3. Create the `staging` and `production` GitHub Environments, and add a **required reviewer** rule to `production` (this is what actually enforces the manual approval gate - the workflow YAML only references the environment by name).
4. Populate the `vars.*` values referenced in both workflows (`AWS_REGION`, `ECR_REPOSITORY`, `STAGING_BUCKET`, `PRODUCTION_BUCKET`, `STAGING_CLOUDFRONT_ID`, `PRODUCTION_CLOUDFRONT_ID`, `STAGING_INSTANCE_TAG`, `PRODUCTION_INSTANCE_TAG`).
5. Enable branch protection on `main` requiring the `test` and `security-scan` checks to pass before merge.
