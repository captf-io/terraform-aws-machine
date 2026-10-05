# Copyright 2026 The CAPTF Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Unit tests of the machine role with a mocked AWS provider: nothing reaches
# AWS. `make unit-test ROLES=machine` runs them on Terraform and OpenTofu.
#
# Runs share state in file order, so the variants plan first, against no
# state, then happy_path applies and a second apply checks it is stable.
# machine_bootstrap, machine_health and machine_validation cover the rest.
#
# The worker demo-md-0-xyz12: sha256 starts e7b67c35, and 0xe7b67c35 % 3 is
# 2, so without a requested failure domain it lands in us-east-1c.

mock_provider "aws" {
  mock_resource "aws_instance" {
    defaults = {
      instance_state     = "running"
      instance_lifecycle = ""
      private_ip         = "10.0.3.23"
      private_dns        = "ip-10-0-3-23.ec2.internal"
      public_ip          = ""
      public_dns         = ""
    }
  }
  mock_data "aws_ami_ids" {
    defaults = {
      ids = ["ami-0123456789abcdef0", "ami-0fedcba9876543210"]
    }
  }
}

variables {
  captf_contract = "v1alpha1"
  captf_cluster  = { name = "demo", namespace = "team-a" }
  captf_object   = { kind = "TerraformMachine", name = "demo-md-0-xyz12", namespace = "team-a" }
  captf_cluster_outputs = {
    schema                = "captf.io/aws-cluster/v1"
    region                = "us-east-1"
    vpc_id                = "vpc-0123456789abcdef0"
    kubernetes_cluster_id = "captf-team-a-demo-1960e37c"
    failure_domains = {
      "us-east-1a" = { subnet_id = "subnet-0aaa0000000000001" }
      "us-east-1b" = { subnet_id = "subnet-0bbb0000000000002" }
      "us-east-1c" = { subnet_id = "subnet-0ccc0000000000003" }
    }
    security_group_ids = {
      control_plane = ["sg-0c0000000000000c1", "sg-0e0000000000000e1"]
      worker        = ["sg-0e0000000000000e1"]
    }
    instance_profiles = {
      control_plane = "captf-team-a-demo-1960e37c-control-plane"
      worker        = "captf-team-a-demo-1960e37c-worker"
    }
    api = {
      target_groups = {
        kube_apiserver = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/captf-team-a-demo-1960e37c-kapi/0123456789abcdef", port = 6443 }
      }
    }
    bootstrap_bucket = "captf-bootstrap-20261001000000000000000001"
  }
  captf_tags         = { "captf.io/cluster" = "demo", "captf.io/namespace" = "team-a", "captf.io/kind" = "TerraformMachine", "captf.io/name" = "demo-md-0-xyz12", "captf.io/managed-by" = "captf", "captf.io/template" = "demo-md-0" }
  machine_name       = "demo-md-0-xyz12"
  bootstrap_data     = "I2Nsb3VkLWNvbmZpZwpydW5jbWQ6IFtlY2hvIGhlbGxvXQo="
  bootstrap_format   = "cloud-config"
  failure_domain     = null
  kubernetes_version = "v1.34.1"
  control_plane      = false
  additional_tags    = { team = "platform" }
}

run "control_plane_registers_backend" {
  command = plan

  variables {
    captf_object   = { kind = "TerraformMachine", name = "demo-control-plane-abcde", namespace = "team-a" }
    machine_name   = "demo-control-plane-abcde"
    control_plane  = true
    failure_domain = "us-east-1b"
  }

  assert {
    condition     = keys(aws_lb_target_group_attachment.api_target_attachments) == ["kube_apiserver"]
    error_message = "a control-plane machine must register in every exported target group."
  }
  assert {
    condition     = aws_lb_target_group_attachment.api_target_attachments["kube_apiserver"].target_group_arn == var.captf_cluster_outputs.api.target_groups.kube_apiserver.arn && aws_lb_target_group_attachment.api_target_attachments["kube_apiserver"].port == 6443
    error_message = "the attachment must target the exported target group on its port."
  }
  assert {
    condition     = aws_instance.node_instance[0].iam_instance_profile == "captf-team-a-demo-1960e37c-control-plane" && aws_instance.node_instance[0].vpc_security_group_ids == toset(["sg-0c0000000000000c1", "sg-0e0000000000000e1"])
    error_message = "a control-plane machine must get the control-plane profile and both security groups."
  }
  assert {
    condition     = aws_s3_object.bootstrap_object[0].key == "control-plane/demo-control-plane-abcde"
    error_message = "a control-plane payload must go under control-plane/, which only control-plane nodes can read."
  }
}

