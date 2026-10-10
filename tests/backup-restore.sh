#!/usr/bin/env bash
# Exercises the running docker plan and restores Vault into an isolated container.
set -euo pipefail
set +x

backrest=$(docker compose ps -q backrest)
test -n "$backrest"
key=/source/var/lib/docker/100000.100000/volumes/infra_vault_unseal/_data/key
restore_dir=$(docker exec "$backrest" mktemp -d /tmp/backup-restore.XXXXXX)
vault_test="backrest-vault-restore-${restore_dir##*.}"
cleanup() {
  docker rm -f "$vault_test" >/dev/null 2>&1 || true
  docker exec "$backrest" rm -rf "$restore_dir"
}
trap cleanup EXIT

api() {
  docker exec "$backrest" curl -fsS --max-time 30 -X POST \
    -H 'Content-Type: application/json' -d "$2" \
    "http://127.0.0.1:9898/v1.Backrest/$1"
}
restic() {
  docker exec "$backrest" sh -eu -c '
    export B2_ACCOUNT_ID=$(tr -d "\r\n" < /run/secrets/backrest_b2_account_id)
    export B2_ACCOUNT_KEY=$(tr -d "\r\n" < /run/secrets/backrest_b2_account_key)
    export RESTIC_PASSWORD=$(tr -d "\r\n" < /run/secrets/backrest_repo_password)
    exec /bin/restic -r b2:enucatl-backups:restic "$@"
  ' sh "$@"
}

started=$(date +%s%3N)
api Backup '{"value":"docker"}' >/dev/null
deadline=$((SECONDS + 1800))
snapshot=
while (( SECONDS < deadline )); do
  operations=$(api GetOperations '{"selector":{"planId":"docker"},"lastN":"1000"}')
  backup=$(jq -c --argjson started "$started" '
    [.operations[]? | select(.operationBackup and
      (.unixTimeStartMs | tonumber) >= $started and
      (.unixTimeStartMs | tonumber) <= (now * 1000))]
    | sort_by(.unixTimeStartMs | tonumber) | last // empty
  ' <<< "$operations")
  status=$(jq -r '.status // empty' <<< "$backup")
  case "$status" in
    STATUS_ERROR|STATUS_WARNING|STATUS_CANCELLED|STATUS_SYSTEM_CANCELLED)
      echo "Backrest backup failed: $status" >&2; exit 1 ;;
    STATUS_SUCCESS)
      snapshot=$(jq -r '.snapshotId // empty' <<< "$backup")
      flow=$(jq -r '.flowId' <<< "$backup")
      if jq -e --arg flow "$flow" '
        any(.operations[]; .flowId == $flow and
          (.status == "STATUS_ERROR" or .status == "STATUS_WARNING"))
      ' <<< "$operations" >/dev/null; then
        echo 'Backrest workflow failed after backup.' >&2; exit 1
      fi
      if jq -e --arg flow "$flow" '
        [.operations[] | select(.flowId == $flow)]
        | all(.status == "STATUS_SUCCESS")
      ' <<< "$operations" >/dev/null; then break; fi ;;
  esac
  sleep 5
done
(( SECONDS < deadline )) || { echo 'Backup workflow timed out.' >&2; exit 1; }
if [ -z "$snapshot" ]; then
  snapshot=$(restic snapshots --json --tag plan:docker | jq -r 'sort_by(.time) | last.id // empty')
fi
test -n "$snapshot"
echo "Backrest docker workflow succeeded: $snapshot"

restic ls --json "$snapshot" "$key" | jq -e --arg key "$key" \
  'select(.struct_type == "node" and .path == $key and .type == "file")' >/dev/null
archive=$(restic ls --json "$snapshot" /source/scratch/backup/vault | jq -sr '
  [.[] | select(.struct_type == "node" and .type == "file" and
    (.name | startswith("vault-backup-")) and (.name | endswith(".tar.gz")))]
  | sort_by(.name) | last.path // empty
')
test -n "$archive"
restic restore "$snapshot" --target "$restore_dir" --verify \
  --include "$key" --include "$archive"
docker exec "$backrest" cmp -s "$key" "$restore_dir$key"
echo 'Remote key restored and matches the live key byte for byte.'

vault_image=$(docker inspect infra-vault-1 --format '{{.Image}}')
docker run -d --name "$vault_test" --network none --userns host --user 0:0 \
  --cap-drop ALL --security-opt no-new-privileges:true --memory 2g \
  --cpus 1 --pids-limit 128 --read-only \
  --tmpfs /vault/file:rw,noexec,nosuid,size=1g \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  -e HOME=/tmp -e VAULT_ADDR=http://127.0.0.1:8200 --entrypoint /bin/sh "$vault_image" \
  -eu -c '
    while [ ! -f /tmp/ready ]; do sleep 1; done
    exec vault server -config=/tmp/restore.hcl
  ' >/dev/null
docker exec "$backrest" cat "$restore_dir$archive" | \
  docker exec -i "$vault_test" tar -xzof - -C /vault/file --strip-components=7
docker exec -i "$vault_test" sh -eu -c 'cat > /tmp/restore.hcl' <<'HCL'
api_addr = "http://127.0.0.1:8200"
disable_mlock = true
storage "file" {
  path = "/vault/file"
}
listener "tcp" {
  address = "127.0.0.1:8200"
  tls_disable = true
}
HCL
docker exec "$vault_test" touch /tmp/ready
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  state=$(docker exec "$vault_test" vault status -format=json 2>/dev/null || true)
  if jq -e '.initialized == true and .sealed == true' <<< "$state" >/dev/null 2>&1; then break; fi
  sleep 1
done
if (( SECONDS >= deadline )); then
  echo 'Restored Vault failed to start sealed.' >&2
  docker logs --tail 40 "$vault_test" >&2
  docker exec "$vault_test" vault status -format=json >&2 || true
  exit 1
fi
docker exec "$backrest" cat "$restore_dir$key" | \
  docker exec -i "$vault_test" vault write -format=json sys/unseal key=- >/dev/null
docker exec "$vault_test" vault status -format=json | \
  jq -e '.initialized == true and .sealed == false' >/dev/null
echo "Isolated Vault restored from ${archive##*/} and successfully unsealed."
