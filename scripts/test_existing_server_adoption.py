#!/usr/bin/env python3
"""Stateful fake-HCloud tests for destructive existing-server adoption."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
ADOPTION_SCRIPT = REPO_ROOT / "modules" / "host" / "scripts" / "adopt-existing-server.sh"

DONOR = {
    "id": 123,
    "name": "donor",
    "status": "running",
    "location": {"name": "fsn1"},
    "server_type": {"name": "cx23"},
    "protection": {"delete": False, "rebuild": False},
    "volumes": [],
    "labels": {"stale": "value"},
    "backup_window": None,
    "placement_group": None,
    "private_net": [{"network": 10, "ip": "10.0.0.101", "alias_ips": ["10.0.0.200"]}],
    "public_net": {
        "ipv4": {"id": 11},
        "ipv6": {"id": 0},
        "floating_ips": [],
    },
    "_firewalls": [
        {"id": 22, "applied_to": [{"type": "server", "server": {"id": 123}}]},
        {"id": 44, "applied_to": []},
    ],
}

DESIRED = {
    "server_id": 123,
    "name": "cluster-worker",
    "location": "fsn1",
    "server_type": "cx23",
    "image_id": "456",
    "labels": {"cluster": "test", "empty": "", "kube-hetzner-adoption": "abc"},
    "backups": False,
    "firewall_ids": [44],
    "placement_group_id": 33,
    "networks": [{"id": 10, "ip": "10.0.0.101"}, {"id": 20, "ip": None}],
    "public": {
        "ipv4": {"enabled": True, "primary_ip_id": None},
        "ipv6": {"enabled": False, "primary_ip_id": None},
    },
}

FAKE_HCLOUD = r'''#!/usr/bin/env python3
import json
import os
import sys

path = os.environ["HCLOUD_TEST_STATE"]
log = os.environ["HCLOUD_TEST_LOG"]
args = sys.argv[1:]
with open(log, "a", encoding="utf-8") as stream:
    stream.write(" ".join(args) + "\n")

if args == ["server", "rebuild", "--help"]:
    print("--user-data-from-file filename")
    raise SystemExit(0)

with open(path, encoding="utf-8") as stream:
    server = json.load(stream)

def save():
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(server, stream)

if args[:4] == ["server", "describe", "-o", "json"]:
    if server.get("_describe_failures_remaining", 0) > 0:
        server["_describe_failures_remaining"] -= 1
        save()
        raise SystemExit(1)
    print(json.dumps({key: value for key, value in server.items() if not key.startswith("_")}))
elif args[:4] == ["server", "list", "-o", "json"]:
    public_server = {key: value for key, value in server.items() if not key.startswith("_")}
    print(json.dumps([] if server.get("deleted") else [public_server]))
elif args[:4] == ["firewall", "list", "-o", "json"]:
    print(json.dumps(server["_firewalls"]))
elif args[:3] == ["server", "update", "--name"]:
    server["name"] = args[3]
    save()
elif args[:3] == ["server", "remove-label", "--label"]:
    server["labels"].pop(args[3], None)
    save()
elif args[:3] == ["server", "add-label", "--label"]:
    key, value = args[3].split("=", 1)
    server["labels"][key] = value
    save()
elif args[:2] == ["server", "poweroff"]:
    server["status"] = "off"
    save()
elif args[:2] == ["server", "poweron"]:
    server["status"] = "running"
    save()
elif args[:2] == ["server", "add-to-placement-group"]:
    group_id = int(args[3])
    if group_id == 99:
        raise SystemExit(1)
    server["placement_group"] = {"id": group_id}
    save()
elif args[:2] == ["server", "remove-from-placement-group"]:
    server["placement_group"] = None
    save()
elif args[:2] == ["server", "detach-from-network"]:
    network_id = int(args[3])
    server["private_net"] = [item for item in server["private_net"] if item["network"] != network_id]
    save()
elif args[:2] == ["server", "attach-to-network"]:
    network_id = int(args[3])
    ip = args[5] if len(args) > 5 and args[4] == "--ip" else "10.0.0.250"
    server["private_net"].append({"network": network_id, "ip": ip, "alias_ips": []})
    save()
elif args[:2] == ["server", "change-alias-ips"]:
    network_id = int(args[3])
    for item in server["private_net"]:
        if item["network"] == network_id:
            item["alias_ips"] = []
    save()
elif args[:2] == ["firewall", "remove-from-resource"]:
    firewall_id = int(args[-1])
    firewall = next(item for item in server["_firewalls"] if item["id"] == firewall_id)
    firewall["applied_to"] = [
        item
        for item in firewall["applied_to"]
        if item.get("type") != "server" or item["server"]["id"] != server["id"]
    ]
    save()
elif args[:2] == ["firewall", "apply-to-resource"]:
    firewall = next(item for item in server["_firewalls"] if item["id"] == int(args[-1]))
    firewall["applied_to"].append({"type": "server", "server": {"id": server["id"]}})
    save()
elif args[:2] == ["server", "rebuild"]:
    if os.environ.get("HCLOUD_TEST_FAIL_REBUILD") == "1":
        server["status"] = "off"
        server["_describe_failures_remaining"] = 1
        save()
        raise SystemExit(1)
    server["image"] = {"id": int(args[3])}
    server["status"] = "running"
    server["rebuild_count"] = server.get("rebuild_count", 0) + 1
    save()
elif args[:2] == ["server", "delete"]:
    server["deleted"] = True
    save()
else:
    print(f"unsupported fake hcloud command: {args}", file=sys.stderr)
    raise SystemExit(2)
'''


def run_helper(desired_path: Path, environment: dict[str, str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(ADOPTION_SCRIPT), str(desired_path)],
        check=check,
        env=environment,
        text=True,
        capture_output=not check,
    )


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="kh-existing-server-") as temp_dir_name:
        temp_dir = Path(temp_dir_name)
        state_path = temp_dir / "server.json"
        desired_path = temp_dir / "desired.json"
        log_path = temp_dir / "hcloud.log"
        fake_hcloud = temp_dir / "hcloud"
        cloud_init_path = temp_dir / "cloud-init"

        fake_hcloud.write_text(FAKE_HCLOUD, encoding="utf-8")
        fake_hcloud.chmod(0o755)
        cloud_init_path.write_text("#cloud-config\n", encoding="utf-8")
        desired_path.write_text(json.dumps({**DESIRED, "user_data_file": str(cloud_init_path)}), encoding="utf-8")

        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{temp_dir}:{environment['PATH']}",
                "HCLOUD_TOKEN": "test-token",
                "HCLOUD_TEST_LOG": str(log_path),
                "HCLOUD_TEST_STATE": str(state_path),
            }
        )

        no_token_environment = environment.copy()
        no_token_environment.pop("HCLOUD_TOKEN")
        state_path.write_text(json.dumps(DONOR), encoding="utf-8")
        no_token = run_helper(desired_path, no_token_environment, check=False)
        assert no_token.returncode != 0
        assert "requires HCLOUD_TOKEN" in no_token.stderr

        rebuild_failure_environment = {**environment, "HCLOUD_TEST_FAIL_REBUILD": "1"}
        state_path.write_text(json.dumps(DONOR), encoding="utf-8")
        rebuild_failure = run_helper(desired_path, rebuild_failure_environment, check=False)
        assert rebuild_failure.returncode != 0
        failed_rebuild_donor = json.loads(state_path.read_text(encoding="utf-8"))
        assert failed_rebuild_donor["status"] == "running"
        assert "kube-hetzner-adoption" not in failed_rebuild_donor["labels"]

        state_path.write_text(json.dumps(DONOR), encoding="utf-8")
        run_helper(desired_path, environment)
        adopted = json.loads(state_path.read_text(encoding="utf-8"))
        assert adopted["id"] == DONOR["id"]
        assert adopted["name"] == DESIRED["name"]
        assert adopted["labels"] == DESIRED["labels"]
        assert adopted["placement_group"] == {"id": 33}
        assert {item["network"] for item in adopted["private_net"]} == {10, 20}
        assert all(not item["alias_ips"] for item in adopted["private_net"])
        attached_firewalls = [
            firewall["id"]
            for firewall in adopted["_firewalls"]
            if any(item.get("server", {}).get("id") == adopted["id"] for item in firewall["applied_to"])
        ]
        assert attached_firewalls == [44]
        assert adopted["image"] == {"id": 456}
        assert adopted["rebuild_count"] == 1

        run_helper(desired_path, environment)
        completed_retry = json.loads(state_path.read_text(encoding="utf-8"))
        assert completed_retry["rebuild_count"] == 1

        failing_desired = {**DESIRED, "placement_group_id": 99, "user_data_file": str(cloud_init_path)}
        desired_path.write_text(json.dumps(failing_desired), encoding="utf-8")
        state_path.write_text(json.dumps(DONOR), encoding="utf-8")
        failed = run_helper(desired_path, environment, check=False)
        assert failed.returncode != 0
        partially_adopted = json.loads(state_path.read_text(encoding="utf-8"))
        assert partially_adopted["status"] == "running"
        assert "kube-hetzner-adoption" not in partially_adopted["labels"]
        assert "rebuild_count" not in partially_adopted
        retry = run_helper(desired_path, environment, check=False)
        assert retry.returncode != 0

    print("PASS existing server adoption: identity, transition, idempotency, and power recovery")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
