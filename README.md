# docker-backrest

## 1. What it does

Backrest runs restic backups to Backblaze B2. Sources are mounted read-only.

| Plan | Host data backed up | Schedule (Europe/Zurich) | Retention |
| --- | --- | --- | --- |
| `docker` | Paperless AI exports (`/var/lib/docker/100000.100000/volumes/paperless-ai_export/_data`), Vault unseal key (`/var/lib/docker/100000.100000/volumes/infra_vault_unseal/_data/key`), Vault archives (`/scratch/backup/vault`) | Monday 08:00 | Last 8 snapshots |
| `documents` | `/export/Documents` (NFS) | Monday 00:00 | Last snapshot |

Both plans skip unchanged data. Documents runs separately so an unavailable NFS server does not block the Docker backups.

## 2. How it is configured

- `docker-compose.yml`: pinned image, source mounts, persistent state volumes, secrets, and Traefik/Authelia access at `backrest.${DOCKER_DOMAIN}`. No host port is published.
- `backrest/config.template.json`: repository, backup paths, schedules, and retention. Edit this file to change backup settings.
- `backrest/render-config.sh`: combines the template and secrets into `/config/config.json` at startup. Template or secret changes replace the generated config; ordinary restarts preserve UI edits.

Apply changes with:

```sh
docker compose up -d --force-recreate
```

Backrest runs as UID/GID `175200010` for NFS access. The init service sets state-volume ownership and grants read access to the Vault key; recreate the stack after replacing that key.

## 3. How it connects to B2

Restic uses B2 directly at `b2:enucatl-backups:restic`: bucket `enucatl-backups`, prefix `restic`. Backrest initializes the repository automatically.

Supply these untracked Compose secret files:

| File | Used for |
| --- | --- |
| `secrets/backrest_b2_account_id` | `B2_ACCOUNT_ID` authentication |
| `secrets/backrest_b2_account_key` | `B2_ACCOUNT_KEY` authentication |
| `secrets/backrest_repo_password` | Restic repository encryption and decryption |

Keep these credentials outside Vault and this host so recovery remains possible if either is unavailable.

## 4. How to check it works

```sh
docker compose config --quiet  # Validate Compose configuration.
docker compose ps             # Check container health.
bash tests/backup-restore.sh   # Exercise backup and recovery.
```

The healthcheck requests Backrest's local HTTP endpoint every 30 seconds. It checks service availability, not backup recovery.

The recovery test runs the `docker` plan, waits for success, restores the Vault key and newest archive from B2 with restic verification, compares the key byte for byte, and starts and unseals an isolated Vault from the restored data. Its container has no network; temporary storage and restored files are removed on exit. It requires Docker, `jq`, and the running `infra-vault-1` container.

This test does not cover the `documents` plan or scheduled execution. Check scheduled runs in the Backrest UI and restore a Documents file separately.
