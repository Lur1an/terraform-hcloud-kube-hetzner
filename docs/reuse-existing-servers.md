# Reuse Existing Hetzner Cloud Servers

`existing_server_id` adds an already allocated Hetzner Cloud server to an
existing kube-hetzner cluster without giving up its server ID, capacity, or
legacy pricing. Terraform's normal `hetznercloud/hcloud` provider owns the
server after it is imported. No provider fork is required.

## Destructive Behavior

Adoption performs a Hetzner **server rebuild**. The donor's root disk is erased
and replaced with the Leap Micro or MicroOS snapshot and cloud-init generated
for the new kube-hetzner node.

- The server ID, location, server type, and declared cloud resources are reused.
- The donor is imported into the node's normal `hcloud_server.server` resource.
- The module prepares and rebuilds the server once before Kubernetes bootstrap.
- Removing `existing_server_id` after adoption does not remove or replace the server.
- Removing the logical node or destroying the cluster deletes the imported server.
- Terraform state is not a backup of the old root disk.

Use this only for surplus servers that may be erased and joined as new nodes.
Do not use it to re-adopt a server already represented by an `hcloud_server` in
the same Terraform state.

## Prerequisites

Install these tools on the machine that runs Terraform or OpenTofu:

- Bash
- [`hcloud`](https://github.com/hetznercloud/cli) CLI version 1.67.0 or newer
- `jq`

Export `HCLOUD_TOKEN` in the runner environment for the adoption apply. The
normal HCloud provider may receive the same token through the module's
`hcloud_token` input. Later plans and destroy use the provider normally and do
not require the adoption helper's environment variable.

Prepare every donor server as follows:

1. Verify it belongs to the same Hetzner project as `hcloud_token`.
2. Disable delete and rebuild protection.
3. Detach all Hetzner Volumes. Rebuild only erases the root disk.
4. Unassign all Floating IPs so Terraform can establish unambiguous ownership.
5. Configure the node's `server_type` and `location` to exactly match the donor.
6. Ensure the selected kube-hetzner snapshot supports the donor architecture.
7. Back up the Terraform state and all data that must survive adoption.

## Configure The Node

Use an explicit `nodes` map because one physical server ID must map to one
stable logical node. `existing_server_id` is available for control-plane and
static agent nodes; it is not available on count-based or autoscaler pools.

```hcl
agent_nodepools = [
  {
    name        = "worker"
    server_type = "cx23"
    location    = "fsn1"
    labels      = []
    taints      = []

    nodes = {
      "0" = {
        existing_server_id = 12345679
      }
      "1" = {} # Created normally by kube-hetzner.
    }
  }
]
```

The donor's effective networking, Primary IP, firewall, placement-group, and
backup configuration must match the node declaration or be safe to reconcile
during the destructive adoption apply.

## Import Before Apply

Adding the node puts its ordinary `hcloud_server.server` resource in
configuration. Import the donor into that exact address **before running a full
apply**. If a plan says that Terraform will create the server, stop: the import
is missing or targets the wrong address.

For a root module named `kube-hetzner`, pool index `0`, node key `0`, and pool
name `worker`, import an agent with:

```bash
terraform import \
  'module.kube-hetzner.module.agents["0-0-worker"].hcloud_server.server' \
  12345679
```

The equivalent control-plane address is:

```bash
terraform import \
  'module.kube-hetzner.module.control_planes["0-0-control-plane"].hcloud_server.server' \
  12345678
```

Replace the root module label, pool index, node key, and pool name with values
from the target configuration. OpenTofu users can run the same commands with
`tofu import`.

The module verifies during apply that the managed `hcloud_server` ID equals
`existing_server_id`. This prevents the helper from rebuilding a donor that was
not imported into the intended logical node. It cannot prevent Terraform from
planning a separate new server when import was skipped, so reviewing the plan
remains mandatory.

Setting `existing_server_id` and importing that exact ID into the documented
resource address is the explicit authorization to erase the donor. No separate
Hetzner label is required.

## Review And Apply

Create and inspect a saved plan:

```bash
terraform plan -out=adopt-existing-server.tfplan
terraform show adopt-existing-server.tfplan
```

The plan must not create, replace, or delete the imported `hcloud_server`.
Review all planned changes to its Networks, Primary IPs, firewalls, labels,
backups, and placement group. Then apply the reviewed plan:

```bash
terraform apply adopt-existing-server.tfplan
```

The apply:

1. Confirms the imported resource ID exactly matches `existing_server_id`.
2. Applies the declared server-level configuration.
3. Rebuilds the root disk from the selected snapshot and cloud-init.
4. Writes a state-specific adoption marker only after rebuild succeeds.
5. Waits for the operating system and SSH.
6. Runs the normal host configuration and Kubernetes bootstrap pipeline.

## Remove The Temporary ID

After the new Kubernetes node is healthy, remove `existing_server_id` while
leaving the `nodes` entry and its key unchanged:

```hcl
nodes = {
  "0" = {}
  "1" = {}
}
```

Run another plan and apply. Terraform removes only one-time adoption metadata
and local files. The normal `hcloud_server.server` remains at the same resource
address with the same Hetzner server ID. All future reads, updates, and deletion
are handled by the official HCloud provider exactly like a server it created.

## Failure Recovery

If adoption fails before rebuild, correct the reported mismatch and apply
again. The imported resource ID remains the authorization for a retry.

If adoption fails during or after rebuild, the old root disk may already be
gone. Fix the error and rerun `terraform apply`; a retry may rebuild the donor
again before Kubernetes bootstrap. Do not remove `existing_server_id` until the
node is healthy and the adoption apply has completed.

If the imported server is deleted outside Terraform, kube-hetzner cannot
recreate the same ID or pricing allocation. Import another prepared donor into
the same logical node only after deliberately repairing its Terraform state.