run "control_plane_rke2_registers_every_port" {
  command = plan

  variables {
    machine_name  = "demo-control-plane-abcde"
    control_plane = true
    captf_cluster_outputs = {
      schema                = "captf.io/aws-cluster/v1"
      region                = "us-east-1"
      vpc_id                = "vpc-0123456789abcdef0"
      kubernetes_cluster_id = "captf-team-a-demo-1960e37c"
      failure_domains       = { "us-east-1a" = { subnet_id = "subnet-0aaa0000000000001" } }
      security_group_ids    = { control_plane = ["sg-0c0000000000000c1", "sg-0e0000000000000e1"], worker = ["sg-0e0000000000000e1"] }
      instance_profiles     = { control_plane = "cp", worker = "worker" }
      api = {
        target_groups = {
          kube_apiserver  = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/captf-team-a-demo-1960e37c-kapi/0123456789abcdef", port = 6443 }
          rke2_supervisor = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/captf-team-a-demo-1960e37c-rke2/0123456789abcdef", port = 9345 }
        }
      }
      bootstrap_bucket = "captf-bootstrap-20261001000000000000000001"
    }
  }

  assert {
    condition     = aws_lb_target_group_attachment.api_target_attachments["rke2_supervisor"].port == 9345 && length(aws_lb_target_group_attachment.api_target_attachments) == 2
    error_message = "an RKE2 control-plane machine must register on the supervisor port too."
  }
}

run "worker_has_no_backend" {
  command = plan

  assert {
    condition     = length(aws_lb_target_group_attachment.api_target_attachments) == 0
    error_message = "a worker must not register in the API target groups."
  }
  assert {
    condition     = aws_instance.node_instance[0].iam_instance_profile == "captf-team-a-demo-1960e37c-worker" && aws_instance.node_instance[0].vpc_security_group_ids == toset(["sg-0e0000000000000e1"])
    error_message = "a worker must get the worker profile and the node security group only."
  }
  assert {
    condition     = aws_s3_object.bootstrap_object[0].key == "worker/demo-md-0-xyz12"
    error_message = "a worker payload must go under worker/."
  }
}

run "failure_domain_requested" {
  command = plan

  variables {
    failure_domain = "us-east-1a"
  }

  assert {
    condition     = aws_instance.node_instance[0].availability_zone == "us-east-1a" && aws_instance.node_instance[0].subnet_id == "subnet-0aaa0000000000001"
    error_message = "the instance must be placed in the requested zone's subnet."
  }
}

run "failure_domain_defaulted" {
  command = plan

  assert {
    condition     = aws_instance.node_instance[0].availability_zone == "us-east-1c" && aws_instance.node_instance[0].subnet_id == "subnet-0ccc0000000000003"
    error_message = "without a request the zone must come from sha256(machine_name) over the sorted zones."
  }
}

run "unknown_failure_domain" {
  command = plan

  variables {
    failure_domain = "us-west-2a"
  }

  expect_failures = [aws_instance.node_instance]
}

run "externally_managed_without_override" {
  command = plan

  variables {
    captf_cluster_outputs = {}
  }

  expect_failures = [aws_instance.node_instance]
}

