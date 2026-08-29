#!/bin/sh
# Zero-downtime deploy: rollout the request-facing services in order, then
# recreate the rest (queues/scheduler/configurator tolerate a brief restart).
#
#   ./rollout.sh .env.alphafitness
#
# Requires the `docker rollout` cli-plugin: https://github.com/Wowu/docker-rollout
set -eu

ENV_FILE=${1:?Usage: $0 <env-file>}

# Migrate with the new image before swapping anything: this one-off container
# does the slow schema work while the old containers keep serving requests, so
# the rollout below is only a container swap.
docker compose --env-file "$ENV_FILE" run --rm backend bench --site all migrate

for service in frontend backend websocket; do
  docker rollout --env-file "$ENV_FILE" "$service" \
    --pre-stop-hook "touch /tmp/drain && sleep 10"
done

docker compose --env-file "$ENV_FILE" up -d --no-deps \
  configurator queue-short queue-long scheduler

# Frappe caches assets.json in redis and each gunicorn worker keeps its own
# copy in memory for 10 minutes (ClientCache.local_ttl), so containers can
# still render the previous build's asset hashes for a while after the swap.
# Those files stay in the shared assets volume, so they are served fine — this
# delete only makes the new hashes take effect sooner.
#
# It has to be done by hand: the key is written shared (plain `assets_json`)
# but `bench clear-cache` deletes it unshared, as `<db_name>|assets_json`.
docker compose --env-file "$ENV_FILE" exec -T redis-cache redis-cli DEL assets_json
docker compose --env-file "$ENV_FILE" exec -T backend bench --site all clear-cache
