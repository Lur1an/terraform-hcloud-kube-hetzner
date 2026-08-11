output "ipv4_address" {
  value      = local.server_ipv4_address
  depends_on = [terraform_data.initial_readiness, terraform_data.os_upgrade_timer]
}

output "ipv6_address" {
  value      = local.server_ipv6_address
  depends_on = [terraform_data.initial_readiness, terraform_data.os_upgrade_timer]
}

output "private_ipv4_address" {
  value      = try([for network in local.server_networks : network.ip if network.network_id == var.network_id][0], "")
  depends_on = [terraform_data.initial_readiness, terraform_data.os_upgrade_timer]
}

output "name" {
  value      = local.server_name
  depends_on = [terraform_data.initial_readiness, terraform_data.os_upgrade_timer]
}

output "id" {
  value      = local.server_id
  depends_on = [terraform_data.initial_readiness, terraform_data.os_upgrade_timer]
}

output "domain_assignments" {
  description = "Assignment of domain to the primary IP of the server"
  value = [
    for rdns in hcloud_rdns.server : {
      domain = rdns.dns_ptr
      ips    = [rdns.ip_address]
    }
  ]
}
