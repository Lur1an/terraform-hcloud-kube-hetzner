#!/usr/bin/env bash
set -euo pipefail

state_file="${1:?usage: adopt-existing-server.sh <desired-state.json>}"
: "${HCLOUD_TOKEN:?existing_server_id adoption requires HCLOUD_TOKEN in the runner environment}"

for command in hcloud jq; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "existing_server_id requires $command to be installed on the machine running Terraform" >&2
    exit 1
  fi
done

server_id="$(jq -er '.server_id' "$state_file")"
restore_power_on_exit=false

restore_server_power() {
  status=$?
  trap - EXIT
  if [ "$restore_power_on_exit" = "true" ]; then
    attempt=0
    while [ "$attempt" -lt 12 ]; do
      current_status="$(hcloud server describe -o json "$server_id" 2>/dev/null | jq -r '.status // empty' 2>/dev/null || true)"
      if [ -n "$current_status" ] && [ "$current_status" != "off" ]; then
        break
      fi
      if hcloud server poweron "$server_id" >/dev/null 2>&1; then
        break
      fi
      sleep 5
      attempt=$((attempt + 1))
    done
  fi
  exit "$status"
}
trap restore_server_power EXIT

rebuild_help="$(hcloud server rebuild --help)"
if [[ "$rebuild_help" != *"--user-data-from-file"* ]]; then
  echo "existing_server_id requires an hcloud CLI with server rebuild --user-data-from-file support (1.67.0 or newer)" >&2
  exit 1
fi

server_json() {
  hcloud server describe -o json "$server_id"
}

ensure_powered_off() {
  if [ "$(server_json | jq -r '.status')" != "off" ]; then
    hcloud server poweroff "$server_id"
    restore_power_on_exit=true
  fi
}

ensure_powered_on() {
  if [ "$(server_json | jq -r '.status')" = "off" ]; then
    hcloud server poweron "$server_id"
  fi
  restore_power_on_exit=false
}

server="$(server_json)"

actual_location="$(jq -r '.location.name // .location' <<<"$server")"
actual_server_type="$(jq -r '.server_type.name // .server_type' <<<"$server")"
desired_location="$(jq -r '.location' "$state_file")"
desired_server_type="$(jq -r '.server_type' "$state_file")"
actual_image="$(jq -r '(.image.id // .image.name // .image // "") | tostring' <<<"$server")"
desired_image="$(jq -r '.image_id | tostring' "$state_file")"

desired_adoption_id="$(jq -er '.labels["kube-hetzner-adoption"]' "$state_file")"
if [ "$(jq -r '.labels["kube-hetzner-adoption"] // ""' <<<"$server")" = "$desired_adoption_id" ] &&
  [ "$actual_image" = "$desired_image" ] &&
  jq -e --argjson desired "$(jq -c '.labels' "$state_file")" '.labels == $desired' <<<"$server" >/dev/null; then
  exit 0
fi
if [ "$actual_location" != "$desired_location" ]; then
  echo "existing server $server_id is in $actual_location, but this node declares $desired_location" >&2
  exit 1
fi
if [ "$actual_server_type" != "$desired_server_type" ]; then
  echo "existing server $server_id has type $actual_server_type, but this node declares $desired_server_type; changing type during adoption could forfeit legacy pricing" >&2
  exit 1
fi
if [ "$(jq -r '.protection.delete // .delete_protection // false' <<<"$server")" = "true" ] ||
  [ "$(jq -r '.protection.rebuild // .rebuild_protection // false' <<<"$server")" = "true" ]; then
  echo "existing server $server_id has delete or rebuild protection enabled; disable both explicitly before adoption" >&2
  exit 1
fi
if [ "$(jq '.volumes | length' <<<"$server")" -ne 0 ]; then
  echo "existing server $server_id has attached volumes; detach them before adoption because rebuild only wipes the root disk" >&2
  exit 1
fi
if [ "$(jq '.public_net.floating_ips | length' <<<"$server")" -ne 0 ]; then
  echo "existing server $server_id has assigned Floating IPs; unassign them before adoption so Terraform can establish unambiguous ownership" >&2
  exit 1
fi

desired_name="$(jq -r '.name' "$state_file")"
if [ "$(jq -r '.name' <<<"$server")" != "$desired_name" ]; then
  hcloud server update --name "$desired_name" "$server_id"
fi

server="$(server_json)"
desired_backups="$(jq -r '.backups' "$state_file")"
actual_backups="$(jq -r '(.backup_window // "") != ""' <<<"$server")"
if [ "$desired_backups" != "$actual_backups" ]; then
  if [ "$desired_backups" = "true" ]; then
    hcloud server enable-backup "$server_id"
  else
    hcloud server disable-backup "$server_id"
  fi
fi

server="$(server_json)"
desired_placement_group="$(jq -r '.placement_group_id // ""' "$state_file")"
actual_placement_group="$(jq -r '.placement_group.id // .placement_group_id // ""' <<<"$server")"
if [ "$actual_placement_group" != "$desired_placement_group" ]; then
  ensure_powered_off
  if [ -n "$actual_placement_group" ]; then
    hcloud server remove-from-placement-group "$server_id"
  fi
  if [ -n "$desired_placement_group" ]; then
    hcloud server add-to-placement-group --placement-group "$desired_placement_group" "$server_id"
  fi
  ensure_powered_on
