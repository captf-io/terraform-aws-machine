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

# Contract inputs of the machine role, in contract order, with the contract's
# types: https://captf.io/docs/module-author/contract/v1alpha1/common.html
# and https://captf.io/docs/module-author/contract/v1alpha1/machine.html

# Only its validation reads it: the module asserts the contract version.
# tflint-ignore: terraform_unused_declarations
variable "captf_contract" {
  description = "Contract version the controller generated the root for; always v1alpha1."
  type        = string

  validation {
    condition     = var.captf_contract == "v1alpha1"
    error_message = "captf_contract must be v1alpha1: this module implements the v1alpha1 machine role."
  }
}

# tflint-ignore: terraform_unused_declarations
variable "captf_cluster" {
  description = "The owning CAPI Cluster: name and namespace."
  type = object({
    name      = string
    namespace = string
  })
}

# tflint-ignore: terraform_unused_declarations
variable "captf_object" {
  description = "The TerraformMachine being reconciled: kind, name and namespace."
  type = object({
    kind      = string
    name      = string
    namespace = string
  })
}

variable "captf_cluster_outputs" {
  description = "The cluster role's exports (schema captf.io/aws-cluster/v1), or {} for an externally managed TerraformCluster, which then needs external_cluster_exports."
  type        = any

  validation {
    condition     = contains(["{}", "null"], jsonencode(var.captf_cluster_outputs)) || try(var.captf_cluster_outputs.schema == "captf.io/aws-cluster/v1", false)
    error_message = "captf_cluster_outputs must be the exports of the aws cluster module (schema captf.io/aws-cluster/v1): the cluster runs a different module or an incompatible version."
  }
}

variable "captf_tags" {
  description = "Tags the controller always sets (captf.io/cluster, captf.io/namespace, captf.io/kind, captf.io/name, captf.io/managed-by, captf.io/template); applied to every taggable resource."
  type        = map(string)
}

variable "machine_name" {
  description = "The owning CAPI Machine's name: the instance's Name tag and the key of its bootstrap object."
  type        = string
}

variable "bootstrap_data" {
  description = "Base64 of the bootstrap Secret's value. Staged in S3 (or sent inline with bootstrap_delivery = inline), never parsed."
  type        = string
  sensitive   = true
}

variable "bootstrap_format" {
  description = "The bootstrap payload's format: cloud-config or ignition."
  type        = string

  validation {
    condition     = contains(["cloud-config", "ignition"], var.bootstrap_format)
    error_message = "bootstrap_format must be cloud-config or ignition."
  }
}

variable "failure_domain" {
  description = "Machine.spec.failureDomain: the availability zone to place the instance in. Null picks one of the cluster's zones deterministically from machine_name."
  type        = string
  default     = null
}

variable "kubernetes_version" {
  description = "Machine.spec.version (vX.Y.Z, or vX.Y.Z+rke2rN under RKE2). Selects the default AMI when machine_image.id is not set."
  type        = string
  default     = null
}

variable "control_plane" {
  description = "True for a control-plane Machine: the instance gets the control-plane identity and security group and registers in the API target groups."
  type        = bool
}
