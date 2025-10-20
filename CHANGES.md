# Changes - Database Setup and From-Scratch Deployment

This document tracks the changes made to enable complete from-scratch deployment of LiteLLM with PostgreSQL.

## Summary

Added missing scripts and documentation to enable users to deploy LiteLLM from scratch without manual secret management.

## New Files Added

### 1. `.env.example`
- Template file showing required environment variables
- Documents that `POSTGRES_PASSWORD` should be generated using `scripts/generate-env.sh`
- Provides guidance to users on secure credential management

### 2. `scripts/generate-env.sh`
- Bash script to generate secure `.env` file with a 40-character random password
- Uses `openssl` (preferred) or falls back to `/dev/urandom`
- Prompts before overwriting existing `.env` file
- Sets file permissions to 600 (owner read/write only)
- Validates password generation

## Modified Files

### 1. `vault/init-vault-secrets.sh`
**Changes:**
- Added database password detection with precedence:
  1. `DB_PASSWORD` environment variable
  2. `POSTGRES_PASSWORD` environment variable  
  3. `.env` file (sourced automatically)
- Now stores **both** secrets in Vault:
  - `secret/litellm/openrouter` (existing - OpenRouter API key)
  - `secret/litellm/database` (new - PostgreSQL password)
- Added password length validation (warns if < 12 characters)
- Updated usage documentation with multiple examples
- Enhanced success message to list all stored secrets

### 2. `README.md`
**Changes:**
- Updated Prerequisites section:
  - Added Docker and Docker Compose
  - Added openssl to required tools
  - Made jq explicitly optional
- Updated TL;DR - Quick Deploy:
  - Added Step 0: Generate .env and start database
  - Updated Step 4 description to clarify both secrets are stored
- Updated Quick start section:
  - Added new Step 1: Setup local database
  - Included note about external PostgreSQL instances
  - Renumbered all subsequent steps (2-8)
  - Added database password to Vault initialization explanation
- Updated Project structure to include:
  - `DATABASE.md`
  - `.env.example`
  - `docker-compose.yml`
  - `scripts/generate-env.sh`

### 3. `DATABASE.md`
**Changes:**
- Added Step 0 to Quick Start: Generate secure credentials
- Explained how `.env` is used by both Docker Compose and Vault
- Added link to main README for complete workflow
- Clarified where database password is stored in Vault (`secret/litellm/database` with field `password`)

## Existing Files (No Changes Required)

### `docker-compose.yml`
- Already correctly configured to read `POSTGRES_PASSWORD` from `.env`
- No modifications needed

### `.gitignore`
- Already contains `.env` entry
- No modifications needed

### `litellm/litellm-values.yaml`
- Already references correct Vault path: `secret/data/litellm/database`
- No modifications needed

## Workflow Impact

### Before (Incomplete)
Users had to manually:
1. Create `.env` file with password
2. Remember to store database password in Vault
3. Figure out the correct Vault path and field name
4. Start docker-compose at some point (undocumented in main flow)

❌ **Result:** LiteLLM pods would fail because `secret/litellm/database` didn't exist in Vault

### After (Complete)
Users follow a clear step-by-step process:
1. Run `./scripts/generate-env.sh` → secure password created automatically
2. Run `docker compose up -d` → database starts with generated password
3. Run `./vault/init-vault-secrets.sh` → **both** OpenRouter key and DB password stored in Vault
4. Deploy LiteLLM → pod starts successfully with all required secrets

✅ **Result:** Complete from-scratch deployment works without manual intervention

## Security Improvements

1. **Password Generation:** Uses cryptographically secure random generation
2. **File Permissions:** `.env` file automatically set to 600 (owner only)
3. **No Password Echo:** Scripts never print passwords to terminal
4. **Validation:** Warns if password is too short
5. **Git Safety:** `.env.example` provided but real `.env` is gitignored

## Testing Checklist

To validate this implementation, a new user should be able to:

- [ ] Clone the repository
- [ ] Run `./scripts/generate-env.sh` successfully
- [ ] Start PostgreSQL with `docker compose up -d`
- [ ] Pull Helm charts with `./scripts/pull-charts.sh`
- [ ] Create namespace: `kubectl create namespace litellm`
- [ ] Install Vault: `helm install vault ./charts/vault -n litellm -f vault/vault-values.yaml`
- [ ] Initialize Vault: `OPENROUTER_API_KEY=<key> ./vault/init-vault-secrets.sh`
- [ ] Verify both secrets exist in Vault:
  - `vault kv get secret/litellm/openrouter` (has `api-key`)
  - `vault kv get secret/litellm/database` (has `password`)
- [ ] Deploy LiteLLM: `helm install litellm ./charts/litellm-helm -n litellm -f litellm/litellm-values.yaml`
- [ ] Verify LiteLLM pod starts without errors
- [ ] Test LiteLLM endpoint with a sample request

## Commit Messages

```
feat(env): add .env.example and secure generator script

- Add .env.example template with documentation
- Add scripts/generate-env.sh for secure password generation
- Script uses openssl or /dev/urandom fallback
- Generates 40-character alphanumeric passwords
- Sets proper file permissions (600)

feat(vault): store database password in Vault

- Update vault/init-vault-secrets.sh to store DB password
- Support multiple input sources: DB_PASSWORD, POSTGRES_PASSWORD, .env
- Store at secret/litellm/database with field 'password'
- Add password length validation
- Maintain backward compatibility with OpenRouter secret

docs: add database setup steps to deployment workflow

- Update README.md TL;DR and Quick start sections
- Add database setup as Step 0/1 in workflows
- Update prerequisites to include Docker/Docker Compose
- Clarify that both secrets are stored in Vault
- Update DATABASE.md with .env generation instructions
- Update project structure to show new files
```
