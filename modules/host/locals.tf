locals {
  ssh_public_key             = trimspace(var.ssh_public_key)
  ssh_additional_public_keys = [for key in var.ssh_additional_public_keys : trimspace(key) if trimspace(key) != ""]
  ssh_authorized_keys        = concat([local.ssh_public_key], local.ssh_additional_public_keys)

  # ssh_agent_identity is not set if the private key is passed directly, but if ssh agent is used, the public key tells ssh agent which private key to use.
  # For terraforms provisioner.connection.agent_identity, we need the public key as a string.
  ssh_agent_identity = var.ssh_private_key == null ? local.ssh_public_key : null

  # the hosts name with its unique suffix attached
  name = var.append_random_suffix ? "${var.name}-${random_string.server.id}" : var.name

  # check if the user has set dns servers
  has_dns_servers = length(var.dns_servers) > 0

  effective_firewall_ids = var.firewall_ids == null ? toset(var.extra_firewall_ids) : setunion(var.firewall_ids, toset(var.extra_firewall_ids))
  extra_network_ids = toset([
    for network_id in var.extra_network_ids : network_id
    if network_id != var.primary_network_key
  ])

  server_id = coalesce(
    try(hcloud_server.server[0].id, null),
    try(data.hcloud_server.existing_ready[0].id, null),
  )
  server_name = var.existing_server_id == null ? hcloud_server.server[0].name : local.name
  server_ipv4_address = var.existing_server_id == null ? hcloud_server.server[0].ipv4_address : try(
    data.hcloud_server.existing_ready[0].ipv4_address,
    null,
  )
  server_ipv6_address = var.existing_server_id == null ? hcloud_server.server[0].ipv6_address : try(
    data.hcloud_server.existing_ready[0].ipv6_address,
    null,
  )
  server_networks = var.existing_server_id == null ? hcloud_server.server[0].network : try(
    data.hcloud_server.existing_ready[0].network,
    [],
  )

  existing_server_desired_state = {
    server_id          = var.existing_server_id
    name               = local.name
    location           = var.location
    server_type        = var.server_type
    image_id           = var.os_snapshot_id
    labels             = merge(var.labels, { "kube-hetzner-adoption" = random_uuid.existing_server_adoption[0].result })
    backups            = var.backups
    firewall_ids       = sort(tolist(local.effective_firewall_ids))
    placement_group_id = var.placement_group_id
    networks = concat(
      [{ id = var.network_id, ip = var.private_ipv4 }],
      [for network_id in sort(tolist(local.extra_network_ids)) : { id = network_id, ip = null }],
    )
    public = {
      ipv4 = {
        enabled       = !var.disable_ipv4
        primary_ip_id = var.primary_ipv4_id
      }
      ipv6 = {
        enabled       = !var.disable_ipv6
        primary_ip_id = var.primary_ipv6_id
      }
    }
  }

  default_connection_host = coalesce(
    local.server_ipv4_address,
    local.server_ipv6_address,
    try(
      [for network in local.server_networks : network.ip if var.network_id != null && network.network_id == var.network_id][0],
      try([for network in local.server_networks : network.ip][0], null)
    )
  )

  map_connection_host = (
    trimspace(lookup(var.node_connection_overrides, local.name, "")) != ""
    ? trimspace(lookup(var.node_connection_overrides, local.name, ""))
    : (
      trimspace(lookup(var.node_connection_overrides, var.name, "")) != ""
      ? trimspace(lookup(var.node_connection_overrides, var.name, ""))
      : null
    )
  )
  suffix_connection_host = trimspace(var.connection_host_suffix) != "" ? "${local.name}.${trim(trimspace(var.connection_host_suffix), ".")}" : null

  provisioner_connection_host = coalesce(
    trimspace(var.connection_host) != "" ? trimspace(var.connection_host) : null,
    local.map_connection_host,
    local.suffix_connection_host,
    local.default_connection_host
  )
}