fi

server="$(server_json)"
while IFS= read -r network_id; do
  if ! jq -e --argjson id "$network_id" '.networks[] | select(.id == $id)' "$state_file" >/dev/null; then
    hcloud server detach-from-network --network "$network_id" "$server_id"
  fi
done < <(jq -r '.private_net[].network' <<<"$server")

while IFS=$'\t' read -r network_id desired_ip; do
  server="$(server_json)"
  actual_ip="$(jq -r --argjson id "$network_id" '.private_net[] | select(.network == $id) | .ip' <<<"$server")"
  if [ -n "$actual_ip" ] && [ -n "$desired_ip" ] && [ "$actual_ip" != "$desired_ip" ]; then
    hcloud server detach-from-network --network "$network_id" "$server_id"
    actual_ip=""
  fi
  if [ -z "$actual_ip" ]; then
    if [ -n "$desired_ip" ]; then
      hcloud server attach-to-network --network "$network_id" --ip "$desired_ip" "$server_id"
    else
      hcloud server attach-to-network --network "$network_id" "$server_id"
    fi
  fi
  server="$(server_json)"
  if [ "$(jq --argjson id "$network_id" '[.private_net[] | select(.network == $id) | .alias_ips[]] | length' <<<"$server")" -ne 0 ]; then
    hcloud server change-alias-ips --network "$network_id" --clear "$server_id"
  fi
done < <(jq -r '.networks[] | [.id, (.ip // "")] | @tsv' "$state_file")

attached_firewall_ids="$(
  hcloud firewall list -o json |
    jq -c --argjson server_id "$server_id" '[.[] | select(any(.applied_to[]?; .type == "server" and .server.id == $server_id)) | .id]'
)"
while IFS= read -r firewall_id; do
  if ! jq -e --argjson id "$firewall_id" '.firewall_ids | index($id)' "$state_file" >/dev/null; then
    hcloud firewall remove-from-resource --type server --server "$server_id" "$firewall_id"
  fi
done < <(jq -r '.[]' <<<"$attached_firewall_ids")

while IFS= read -r firewall_id; do
  if ! jq -e --argjson id "$firewall_id" 'index($id)' <<<"$attached_firewall_ids" >/dev/null; then
    hcloud firewall apply-to-resource --type server --server "$server_id" "$firewall_id"
  fi
done < <(jq -r '.firewall_ids[]' "$state_file")

server="$(server_json)"
public_network_changed=false
for family in ipv4 ipv6; do
  enabled="$(jq -r ".public.$family.enabled" "$state_file")"
  desired_primary_ip="$(jq -r ".public.$family.primary_ip_id // \"\"" "$state_file")"
  actual_primary_ip="$(jq -r "if (.public_net.$family.id // 0) > 0 then .public_net.$family.id else \"\" end" <<<"$server")"

  if [ "$enabled" = "false" ] && [ -n "$actual_primary_ip" ]; then
    ensure_powered_off
    hcloud primary-ip unassign "$actual_primary_ip"
    public_network_changed=true
  elif [ "$enabled" = "true" ] && [ -n "$desired_primary_ip" ] && [ "$actual_primary_ip" != "$desired_primary_ip" ]; then
    ensure_powered_off
    if [ -n "$actual_primary_ip" ]; then
      hcloud primary-ip unassign "$actual_primary_ip"
    fi
    hcloud primary-ip assign --server "$server_id" "$desired_primary_ip"
    public_network_changed=true
  elif [ "$enabled" = "true" ] && [ -z "$actual_primary_ip" ] && [ -z "$desired_primary_ip" ]; then
    echo "existing server $server_id has no public $family Primary IP; provide primary_${family}_id or enable primary_ip_pool" >&2
    exit 1
  fi
done
if [ "$public_network_changed" = "true" ]; then
  ensure_powered_on
fi

restore_power_on_exit=true
hcloud server rebuild \
  --image "$desired_image" \
  --user-data-from-file "$(jq -r '.user_data_file' "$state_file")" \
  "$server_id"
restore_power_on_exit=false

# Publish the adoption UUID only after rebuild succeeds. A later retry can then
# recognize the completed transition without rebuilding the server again.
server="$(server_json)"
while IFS=$'\t' read -r key value; do
  if ! jq -e --arg key "$key" --arg value "$value" '.labels | has($key) and .[$key] == $value' <<<"$server" >/dev/null; then
    hcloud server add-label --label "$key=$value" "$server_id"
  fi
done < <(jq -r '.labels | to_entries[] | [.key, .value] | @tsv' "$state_file")

server="$(server_json)"
while IFS= read -r key; do
  if ! jq -e --arg key "$key" '.labels | has($key)' "$state_file" >/dev/null; then
    hcloud server remove-label --label "$key" "$server_id"
  fi
done < <(jq -r '.labels | keys[]' <<<"$server")
