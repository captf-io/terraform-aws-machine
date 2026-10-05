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

# The node: one EC2 instance in the machine's availability zone. subnet_id and
# availability_zone are set together, so a subnet from the wrong zone fails
# at RunInstances instead of placing the node in another failure domain.
# Every precondition of the machine role lives here, on its primary
# resource.
resource "aws_instance" "node_instance" {
  # count = 1, not a bare resource: once a refresh drops a bare resource
  # from state its references read as unknown, which try() cannot catch, so
  # the outputs would go null; an empty tuple fails the index, and try()
  # falls back (checked on Terraform 1.16.4 and OpenTofu 1.12.6).
  count = 1

  ami                         = local.image_id
  associate_public_ip_address = var.public_ip
  availability_zone           = local.failure_domain
  iam_instance_profile        = local.instance_profile
  instance_type               = var.instance_type
  key_name                    = var.ssh_key_name
  subnet_id                   = local.subnet_id
  tags                        = merge(local.tags, { Name = local.instance_name })
  user_data_base64            = local.user_data_base64
  vpc_security_group_ids      = local.security_group_ids

  dynamic "instance_market_options" {
    for_each = var.spot ? [true] : []

    content {
      market_type = "spot"

      spot_options {
        instance_interruption_behavior = "terminate"
        spot_instance_type             = "one-time"
      }
    }
  }

  # IMDSv2 only. Instance tags stay out of the metadata service: their keys
  # (captf.io/cluster, kubernetes.io/cluster/<id>) contain "/", which IMDS
  # does not allow
  # (https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/work-with-tags-in-IMDS.html).
  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = var.instance_metadata_hop_limit
    http_tokens                 = "required"
    instance_metadata_tags      = "disabled"
  }

  # The root volume's tags here, not volume_tags: the provider reads
  # volume_tags back from every attached volume, so the EBS CSI driver's
  # tags on attached PersistentVolumes would show as drift on every plan.
  root_block_device {
    delete_on_termination = true
    encrypted             = true
    kms_key_id            = var.root_volume_kms_key_id
    tags                  = merge(local.tags, { Name = local.instance_name })
    volume_size           = var.root_volume_size_gib
    volume_type           = var.root_volume_type
  }

  lifecycle {
    # A machine keeps what it was created with: a looked-up image changes
    # when a newer one is published, and the user-data stub can change with
    # a module release, where an update would stop and start the instance.
    # New images and stubs reach the cluster through new machines (a
    # template rollout).
    ignore_changes = [ami, user_data_base64]

    precondition {
      condition     = local.exports_complete || !local.externally_managed || var.external_cluster_exports != null
      error_message = "The TerraformCluster is externally managed (captf_cluster_outputs is {}): set spec.variables.external_cluster_exports on the TerraformMachineTemplate to the cluster's exports (README \"Exports\")."
    }
    precondition {
      condition     = local.exports_complete || (local.externally_managed && var.external_cluster_exports == null)
      error_message = "The cluster's exports lack ${join(", ", local.exports_missing)}: ${local.externally_managed ? "external_cluster_exports" : "captf_cluster_outputs"} must hold every field of captf.io/aws-cluster/v1 (README \"Exports\")."
    }
    precondition {
      condition     = var.failure_domain == null || contains(local.failure_domain_names, coalesce(var.failure_domain, "-")) || !local.exports_complete
      error_message = "failure_domain names ${coalesce(var.failure_domain, "-")}, which is not one of the cluster's failure domains (${join(", ", local.failure_domain_names)})."
    }
    precondition {
      condition     = local.image_id != null
      error_message = var.machine_image.id == null && local.kubernetes_semver == null ? "No AMI to boot: set spec.variables.machine_image.id, or set the Machine's version so an image can be looked up." : "No AMI named ${coalesce(local.image_name_filter, "-")} (architecture ${var.machine_image.architecture}) is owned by ${var.machine_image.owner} in this region: set machine_image.id, or a name_format and owner that match an image here."
    }
    precondition {
      condition     = !(var.spot && var.control_plane)
      error_message = "spot must be false for control-plane machines: reclaiming a Spot Instance would take an etcd member with it."
    }
    precondition {
      condition     = !(var.bootstrap_delivery == "s3" && var.bootstrap_format == "ignition" && local.bootstrap_gzipped)
      error_message = "A gzip-compressed Ignition payload cannot be staged in S3: Ignition cannot fetch a compressed config from s3://. Turn off gzipUserData in the bootstrap config, or set bootstrap_delivery = \"inline\"."
    }
    precondition {
      condition     = local.user_data_bytes <= local.user_data_max_bytes
      error_message = "The user data is ${local.user_data_bytes} bytes, over EC2's ${local.user_data_max_bytes}-byte limit: use bootstrap_delivery = \"s3\" (the default), which sends only a small stub."
    }
  }

  # The stub names the payload by bucket and key, not by reference, so the
  # graph alone would not create the object first; with it in place before
  # boot, the stub's first fetch succeeds.
  depends_on = [aws_s3_object.bootstrap_object]
}
