# docker-backrest

Backrest/restic backup service for the selected Docker and host data paths.

## Service

This Compose project runs Backrest with a fresh restic repository at:

```text
b2:enucatl-backups:restic
```

The image is pinned by digest in `docker-compose.yml`. To upgrade Backrest, resolve the current digest for the desired tag and update the image reference explicitly:

```sh
docker buildx imagetools inspect ghcr.io/garethgeorge/backrest:latest
```

Backrest is exposed through Traefik and Authelia at:

```text
backrest.${DOCKER_DOMAIN}
```

No host port is published directly.

## Backup Scope

The configured Backrest plans separate always-local data from the intermittently
available Documents NFS mount. The `docker` plan backs up:

```text
/source/var/lib/docker/100000.100000/volumes/paperless-ai_export/_data
/source/var/lib/docker/100000.100000/volumes/infra_vault_unseal/_data/key
/source/scratch/backup/vault
```

The `documents` plan backs up:

```text
/source/export/Documents
```

Both plans run weekly on Monday using local time; `docker` keeps eight snapshots
and `documents` keeps the last snapshot. Both skip backups when their selected
sources have not changed. If `forbearance.home.arpa` is offline, only the
`documents` plan is affected.

The `docker` plan backs up the Vault unseal share alongside the Vault data
archives to the encrypted B2 repository. It does not mount the complete
initialization response in `infra_vault_recovery` or the bootstrap root token.
Keep the restic repository password and B2 access credentials available outside
Vault and this host so these backups can be recovered when Vault is unavailable.

## Secrets

Compose secrets are loaded from the untracked `secrets/` directory:

```text
secrets/backrest_b2_account_id
secrets/backrest_b2_account_key
secrets/backrest_repo_password
```

`backrest_repo_password` is the restic repository password. Restic uses it to unlock the repository encryption keys, and it is required to verify or restore backups. Store it somewhere durable outside this repository.

## Bootstrap Config

Backrest state is stored in named volumes:

```text
data
configuration
cache
tmp
```

On container start, `backrest/render-config.sh` renders `/config/config.json` from `backrest/config.template.json` and the Compose secrets. The generated config lives in the `configuration` volume and is not tracked.

The renderer records a checksum next to the generated config and only rewrites `/config/config.json` when the rendered template or secrets change. Normal restarts do not rewrite Backrest's mutable config, but template and secret changes are applied on the next container start.

Treat `backrest/config.template.json` as the source of truth for repository and plan settings. Backrest UI edits can be overwritten when the template or secrets change.

## Security Boundary

The service keeps the shared `docker-compose-security-baseline` limits, `no-new-privileges`, resource limits, PID limits, and read-only source mounts.

`userns_mode: host` is intentional because Backrest must read userns-remapped Docker volume data under `/var/lib/docker/100000.100000`.

The stable `/export` parent is bind-mounted with `rslave` propagation rather
than mounting `/export/Documents` directly. This allows Backrest to start while
the systemd NFS automount is unavailable and makes the Documents submount
visible if it is mounted later.

The Backrest service runs as the dedicated FreeIPA UID/GID `175200010`, which has read access to `/export/Documents` over Kerberized NFS. A one-shot `backrest-init` service owns the named state volumes for that UID before Backrest starts.

The init service also grants group read permission on the unseal key. Backrest
joins its remapped Vault group (`100100`) and mounts only that file read-only;
the private parent directory retains its existing permissions. Recreate the stack
with `docker compose up -d --force-recreate` after replacing or rotating the key
so the file mount and permissions refresh.

The service does not use privileged mode, does not mount the Docker socket, and does not mount host root.

## Operations

Validate the Compose model:

```sh
docker compose config
```

Start Backrest:

```sh
docker compose up -d
```

Test the running Docker backup plan, restore its unseal key and newest Vault
archive from B2, and unseal an isolated Vault using the restored files:

```sh
bash tests/backup-restore.sh
```

The test uses the running Vault image with networking disabled, keeps its Vault
storage in temporary memory, and removes its container and restored files on exit.

After first start:

1. Confirm `backrest.${DOCKER_DOMAIN}` loads through Authelia.
2. Let Backrest initialize `b2:enucatl-backups:restic`.
3. Run the `docker` plan manually once.
4. Verify a snapshot exists.
5. Restore at least one small file to a temporary path before relying on the migration.

Keep the old Duplicati configuration volume and remote backup data until one manual and one scheduled Backrest run have both been restore-tested.
