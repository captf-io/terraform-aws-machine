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

# Contract outputs of the machine role, in contract order:
# https://captf.io/docs/module-author/contract/v1alpha1/machine.html#outputs
# and "health" in https://captf.io/docs/module-author/contract/v1alpha1/common.html
#
# Every value reads the instance's refreshed state through try(), so an
# apply -refresh-only after the instance vanished never errors.

output "provider_id" {
  description = "aws:///<availability-zone>/<instance-id>, the providerID cloud-provider-aws writes to the Node (getProviderID in cloud-provider-aws v1.36.1)."
  value       = try("aws:///${aws_instance.node_instance[0].availability_zone}/${aws_instance.node_instance[0].id}", null)
}

output "addresses" {
  description = "The addresses cloud-provider-aws reports for the Node: InternalIP, InternalDNS and Hostname from the private IP and DNS name; ExternalIP and ExternalDNS when the instance has a public address."
  value = try([
    for a in [
      { type = "InternalIP", address = aws_instance.node_instance[0].private_ip },
      { type = "InternalDNS", address = aws_instance.node_instance[0].private_dns },
      { type = "Hostname", address = aws_instance.node_instance[0].private_dns },
      { type = "ExternalIP", address = aws_instance.node_instance[0].public_ip },
      { type = "ExternalDNS", address = aws_instance.node_instance[0].public_dns },
    ] : a if a.address != null && a.address != ""
  ], [])
}

output "failure_domain" {
  description = "The availability zone the instance runs in: the requested failure_domain, or the one the module picked."
  value       = try(aws_instance.node_instance[0].availability_zone, local.failure_domain)
}

output "interruptible" {
  description = "True for a Spot Instance (instance_lifecycle spot); CAPI then labels the Node cluster.x-k8s.io/interruptible."
  value       = try(aws_instance.node_instance[0].instance_lifecycle == "spot", var.spot)
}

output "health" {
  description = "From the instance state: pending, running, stopping and stopped (stopped), shutting-down (terminated); terminated when the instance is gone."
  value       = local.health_reading
}
