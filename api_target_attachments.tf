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

# A control-plane machine registers its instance in every API target group
# the cluster exports, in this machine's own state, so destroying the
# machine deregisters it (machine.md "Control-plane machines"). The
# attachment follows the instance's creation within the same apply, long
# before kubeadm init or join can finish on the booting node.
resource "aws_lb_target_group_attachment" "api_target_attachments" {
  for_each = local.api_target_groups

  port             = each.value.port
  target_group_arn = each.value.arn
  target_id        = aws_instance.node_instance[0].id
}
