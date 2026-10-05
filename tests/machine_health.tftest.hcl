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

# health for every mapped EC2 instance state, and interruptible for Spot.
#
# A mock applies override values when it creates a resource, and a mock
# never plans a replacement on its own, so each run replaces the instance
# (plan_options) for the overridden state to land on a fresh one.

mock_provider "aws" {
  mock_resource "aws_instance" {
    defaults = {
      instance_lifecycle = ""
      private_ip         = "10.0.1.23"
      private_dns        = "ip-10-0-1-23.ec2.internal"
      public_ip          = ""
      public_dns         = ""
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
    }
    security_group_ids = { control_plane = ["sg-0c0000000000000c1", "sg-0e0000000000000e1"], worker = ["sg-0e0000000000000e1"] }
    instance_profiles  = { control_plane = "captf-team-a-demo-1960e37c-control-plane", worker = "captf-team-a-demo-1960e37c-worker" }
    api                = null
    bootstrap_bucket   = "captf-bootstrap-20261001000000000000000001"
  }
  captf_tags         = { "captf.io/cluster" = "demo" }
  machine_name       = "demo-md-0-xyz12"
  bootstrap_data     = "I2Nsb3VkLWNvbmZpZwpydW5jbWQ6IFtlY2hvIGhlbGxvXQo="
  bootstrap_format   = "cloud-config"
  failure_domain     = "us-east-1a"
  kubernetes_version = null
  control_plane      = false
  machine_image      = { id = "ami-0123456789abcdef0" }
}

run "health_running" {
  plan_options {
    replace = [aws_instance.node_instance[0]]
  }

  override_resource {
    target = aws_instance.node_instance
    values = {
      instance_state = "running"
    }
  }

  assert {
    condition     = output.health.state == "running" && output.health.healthy && length(output.health.reasons) == 0
    error_message = "running maps to running, healthy."
  }
}

run "health_pending" {
  plan_options {
    replace = [aws_instance.node_instance[0]]
  }

  override_resource {
    target = aws_instance.node_instance
    values = {
      instance_state = "pending"
    }
  }

  assert {
    condition     = output.health.state == "pending" && !output.health.healthy && output.health.reasons[0] == "InstancePending"
    error_message = "pending maps to pending."
  }
}

run "health_stopping" {
  plan_options {
    replace = [aws_instance.node_instance[0]]
  }

  override_resource {
    target = aws_instance.node_instance
    values = {
      instance_state = "stopping"
    }
  }

  assert {
    condition     = output.health.state == "stopped" && !output.health.healthy && output.health.reasons[0] == "InstanceStopping"
    error_message = "stopping maps to stopped, a remediation candidate."
  }
}

run "health_stopped" {
  plan_options {
    replace = [aws_instance.node_instance[0]]
  }

  override_resource {
    target = aws_instance.node_instance
    values = {
      instance_state = "stopped"
    }
  }

  assert {
    condition     = output.health.state == "stopped" && !output.health.healthy && output.health.reasons[0] == "InstanceStopped"
    error_message = "stopped maps to stopped."
  }
}

run "health_shutting_down" {
  plan_options {
    replace = [aws_instance.node_instance[0]]
  }

  override_resource {
    target = aws_instance.node_instance
    values = {
      instance_state = "shutting-down"
    }
  }

  assert {
    condition     = output.health.state == "terminated" && !output.health.healthy && output.health.reasons[0] == "InstanceShuttingDown"
    error_message = "shutting-down means the instance is going away: terminated."
  }
}

run "health_terminated" {
  plan_options {
    replace = [aws_instance.node_instance[0]]
  }

  override_resource {
    target = aws_instance.node_instance
    values = {
      instance_state = "terminated"
    }
  }

  assert {
    condition     = output.health.state == "terminated" && !output.health.healthy && output.health.reasons[0] == "InstanceTerminated"
    error_message = "terminated maps to terminated."
  }
}

run "health_unknown" {
  plan_options {
    replace = [aws_instance.node_instance[0]]
  }

  override_resource {
    target = aws_instance.node_instance
    values = {
      instance_state = "rebooting"
    }
  }

  assert {
    condition     = output.health.state == "unknown" && !output.health.healthy && output.health.reasons[0] == "UnknownState"
    error_message = "a state outside the EC2 list maps to unknown."
  }
}

run "spot_is_interruptible" {
  variables {
    spot = true
  }

  plan_options {
    replace = [aws_instance.node_instance[0]]
  }

  override_resource {
    target = aws_instance.node_instance
    values = {
      instance_state     = "running"
      instance_lifecycle = "spot"
    }
  }

  assert {
    condition     = output.interruptible
    error_message = "a Spot Instance is interruptible."
  }
  assert {
    condition     = aws_instance.node_instance[0].instance_market_options[0].market_type == "spot" && aws_instance.node_instance[0].instance_market_options[0].spot_options[0].spot_instance_type == "one-time"
    error_message = "spot must request a one-time Spot Instance."
  }
}
