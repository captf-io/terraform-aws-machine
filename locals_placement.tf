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

# Placement: the availability zone (failure domain), its subnet, and the
# security groups and instance profile of the machine's kind.
locals {
  failure_domain_names = sort(keys(local.cluster_exports.failure_domains))

  # Without a requested domain, the sha256 of machine_name picks one of the
  # sorted zones: deterministic, so a retried apply places the machine in
  # the same zone (CONVENTIONS.md section 11). KCP and MachineDeployments
  # normally request one.
  default_failure_domain = try(
    local.failure_domain_names[parseint(substr(sha256(var.machine_name), 0, 8), 16) % length(local.failure_domain_names)],
    null,
  )
  failure_domain = var.failure_domain != null ? var.failure_domain : local.default_failure_domain
  subnet_id      = try(local.cluster_exports.failure_domains[local.failure_domain], null)

  node_kind          = var.control_plane ? "control_plane" : "worker"
  instance_profile   = local.cluster_exports.instance_profiles[local.node_kind]
  security_group_ids = concat(local.cluster_exports.security_group_ids[local.node_kind], var.additional_security_group_ids)

  # Control-plane machines register in every API target group; workers in
  # none (machine.md "Control-plane machines").
  api_target_groups = { for k, tg in local.cluster_exports.api_target_groups : k => tg if var.control_plane }
}