run "externally_managed_with_override" {
  command = plan

  variables {
    captf_cluster_outputs = {}
    external_cluster_exports = {
      schema                = "captf.io/aws-cluster/v1"
      region                = "eu-west-1"
      vpc_id                = "vpc-0fedcba9876543210"
      kubernetes_cluster_id = "legacy"
      failure_domains       = { "eu-west-1a" = { subnet_id = "subnet-0eee0000000000005" } }
      security_group_ids    = { control_plane = ["sg-0c0000000000000c2"], worker = ["sg-0e0000000000000e2"] }
      instance_profiles     = { control_plane = "legacy-cp", worker = "legacy-worker" }
      api                   = null
      bootstrap_bucket      = "legacy-bootstrap"
    }
  }

  assert {
    condition     = aws_instance.node_instance[0].subnet_id == "subnet-0eee0000000000005" && aws_instance.node_instance[0].iam_instance_profile == "legacy-worker"
    error_message = "external_cluster_exports must stand in for the exports of an externally managed cluster."
  }
  assert {
    condition     = aws_s3_object.bootstrap_object[0].bucket == "legacy-bootstrap" && aws_instance.node_instance[0].tags["kubernetes.io/cluster/legacy"] == "owned"
    error_message = "the bucket and cluster ID must come from external_cluster_exports."
  }
}

run "rejects_incomplete_exports" {
  command = plan

  variables {
    captf_cluster_outputs = { schema = "captf.io/aws-cluster/v1", region = "us-east-1" }
  }

  expect_failures = [aws_instance.node_instance]
}

run "wrong_exports_schema" {
  command = plan

  variables {
    captf_cluster_outputs = { schema = "captf.io/gcp-cluster/v1" }
  }

  expect_failures = [var.captf_cluster_outputs]
}

run "image_lookup" {
  command = plan

  variables {
    kubernetes_version = "v1.34.1+rke2r1"
  }

  assert {
    condition     = aws_instance.node_instance[0].ami == "ami-0123456789abcdef0"
    error_message = "the newest matching AMI (the first of aws_ami_ids) must be used."
  }
  assert {
    condition     = contains(flatten([for f in data.aws_ami_ids.node_images[0].filter : tolist(f.values) if f.name == "name"]), "capa-ami-ubuntu-24.04-?1.34.1-*") && data.aws_ami_ids.node_images[0].owners[0] == "819546954734"
    error_message = "the lookup must use the version without v or +suffix in the CAPA name format, from the CAPA account."
  }
}

run "image_explicit" {
  command = plan

  variables {
    machine_image = { id = "ami-0aaaaaaaaaaaaaaaa" }
  }

  assert {
    condition     = aws_instance.node_instance[0].ami == "ami-0aaaaaaaaaaaaaaaa" && length(data.aws_ami_ids.node_images) == 0
    error_message = "machine_image.id must be used as is, without a lookup."
  }
}

run "rejects_missing_image" {
  command = plan

  override_data {
    target = data.aws_ami_ids.node_images
    values = {
      ids = []
    }
  }

  expect_failures = [aws_instance.node_instance]
}

run "rejects_image_without_version" {
  command = plan

  variables {
    kubernetes_version = null
  }

  expect_failures = [aws_instance.node_instance]
}

run "rejects_spot_control_plane" {
  command = plan

  variables {
    control_plane = true
    spot          = true
  }

  expect_failures = [aws_instance.node_instance]
}

run "instance_options" {
  command = plan

  variables {
    public_ip                     = true
    ssh_key_name                  = "ops"
    instance_metadata_hop_limit   = 2
    additional_security_group_ids = ["sg-0abc000000000000a"]
    root_volume_size_gib          = 100
    root_volume_kms_key_id        = "arn:aws:kms:us-east-1:123456789012:key/0e0e0e0e-0e0e-0e0e-0e0e-0e0e0e0e0e0e"
  }

  assert {
    condition     = aws_instance.node_instance[0].associate_public_ip_address && aws_instance.node_instance[0].key_name == "ops"
    error_message = "public_ip and ssh_key_name must reach the instance."
  }
  assert {
    condition     = aws_instance.node_instance[0].metadata_options[0].http_put_response_hop_limit == 2 && contains(aws_instance.node_instance[0].vpc_security_group_ids, "sg-0abc000000000000a")
    error_message = "the hop limit and additional security groups must reach the instance."
  }
  assert {
    condition     = aws_instance.node_instance[0].root_block_device[0].volume_size == 100 && aws_instance.node_instance[0].root_block_device[0].kms_key_id == var.root_volume_kms_key_id
    error_message = "the root volume size and KMS key must reach the instance."
  }
}

