"""Persistent base: VPC, one K3s server, and the base firewall.

Contains NO GPU resources. The ephemeral GPU worker lives in ../gpu (a
separate Pulumi project and stack) and only reads this stack's outputs.
Pulumi only creates cloud resources; Ansible installs K3s over SSH.
"""

import ipaddress
import os

import pulumi
import pulumi_linode as linode

# The lab is scoped to us-ord: it is the region with the GPU plans this
# environment targets.
LAB_REGION = "us-ord"

# `pulumi preview` succeeds even with no or a fake token, so a missing token only
# shows up as a failure at the first real API call during `pulumi up`. Fail early.
if not os.environ.get("LINODE_TOKEN") and not pulumi.Config("linode").get("token"):
    raise ValueError(
        "LINODE_TOKEN is not set in this shell. Export a Linode API token, then "
        "check it with ./scripts/check-linode-token.sh"
    )

cfg = pulumi.Config()
region = cfg.get("region") or LAB_REGION
server_type = cfg.require("serverType")
admin_cidr = cfg.require("adminCidr")
ssh_key = cfg.require("sshPublicKey")
prefix = cfg.get("labPrefix") or "llm-lab"
image = cfg.get("image") or "linode/ubuntu24.04"
subnet_cidr = cfg.get("vpcSubnetCidr") or "10.0.0.0/24"
server_vpc_ip = cfg.get("serverVpcIp") or "10.0.0.10"

if region != LAB_REGION:
    raise ValueError(f"region must be {LAB_REGION}, got {region}")
if admin_cidr in ("0.0.0.0/0", "::/0"):
    raise ValueError("adminCidr must be your own address, not the whole internet")
if ipaddress.ip_address(server_vpc_ip) not in ipaddress.ip_network(subnet_cidr):
    raise ValueError(f"serverVpcIp {server_vpc_ip} is not inside {subnet_cidr}")

tags = ["llm-inference-lab", "k3s-server"]

vpc = linode.Vpc(
    "vpc",
    label=f"{prefix}-vpc",
    region=region,
    description="Shared lab network (persistent)",
)
subnet = linode.VpcSubnet(
    "subnet",
    label=f"{prefix}-subnet",
    vpc_id=vpc.id.apply(int),
    ipv4=subnet_cidr,
)

server = linode.Instance(
    "server",
    label=f"{prefix}-server",
    region=region,
    type=server_type,
    image=image,
    authorized_keys=[ssh_key],  # key-only: no root password
    interface_generation="legacy_config",
    interfaces=[
        linode.InstanceInterfaceArgs(purpose="public", primary=True),
        linode.InstanceInterfaceArgs(
            purpose="vpc",
            subnet_id=subnet.id.apply(int),
            ipv4=linode.InstanceInterfaceIpv4Args(vpc=server_vpc_ip),
        ),
    ],
    tags=tags,
)

# Node-to-node traffic is admitted by VPC subnet, so a node added later (the
# ephemeral GPU worker) needs no change to this firewall. Cloud Firewall rules
# apply to the VPC interface as well as the public one.
firewall = linode.Firewall(
    "base-firewall",
    label=f"{prefix}-base-fw",
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
            label="admin-k8s-api",
            protocol="TCP",
            ports="6443",
            ipv4s=[admin_cidr],
        ),
        linode.FirewallInboundArgs(
            action="ACCEPT",
            label="vpc-supervisor-kubelet",
            protocol="TCP",
            ports="6443,10250",
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
    linodes=[server.id.apply(int)],
    tags=["llm-inference-lab"],
)

pulumi.export("region", region)
pulumi.export("server_ip", server.ip_address)
pulumi.export("server_vpc_ip", server_vpc_ip)
pulumi.export("server_instance_id", server.id)
pulumi.export("vpc_id", vpc.id)
pulumi.export("vpc_subnet_id", subnet.id)
pulumi.export("vpc_subnet_cidr", subnet_cidr)
pulumi.export("base_firewall_id", firewall.id)
