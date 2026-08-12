resource "random_uuid" "existing_server_adoption" {
  count = var.existing_server_id == null ? 0 : 1
}

data "hcloud_server" "existing" {
  count = var.existing_server_id == null ? 0 : 1

  id = var.existing_server_id
}

resource "local_sensitive_file" "existing_server_cloud_init" {
  count = var.existing_server_id == null ? 0 : 1

  filename        = "${path.root}/.terraform/kube-hetzner-existing-${var.existing_server_id}-cloud-init"
  content         = data.cloudinit_config.config.rendered
  file_permission = "0600"
}

resource "local_sensitive_file" "existing_server_desired_state" {
  count = var.existing_server_id == null ? 0 : 1

  filename = "${path.root}/.terraform/kube-hetzner-existing-${var.existing_server_id}-desired-state.json"
  content = jsonencode(merge(local.existing_server_desired_state, {
    user_data_file = local_sensitive_file.existing_server_cloud_init[0].filename
  }))
  file_permission = "0600"
}

resource "terraform_data" "adopt_existing_server" {
  count = var.existing_server_id == null ? 0 : 1

  triggers_replace = {
    server_id = tostring(var.existing_server_id)
  }

  provisioner "local-exec" {
    command = "bash \"${path.module}/scripts/adopt-existing-server.sh\" \"${local_sensitive_file.existing_server_desired_state[0].filename}\""
  }

  depends_on = [hcloud_server.server, hcloud_server_network.extra_networks]

  lifecycle {
    precondition {
      condition     = tonumber(hcloud_server.server.id) == var.existing_server_id
      error_message = "existing_server_id ${var.existing_server_id} must first be imported into this node's hcloud_server.server resource address."
    }
    precondition {
      condition     = !contains(keys(var.labels), "kube-hetzner-adoption")
      error_message = "kube-hetzner-adoption is reserved for the one-time existing server completion marker and must not be set through hcloud_labels."
    }
    precondition {
      condition     = data.hcloud_server.existing[0].location == var.location
      error_message = "existing_server_id ${var.existing_server_id} is in ${data.hcloud_server.existing[0].location}, but this node declares ${var.location}."
    }
    precondition {
      condition     = data.hcloud_server.existing[0].server_type == var.server_type
      error_message = "existing_server_id ${var.existing_server_id} has type ${data.hcloud_server.existing[0].server_type}, but this node declares ${var.server_type}; changing type during adoption could forfeit legacy pricing."
    }
    precondition {
      condition     = !data.hcloud_server.existing[0].delete_protection && !data.hcloud_server.existing[0].rebuild_protection
      error_message = "existing_server_id ${var.existing_server_id} has delete or rebuild protection enabled; disable both explicitly before adoption."
    }
  }
}
