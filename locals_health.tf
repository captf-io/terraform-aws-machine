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

# Machine health from the instance state ("health" in
# https://captf.io/docs/module-author/contract/v1alpha1/common.html,
# CONVENTIONS.md section 10). A health other than running/healthy makes the
# Machine a MachineHealthCheck remediation candidate.
locals {
  # Every EC2 instance state
  # (https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_InstanceState.html)
  # -> contract health.
  health_by_state = {
    PENDING         = { state = "pending", healthy = false, reason = "InstancePending" }
    RUNNING         = { state = "running", healthy = true, reason = null }
    STOPPING        = { state = "stopped", healthy = false, reason = "InstanceStopping" }
    STOPPED         = { state = "stopped", healthy = false, reason = "InstanceStopped" }
    "SHUTTING-DOWN" = { state = "terminated", healthy = false, reason = "InstanceShuttingDown" }
    TERMINATED      = { state = "terminated", healthy = false, reason = "InstanceTerminated" }
  }

  instance_id    = try(aws_instance.node_instance[0].id, null)
  instance_state = try(aws_instance.node_instance[0].instance_state, null)

  # The provider drops a terminated instance from state on refresh, so a
  # missing instance after apply is a terminated one.
  health_entry = local.instance_id == null ? { state = "terminated", healthy = false, reason = "InstanceNotFound" } : lookup(
    local.health_by_state,
    upper(coalesce(local.instance_state, "unknown")),
    { state = "unknown", healthy = false, reason = "UnknownState" },
  )

  health_reading = {
    state   = local.health_entry.state
    healthy = local.health_entry.healthy
    message = local.instance_id == null ? "EC2 instance not found" : "EC2 instance ${local.instance_id} is ${coalesce(local.instance_state, "in an unknown state")}"
    reasons = local.health_entry.reason == null ? [] : [local.health_entry.reason]
  }
}