run "happy_path" {
  assert {
    condition     = output.provider_id == "aws:///us-east-1c/${aws_instance.node_instance[0].id}"
    error_message = "provider_id must be aws:///<zone>/<instance-id>."
  }
  assert {
    condition = jsonencode(output.addresses) == jsonencode([
      { type = "InternalIP", address = "10.0.3.23" },
      { type = "InternalDNS", address = "ip-10-0-3-23.ec2.internal" },
      { type = "Hostname", address = "ip-10-0-3-23.ec2.internal" },
    ])
    error_message = "addresses must mirror the cloud controller manager: private IP and DNS name, no external ones without a public address."
  }
  assert {
    condition     = output.failure_domain == "us-east-1c"
    error_message = "failure_domain must be the zone the instance runs in."
  }
  assert {
    condition     = output.interruptible == false
    error_message = "an on-demand instance is not interruptible."
  }
  assert {
    condition     = jsonencode(output.health) == jsonencode({ state = "running", healthy = true, message = "EC2 instance ${aws_instance.node_instance[0].id} is running", reasons = [] })
    error_message = "a running instance is healthy."
  }
  assert {
    condition = alltrue([
      aws_instance.node_instance[0].metadata_options[0].http_tokens == "required",
      aws_instance.node_instance[0].metadata_options[0].http_put_response_hop_limit == 1,
      aws_instance.node_instance[0].metadata_options[0].instance_metadata_tags == "disabled",
      aws_instance.node_instance[0].root_block_device[0].encrypted,
      aws_instance.node_instance[0].root_block_device[0].volume_type == "gp3",
      aws_instance.node_instance[0].root_block_device[0].volume_size == 40,
      !aws_instance.node_instance[0].associate_public_ip_address,
      length(aws_instance.node_instance[0].instance_market_options) == 0,
    ])
    error_message = "the defaults must be secure: IMDSv2 with hop limit 1, encrypted root volume, no public IP, on-demand."
  }
  assert {
    condition     = aws_instance.node_instance[0].ami == "ami-0123456789abcdef0" && aws_instance.node_instance[0].instance_type == "m6i.large"
    error_message = "the instance must boot the looked-up AMI as the default instance type."
  }
  assert {
    condition     = aws_s3_object.bootstrap_object[0].bucket == "captf-bootstrap-20261001000000000000000001" && nonsensitive(aws_s3_object.bootstrap_object[0].content_base64) == nonsensitive(var.bootstrap_data)
    error_message = "the payload must be staged unchanged in the cluster's bootstrap bucket."
  }
}

run "tags_on_taggable_resources" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for tags in [aws_instance.node_instance[0].tags, aws_instance.node_instance[0].root_block_device[0].tags] :
      [for k, v in merge(var.captf_tags, var.additional_tags, { "kubernetes.io/cluster/captf-team-a-demo-1960e37c" = "owned", Name = "demo-md-0-xyz12" }) : lookup(tags, k, null) == v]
    ]))
    error_message = "the instance and its volumes must carry the captf tags, additional_tags, the cluster ownership tag and the Machine name."
  }
  assert {
    condition     = jsonencode(aws_s3_object.bootstrap_object[0].tags) == jsonencode(var.captf_tags)
    error_message = "the payload object must carry exactly the captf tags (S3 allows 10 per object)."
  }
}

# A second identical apply keeps the instance: the provider ID embeds its ID.
run "reapply_is_stable" {
  # previous_provider_id is test-only: OpenTofu does not resolve run.<name>
  # inside an assert.
  variables {
    previous_provider_id = run.happy_path.provider_id
  }

  assert {
    condition     = output.provider_id == var.previous_provider_id
    error_message = "a second apply must keep the instance."
  }
}
