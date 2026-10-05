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

# What the machine needs from the cluster: the exports of the aws cluster
# module (schema captf.io/aws-cluster/v1, CONVENTIONS.md section 12), or
# external_cluster_exports when the TerraformCluster is externally managed
# and the controller passes {}.
locals {
  externally_managed = contains(["{}", "null"], jsonencode(var.captf_cluster_outputs))

  # A tuple index, not a conditional: the two values are objects of
  # different shapes, which a conditional refuses to unify.
  exports_source = [var.captf_cluster_outputs, var.external_cluster_exports][local.externally_managed ? 1 : 0]

  # Normalized to one shape, every attribute try()-guarded, so a missing or
  # malformed field reads as null or empty here and is reported by the
  # precondition on aws_instance.node_instance instead of failing deep
  # inside an expression.
  cluster_exports = {
    schema                = try(tostring(local.exports_source.schema), null)
    region                = try(tostring(local.exports_source.region), null)
    kubernetes_cluster_id = try(tostring(local.exports_source.kubernetes_cluster_id), null)
    # Zone -> subnet ID.
    failure_domains = try({ for z, d in local.exports_source.failure_domains : z => tostring(d.subnet_id) }, {})
    security_group_ids = {
      control_plane = try([for s in local.exports_source.security_group_ids.control_plane : tostring(s)], [])
      worker        = try([for s in local.exports_source.security_group_ids.worker : tostring(s)], [])
    }
    instance_profiles = {
      control_plane = try(tostring(local.exports_source.instance_profiles.control_plane), null)
      worker        = try(tostring(local.exports_source.instance_profiles.worker), null)
    }
    # Port name -> { arn, port }; empty when the cluster has a user endpoint.
    api_target_groups = try({ for k, tg in local.exports_source.api.target_groups : k => { arn = tostring(tg.arn), port = tonumber(tg.port) } }, {})
    bootstrap_bucket  = try(tostring(local.exports_source.bootstrap_bucket), null)
  }

  # The fields every machine needs. api is optional: null for a user
  # endpoint.
  exports_missing = [
    for field, ok in {
      schema                = local.cluster_exports.schema == "captf.io/aws-cluster/v1"
      region                = local.cluster_exports.region != null
      kubernetes_cluster_id = local.cluster_exports.kubernetes_cluster_id != null
      failure_domains       = length(local.cluster_exports.failure_domains) > 0
      security_group_ids    = length(local.cluster_exports.security_group_ids.control_plane) > 0 && length(local.cluster_exports.security_group_ids.worker) > 0
      instance_profiles     = local.cluster_exports.instance_profiles.control_plane != null && local.cluster_exports.instance_profiles.worker != null
      bootstrap_bucket      = local.cluster_exports.bootstrap_bucket != null
    } : field if !ok
  ]
  exports_complete = length(local.exports_missing) == 0
}
