# GitHub Actions Secrets Configuration

This document describes the secrets required for the blue-green deployment pipeline.

## Required Secrets

All secrets are configured at: **Settings -> Secrets and variables -> Actions -> New repository secret**

| Secret Name | Value | Where to Get |
|------------|-------|--------------|
| `EC2_SSH_KEY` | Full private key PEM content | `C:\Users\fiefi\.ssh\ec2-static-site-key.pem` |
| `EC2_HOST` | `13.236.205.122` | Fixed EC2 public IP |
| `DOCKER_USERNAME` | Docker Hub username | `mythicc123` |
| `DOCKER_PASSWORD` | Docker Hub password or access token | Docker Hub account settings |

## EC2_SSH_KEY Setup

1. Read the private key:
   ```bash
   cat ~/.ssh/ec2-static-site-key.pem
   ```
2. Copy the entire output including `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END OPENSSH PRIVATE KEY-----`
3. Paste into the `EC2_SSH_KEY` secret value field in GitHub
4. **IMPORTANT:** The key must be unencrypted (no passphrase). If the key has a passphrase, remove it:
   ```bash
   ssh-keygen -p -f ~/.ssh/ec2-static-site-key.pem
   # Enter old passphrase, leave new passphrase empty
   ```

## DOCKER_PASSWORD Setup

Using an access token instead of password is recommended:

1. Go to Docker Hub -> Account Settings -> Security -> Access Tokens
2. Create new token with:
   - Token name: `github-actions-deploy`
   - Access permission: `Read, Write, Delete`
3. Copy the generated token as the `DOCKER_PASSWORD` secret value

## Verification

After setting secrets, push a commit to `main` and verify:
1. The workflow starts in the Actions tab
2. The Docker build step succeeds
3. The deploy step completes (look for "LOCK ACQUIRED" and "LOCK RELEASED" in logs)
4. The smoke test step passes (look for "SMOKE TEST: ALL PASSED")
5. The workflow shows a green checkmark

## Troubleshooting

**SSH connection refused:**
- Verify EC2 is running and accessible from the internet
- Check the public IP is correct
- Verify the public key is in `~/.ssh/authorized_keys` on EC2

**Docker push failed:**
- Verify `DOCKER_USERNAME` and `DOCKER_PASSWORD` are correct
- Ensure the Docker Hub account has push access to `mythicc123/multi-container-service`

**Deploy step failed:**
- Check that Phase 2 scripts exist at `scripts/*.sh`
- Verify `/tmp/deploy/` scripts were installed by the setup step
- Check EC2 lock file: `ssh ubuntu@13.236.205.122 "cat /tmp/blue-green-deploy.lock"`
