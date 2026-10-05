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

# How the bootstrap payload reaches the instance, per format and delivery
# (DESIGN.md "Bootstrap payloads are staged in S3"). Plans only: the user
# data is known at plan time.

mock_provider "aws" {
  mock_data "aws_ami_ids" {
    defaults = {
      ids = ["ami-0123456789abcdef0"]
    }
  }
}

variables {
  captf_contract = "v1alpha1"
  captf_cluster  = { name = "demo", namespace = "team-a" }
  captf_object   = { kind = "TerraformMachine", name = "demo-control-plane-abcde", namespace = "team-a" }
  captf_cluster_outputs = {
    schema                = "captf.io/aws-cluster/v1"
    region                = "us-east-1"
    vpc_id                = "vpc-0123456789abcdef0"
    kubernetes_cluster_id = "captf-team-a-demo-1960e37c"
    failure_domains       = { "us-east-1a" = { subnet_id = "subnet-0aaa0000000000001" } }
    security_group_ids    = { control_plane = ["sg-0c0000000000000c1", "sg-0e0000000000000e1"], worker = ["sg-0e0000000000000e1"] }
    instance_profiles     = { control_plane = "captf-team-a-demo-1960e37c-control-plane", worker = "captf-team-a-demo-1960e37c-worker" }
    api                   = null
    bootstrap_bucket      = "captf-bootstrap-20261001000000000000000001"
  }
  captf_tags         = { "captf.io/cluster" = "demo" }
  machine_name       = "demo-control-plane-abcde"
  bootstrap_data     = "I2Nsb3VkLWNvbmZpZwpydW5jbWQ6IFtlY2hvIGhlbGxvXQo="
  bootstrap_format   = "cloud-config"
  failure_domain     = null
  kubernetes_version = "v1.34.1"
  control_plane      = true
}

run "bootstrap_cloud_config" {
  command = plan

  assert {
    condition     = startswith(base64decode(aws_instance.node_instance[0].user_data_base64), "#cloud-boothook\n#!/bin/sh\n")
    error_message = "the cloud-config stub must be a boothook script."
  }
  assert {
    condition     = !strcontains(base64decode(aws_instance.node_instance[0].user_data_base64), "x-include-url") && !strcontains(base64decode(aws_instance.node_instance[0].user_data_base64), "multipart")
    error_message = "the stub must not rely on an include: cloud-init resolves includes before boothooks run."
  }
  assert {
    condition     = strcontains(base64decode(aws_instance.node_instance[0].user_data_base64), "'#cloud-config'*) ;;") && strcontains(base64decode(aws_instance.node_instance[0].user_data_base64), "aws s3 cp --only-show-errors --region 'us-east-1' 's3://captf-bootstrap-20261001000000000000000001/control-plane/demo-control-plane-abcde'")
    error_message = "the boothook must fetch this machine's object from the cluster's bucket in the cluster's region."
  }
  assert {
    condition     = strcontains(base64decode(aws_instance.node_instance[0].user_data_base64), "config=/etc/cloud/cloud.cfg.d/99-captf-bootstrap.cfg\n") && strcontains(base64decode(aws_instance.node_instance[0].user_data_base64), "chmod 0600 \"$decoded\"\nmv \"$decoded\" \"$config\"\n")
    error_message = "the boothook must install the payload, mode 0600, as cloud-init system configuration."
  }
  assert {
    condition     = !strcontains(base64decode(aws_instance.node_instance[0].user_data_base64), "runcmd")
    error_message = "the payload itself must not be in the user data."
  }
  assert {
    condition     = nonsensitive(aws_s3_object.bootstrap_object[0].content_base64) == nonsensitive(var.bootstrap_data) && aws_s3_object.bootstrap_object[0].server_side_encryption == "AES256"
    error_message = "the payload must be staged unchanged and encrypted."
  }
}

run "bootstrap_ignition" {
  command = plan

  variables {
    bootstrap_format = "ignition"
    bootstrap_data   = "eyJpZ25pdGlvbiI6eyJ2ZXJzaW9uIjoiMy40LjAifX0="
  }

  assert {
    condition     = jsondecode(base64decode(aws_instance.node_instance[0].user_data_base64)) == { ignition = { version = "3.0.0", config = { replace = { source = "s3://captf-bootstrap-20261001000000000000000001/control-plane/demo-control-plane-abcde" } } } }
    error_message = "the Ignition stub must replace itself with the staged config."
  }
}

run "bootstrap_gzip_cloud_config_staged" {
  command = plan

  variables {
    bootstrap_data = "H4sIAAAAAAAC/1NOzskvTdFNzs9Ly0znKirNS85NsVKITk3OyFfISM3JyY/lAgDckH8lIwAAAA=="
  }

  assert {
    condition     = nonsensitive(aws_s3_object.bootstrap_object[0].content_base64) == nonsensitive(var.bootstrap_data) && strcontains(base64decode(aws_instance.node_instance[0].user_data_base64), "gzip -dc")
    error_message = "a gzip payload must be staged as is; the boothook decompresses it."
  }
}

run "bootstrap_inline_cloud_config" {
  command = plan

  variables {
    bootstrap_delivery = "inline"
  }

  assert {
    condition     = nonsensitive(aws_instance.node_instance[0].user_data_base64) == nonsensitive(base64gzip(base64decode(var.bootstrap_data)))
    error_message = "inline delivery must gzip a plain cloud-config."
  }
  assert {
    condition     = length(aws_s3_object.bootstrap_object) == 0
    error_message = "inline delivery must not stage an object."
  }
}

run "bootstrap_inline_gzip" {
  command = plan

  variables {
    bootstrap_delivery = "inline"
    bootstrap_data     = "H4sIAAAAAAAC/1NOzskvTdFNzs9Ly0znKirNS85NsVKITk3OyFfISM3JyY/lAgDckH8lIwAAAA=="
  }

  assert {
    condition     = nonsensitive(aws_instance.node_instance[0].user_data_base64) == nonsensitive(var.bootstrap_data)
    error_message = "inline delivery must pass a gzip payload verbatim."
  }
}

run "bootstrap_inline_ignition" {
  command = plan

  variables {
    bootstrap_delivery = "inline"
    bootstrap_format   = "ignition"
    bootstrap_data     = "eyJpZ25pdGlvbiI6eyJ2ZXJzaW9uIjoiMy40LjAifX0="
  }

  assert {
    condition     = nonsensitive(aws_instance.node_instance[0].user_data_base64) == nonsensitive(var.bootstrap_data)
    error_message = "inline delivery must pass an Ignition payload verbatim."
  }
}

run "rejects_ignition_gzip_in_s3" {
  command = plan

  variables {
    bootstrap_format = "ignition"
    bootstrap_data   = "H4sIAAAAAAAC/1NOzskvTdFNzs9Ly0znKirNS85NsVKITk3OyFfISM3JyY/lAgDckH8lIwAAAA=="
  }

  expect_failures = [aws_instance.node_instance]
}

# About 18 KB decoded, already "gzip" (H4sI...), so it goes inline verbatim.
run "bootstrap_too_large" {
  command = plan

  variables {
    bootstrap_delivery = "inline"
    bootstrap_data     = "H4sI${join("", [for i in range(1000) : "AAAAAAAAAAAAAAAAAAAAAAAA"])}"
  }

  expect_failures = [aws_instance.node_instance]
}
