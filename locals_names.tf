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

# Names of what the machine creates (CONVENTIONS.md section 6). The instance's
# Name tag is the Machine name, for people: Kubernetes knows the node by its
# private DNS name, which cloud-provider-aws matches (README "Limitations").
locals {
  instance_name = var.machine_name

  # The payload's key in the bootstrap bucket. The prefix decides who may
  # read it (cluster/locals_bootstrap.tf): control-plane payloads carry the
  # cluster CA keys and are readable by control-plane nodes only.
  bootstrap_object_key = "${var.control_plane ? "control-plane" : "worker"}/${var.machine_name}"
}
