"""Ephemeral GPU worker for ONE session (one stack per session).

Reads the persistent base stack's outputs through a StackReference, which is
read-only: this project never owns, modifies, or deletes the control plane,
VPC, subnet, or base firewall. It creates only: one GPU instance and one
session-owned firewall. No volumes or other persistent storage are created.

Expiry tags are policy metadata only; they delete nothing. Enforcement is the
independent reaper (scripts/gpu-reaper.sh).
"""

import ipaddress
import re

import pulumi
import pulumi_linode as linode

LAB_REGION = "us-ord"

cfg = pulumi.Config()
base_stack = cfg.require("baseStack")
session_id = cfg.require("sessionId")
expires_epoch = cfg.require_int("expiresEpoch")
gpu_type = cfg.require("gpuType")
admin_cidr = cfg.require("adminCidr")
ssh_key = cfg.require("sshPublicKey")
gpu_vpc_ip = cfg.get("gpuVpcIp") or "10.0.0.20"
image = cfg.get("image") or "linode/ubuntu24.04"

if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", session_id) or len(session_id) > 24:
    raise ValueError("sessionId must be lowercase letters/digits/dashes, max 24")
if "gpu" not in gpu_type:
    raise ValueError(f"gpuType must be a GPU plan (e.g. g2-gpu-...), got {gpu_type}")
if admin_cidr in ("0.0.0.0/0", "::/0"):
    raise ValueError("adminCidr must be your own address, not the whole internet")
ipaddress.ip_address(gpu_vpc_ip)

base = pulumi.StackReference(base_stack)
region = base.require_output("region")
subnet_id = base.require_output("vpc_subnet_id")
subnet_cidr = base.require_output("vpc_subnet_cidr")


def _check_region(r: str) -> str:
    if r != LAB_REGION:
        raise ValueError(f"base stack region must be {LAB_REGION}, got {r}")
    return r


tags = [
    "llm-inference-lab",
    "llm-gpu-session",  # marker the reaper filters on
    f"llm-session-{session_id}",
    f"llm-exp-{expires_epoch}",
]

gpu = linode.Instance(
    "gpu",
    label=f"llm-gpu-{session_id}",
    region=region.apply(_check_region),
    type=gpu_type,
    image=image,
    authorized_keys=[ssh_key],  # key-only: no root password
    interface_generation="legacy_config",
    interfaces=[
        linode.InstanceInterfaceArgs(purpose="public", primary=True),
        linode.InstanceInterfaceArgs(
            purpose="vpc",
            subnet_id=subnet_id.apply(int),
            ipv4=linode.InstanceInterfaceIpv4Args(vpc=gpu_vpc_ip),
        ),
    ],
    tags=tags,
)

# Session-owned firewall: a Linode can have only one firewall, so the GPU node
# gets its own instead of being added to the base firewall.
session_firewall = linode.Firewall(
    "session-firewall",
    label=f"llm-gpu-{session_id}-fw",
    inbound_policy="DROP",
    outbound_policy="ACCEPT",
    inbounds=[
        linode.FirewallInboundArgs(
            action="ACCEPT",
            label="admin-ssh",
            protocol="TCP",
            ports="22",
            ipv4s=[admin_cidr],
        ),
        linode.FirewallInboundArgs(
            action="ACCEPT",
            label="vpc-kubelet",
            protocol="TCP",
            ports="10250",
            ipv4s=[subnet_cidr],
        ),
        linode.FirewallInboundArgs(
            action="ACCEPT",
            label="vpc-flannel-vxlan",
            protocol="UDP",
            ports="8472",
            ipv4s=[subnet_cidr],
        ),
    ],
    linodes=[gpu.id.apply(int)],
    tags=tags,
)

pulumi.export("session_id", session_id)
pulumi.export("expires_epoch", expires_epoch)
pulumi.export("gpu_ip", gpu.ip_address)
pulumi.export("gpu_vpc_ip", gpu_vpc_ip)
pulumi.export("gpu_instance_id", gpu.id)
pulumi.export("session_firewall_id", session_firewall.id)
