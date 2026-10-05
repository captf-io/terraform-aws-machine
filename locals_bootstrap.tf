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

# What the instance boots with (DESIGN.md "Bootstrap payloads are staged in
# S3", CONVENTIONS.md section 13). bootstrap_data is opaque: it is staged or
# sent as-is, decoded only to gzip a plain cloud-config for inline delivery.
locals {
  # "H4sI" is the base64 of the gzip magic (1f 8b 08). Whether the payload
  # is compressed is not secret.
  bootstrap_gzipped = nonsensitive(startswith(var.bootstrap_data, "H4sI"))

  # The payload object exists only when it can be written: with s3 delivery
  # and a bucket from exports. Otherwise the precondition on
  # aws_instance.node_instance explains what is missing.
  bootstrap_object_enabled = var.bootstrap_delivery == "s3" && local.exports_complete
  bootstrap_object_url     = "s3://${coalesce(local.cluster_exports.bootstrap_bucket, "-")}/${local.bootstrap_object_key}"

  # The stub user data that fetches the staged payload. cloud-config: a
  # boothook that downloads the payload and installs it in
  # /etc/cloud/cloud.cfg.d, which cloud-init reads after its boothooks
  # (DESIGN.md decision 1). Ignition: a config that replaces itself with
  # the object; Ignition reads s3:// URLs with the instance profile (spec
  # 3.0.0, which every Ignition 2.x accepts).
  bootstrap_stub = var.bootstrap_format == "ignition" ? jsonencode({
    ignition = {
      version = "3.0.0"
      config  = { replace = { source = local.bootstrap_object_url } }
    }
    }) : templatefile("${path.module}/templates/user_data.tftpl", {
    bucket = coalesce(local.cluster_exports.bootstrap_bucket, "-")
    key    = local.bootstrap_object_key
    region = coalesce(local.cluster_exports.region, "-")
  })

  # Inline delivery: a plain cloud-config is gzipped to fit more into the
  # 16 KiB (cloud-init detects gzip); gzip and Ignition go verbatim. The
  # decode happens only once the payload is known to be uncompressed text
  # (CONVENTIONS.md section 4).
  inline_user_data_base64 = var.bootstrap_format == "cloud-config" && !local.bootstrap_gzipped ? base64gzip(base64decode(var.bootstrap_data)) : var.bootstrap_data

  user_data_base64 = var.bootstrap_delivery == "s3" ? base64encode(local.bootstrap_stub) : local.inline_user_data_base64

  # Decoded size of what is sent: EC2 limits user data to 16 KiB before
  # base64 (https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/user-data.html).
  inline_user_data_bytes = nonsensitive(
    floor(length(local.inline_user_data_base64) / 4) * 3 - (endswith(local.inline_user_data_base64, "==") ? 2 : endswith(local.inline_user_data_base64, "=") ? 1 : 0)
  )
  user_data_bytes     = var.bootstrap_delivery == "s3" ? length(local.bootstrap_stub) : local.inline_user_data_bytes
  user_data_max_bytes = 16384
}
