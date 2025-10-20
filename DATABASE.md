# Local PostgreSQL Database Setup

This document describes the local PostgreSQL database setup that simulates an AWS RDS instance for LiteLLM development and testing.

## Overview

- **Database**: PostgreSQL 16
- **Container**: `litellm_postgres`
- **Port**: 5432 (exposed to host)
- **Database name**: `litellm`
- **Username**: `llmproxy`
- **Password**: Stored in `.env` file (not committed to git)

## Quick Start

### 1. Start the database

```bash
docker compose up -d
```

### 2. Check status

```bash
docker compose ps
```

You should see the `postgres` service with state `healthy`.

### 3. View logs

```bash
docker compose logs -f postgres
```

## Database Connection

### Connection String

The database connection URL for LiteLLM is:

```bash
postgresql://llmproxy:${POSTGRES_PASSWORD}@localhost:5432/litellm
```

### Set DATABASE_URL environment variable

For local development with LiteLLM:

```bash
# Load password from .env
source .env

# Set DATABASE_URL
export DATABASE_URL="postgresql://llmproxy:${POSTGRES_PASSWORD}@localhost:5432/litellm"
```

## Management Commands

### Connect to the database

**From within the container:**

```bash
docker compose exec postgres psql -U llmproxy -d litellm
```

**From your host (if you have psql installed):**

```bash
source .env
psql "postgresql://llmproxy:${POSTGRES_PASSWORD}@localhost:5432/litellm"
```

### Check database readiness

```bash
docker compose exec postgres pg_isready -U llmproxy -d litellm
```

### Run a test query

```bash
docker compose exec postgres psql -U llmproxy -d litellm -c "SELECT version();"
```

### List all databases

```bash
docker compose exec postgres psql -U llmproxy -d litellm -c "\l"
```

### List all tables

```bash
docker compose exec postgres psql -U llmproxy -d litellm -c "\dt"
```

## Lifecycle Management

### Stop the database (keeps data)

```bash
docker compose down
```

### Restart the database

```bash
docker compose restart postgres
```

### Stop and remove the database (keeps data in volume)

```bash
docker compose down
```

### Full reset (DESTROYS ALL DATA)

```bash
docker compose down -v
```

⚠️ This removes the Docker volume and all database data!

## Data Persistence

Database data is stored in a Docker volume named `litellm_postgres_data`. This ensures data persists across container restarts and recreations.

### View volume details

```bash
docker volume inspect litellm_postgres_data
```

### Backup the database

```bash
docker compose exec postgres pg_dump -U llmproxy -d litellm > litellm_backup_$(date +%Y%m%d_%H%M%S).sql
```

### Restore from backup

```bash
# Make sure the database is running
docker compose up -d

# Restore
cat litellm_backup_YYYYMMDD_HHMMSS.sql | docker compose exec -T postgres psql -U llmproxy -d litellm
```

## Integration with LiteLLM

### For local testing with Docker

If you want to run LiteLLM locally and connect to this database:

```bash
# Load the password
source .env

# Run LiteLLM (example)
docker run -d \
  -p 4000:4000 \
  -e DATABASE_URL="postgresql://llmproxy:${POSTGRES_PASSWORD}@host.docker.internal:5432/litellm" \
  -e STORE_MODEL_IN_DB="True" \
  ghcr.io/berriai/litellm-database:main-stable \
  --config /path/to/config.yaml
```

Note: Use `host.docker.internal` instead of `localhost` when connecting from another Docker container.

### For Kubernetes with AWS RDS

When you deploy to Kubernetes with AWS RDS, you'll use a connection string like:

```bash
postgresql://llmproxy:${RDS_PASSWORD}@your-rds-endpoint.region.rds.amazonaws.com:5432/litellm
```

## Troubleshooting

### Port 5432 already in use

If you have another PostgreSQL instance running on port 5432:

```bash
# Check what's using port 5432
lsof -i :5432

# Either stop that service or change the port in docker-compose.yml
# For example, change to 5433:
# ports:
#   - "5433:5432"
# Then connect using: postgresql://llmproxy:${POSTGRES_PASSWORD}@localhost:5433/litellm
```

### Container unhealthy

```bash
# Check logs
docker compose logs postgres

# Verify pg_isready
docker compose exec postgres pg_isready -U llmproxy -d litellm

# Restart the container
docker compose restart postgres
```

### Reset password

To change the PostgreSQL password:

1. Update `.env` with a new password
2. Stop and remove the container: `docker compose down -v` (WARNING: deletes data)
3. Start fresh: `docker compose up -d`

### Connection refused from host

Ensure the container is running and healthy:

```bash
docker compose ps
docker compose logs postgres
```

## Security Notes

- The `.env` file contains the database password and is **not committed to git**
- For production/AWS RDS, use proper secret management (AWS Secrets Manager, Vault, etc.)
- The password in `.env` is auto-generated with 40 characters of randomness
- Change the default username/password for production deployments

## AWS RDS Migration

When migrating to AWS RDS:

1. Create an RDS PostgreSQL instance (version 16 recommended)
2. Use the same database name (`litellm`) and username (`llmproxy`)
3. Update your Kubernetes secrets with the RDS endpoint and credentials
4. Update the DATABASE_URL in your LiteLLM deployment to point to RDS
5. Apply database migrations if needed

The schema and data structure will be compatible since both use PostgreSQL 16.
