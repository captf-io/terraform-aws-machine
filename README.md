# terraform-aws-machine

The CAPTF AWS machine module: the Terraform/OpenTofu root module behind `TerraformMachine`. The images are published from [aws-modules](https://github.com/captf-io/aws-modules) as `ghcr.io/captf-io/aws-machine`; this repository holds the module code only.

The `machine` role for AWS: one EC2 instance per Machine, control plane or
worker. It implements the `v1alpha1`
[machine role](https://captf.io/docs/module-author/contract/v1alpha1/machine.html)
and ships as `ghcr.io/captf-io/aws-machine`. Everything cluster-wide (subnets,
security groups, instance profiles, the API target groups, the bootstrap
bucket) comes from the cluster's exports.

## What it creates

| Resource | Count | Purpose |
| --- | --- | --- |
| `aws_instance.node_instance` | 1 | The node, in the failure domain's subnet and zone, with IMDSv2 and an encrypted root volume |
| `aws_s3_object.bootstrap_object` | 0 or 1 | The bootstrap payload, staged in the cluster's bucket (`bootstrap_delivery = "s3"`, the default) |
| `aws_lb_target_group_attachment.api_target_attachments` | 1 per API port, control plane only | Registers the instance behind the API endpoint, in this machine's state, so destroy deregisters it |

It reads `data.aws_ami_ids.node_images` when `machine_image.id` is not set.

## Prerequisites

- **A provisioned aws-cluster** (or `external_cluster_exports`).
- **Image.** cloud-init (or Ignition) and, for the default S3 delivery, AWS
  CLI v2 on the `PATH`. Kubernetes binaries for the Machine's version.
  image-builder's AWS images (and the CAPA images the default lookup finds)
  have all of it. The node must register under its private DNS name, the
  name cloud-provider-aws looks it up by: on Ubuntu set the kubeadm
  `nodeRegistration.name` to `{{ ds.meta_data.local_hostname }}` (see the
  example).
- **cloud-provider-aws in the workload cluster**, with the kubelet's
  `cloud-provider: external`: it sets each Node's `providerID`, which must
  equal the Machine's. Setting the kubelet's `provider-id` to
  `aws:///{{ v1.availability_zone }}/{{ v1.instance_id }}` as well, as the
  example does, links Machine and Node before the cloud controller manager
  runs.
- **Quotas.** One instance, its vCPUs (and Spot vCPUs) per instance family.
- **Identity permissions.** `ec2:RunInstances`, `ec2:TerminateInstances`,
  `ec2:CreateTags`, `ec2:Describe*`, `iam:PassRole` on the node roles,
  `elasticloadbalancing:RegisterTargets` and `DeregisterTargets`, and
  `s3:PutObject`, `s3:GetObject*` and `s3:DeleteObject` on the bootstrap
  bucket: see [`examples/identity-policy.json`](examples/identity-policy.json).

## Inputs

Contract inputs ([machine role](https://captf.io/docs/module-author/contract/v1alpha1/machine.html#inputs)):

| Input | Used for |
| --- | --- |
| `captf_contract` | Validated to be `v1alpha1` |
| `captf_cluster` | Declared, unused: the cluster's identity comes from exports |
| `captf_object` | Declared, unused |
| `captf_cluster_outputs` | Everything cluster-wide; validated to be `captf.io/aws-cluster/v1` or `{}` |
| `captf_tags` | Tags on every taggable resource |
| `machine_name` | The instance's `Name` tag and the payload's key |
| `bootstrap_data` | The payload, staged or sent as-is; never parsed |
| `bootstrap_format` | `cloud-config` or `ignition`: which stub |
| `failure_domain` | The zone; null picks one from `sha256(machine_name)` over the sorted cluster zones |
| `kubernetes_version` | The AMI lookup (without `v` and any `+suffix`) |
| `control_plane` | Identity, security groups, payload prefix, target group registration |

User variables, set through the TerraformMachineTemplate's
`spec.template.spec.variables` or `variablesFrom`:

| Variable | Type | Default | Description |
| --- | --- | --- | --- |
| `additional_security_group_ids` | `list(string)` | `[]` | Extra security groups for the instance. |
| `additional_tags` | `map(string)` | `{}` | Extra tags for every taggable resource; at most 40, no `aws:`, `captf.io/` or `kubernetes.io/cluster/` keys. |
| `bootstrap_delivery` | `string` | `"s3"` | `s3` (stub plus staged payload) or `inline` (payload as user data, 16 KiB at most). |
| `external_cluster_exports` | `any` | `null` | The exports of an externally managed TerraformCluster, used when `captf_cluster_outputs` is `{}`. |
| `instance_metadata_hop_limit` | `number` | `1` | IMDSv2 hop limit; 2 lets pods without host networking reach the metadata service. |
| `instance_type` | `string` | `"m6i.large"` | EC2 instance type. |
| `machine_image` | `object({id, owner, name_format, architecture})` | `{}`: CAPA images, owner `819546954734`, `capa-ami-ubuntu-24.04-?{semver}-*`, `x86_64` | `id` pins the AMI; without it the newest AMI matching the format for the Kubernetes version is used. |
| `public_ip` | `bool` | `false` | Give the instance a public IPv4 address. |
| `root_volume_kms_key_id` | `string` | `null` | KMS key ARN for the root volume; null uses the account's default EBS key. A customer managed key must let the identity use it (`kms:CreateGrant`, `kms:Decrypt`, `kms:GenerateDataKeyWithoutPlaintext`, `kms:ReEncrypt*`, `kms:DescribeKey`), through its key policy or the identity's policy. |
| `root_volume_size_gib` | `number` | `40` | Root volume size. |
| `root_volume_type` | `string` | `"gp3"` | `gp3` or `gp2`. |
| `spot` | `bool` | `false` | One-time Spot Instance; workers only. |
| `ssh_key_name` | `string` | `null` | EC2 key pair; no rule admits SSH either way. |

## Outputs

| Output | Value |
| --- | --- |
| `provider_id` | `aws:///<availability-zone>/<instance-id>`, the format cloud-provider-aws v1.36.1 writes (`InstanceID()` returns `/<zone>/<id>`, `getProviderID` prefixes `aws://`) |
| `addresses` | `InternalIP` (private IP), `InternalDNS` and `Hostname` (private DNS name); `ExternalIP` and `ExternalDNS` when the instance has a public address, as the cloud controller manager reports them |
| `failure_domain` | The zone the instance runs in: the requested one, or the one picked |
| `interruptible` | `true` for a Spot Instance (`instance_lifecycle = "spot"`) |
| `health` | See Health |

## Exports

The machine role exports nothing. It reads the cluster's
(`captf.io/aws-cluster/v1`, see [the cluster README](https://github.com/captf-io/terraform-aws-cluster#exports)):
every field but `api` is required, and `api.target_groups` is what a
control-plane machine registers in.

## Identity Secret

The provider sets only the region, from the cluster's exports; credentials
come from the identity Secret as for the cluster role
([cluster README](https://github.com/captf-io/terraform-aws-cluster#identity-secret)).

## Bootstrap

The bootstrap payload holds join tokens and, for control-plane nodes, the
cluster CA keys, and a control-plane payload outgrows EC2's 16 KiB of user
data. So the module stages it as `control-plane/<machine>` or
`worker/<machine>` in the cluster's bootstrap bucket, readable only by the
matching node role, and gives the instance a small user-data stub:

- `cloud-config`: a `#cloud-boothook` script that downloads the object with
  the AWS CLI (once per instance, retrying for five minutes, decompressing
  gzip) and installs it, mode 0600, as
  `/etc/cloud/cloud.cfg.d/99-captf-bootstrap.cfg`. cloud-init re-reads its
  configuration after the boothooks, so the payload runs in the same boot
  as system configuration. It must be cloud-config (`#cloud-config`, or a
  `## template: jinja` cloud-config as CABPK writes); a shell script or
  MIME payload is refused. Merged as system configuration, its lists
  replace those of the image's own `cloud.cfg.d` files.
- `ignition`: `{"ignition":{"version":"3.0.0","config":{"replace":{"source":"s3://<bucket>/<key>"}}}}`;
  Ignition fetches `s3://` with the instance profile.

`bootstrap_delivery = "inline"` sends the payload itself as user data
instead (a plain cloud-config gzipped, anything else verbatim), up to
16 KiB, for images without the AWS CLI. Anyone who can call
`ec2:DescribeInstanceAttribute` or reach the instance metadata service can
then read it, CA keys included.

## Tags

The instance and its root volume carry `captf_tags`, `additional_tags`,
`kubernetes.io/cluster/<id> = owned` (cloud-provider-aws reads its cluster
ID from it) and `Name = <machine_name>`. The S3 object carries `captf_tags`
only: S3 allows 10 tags per object. Target group attachments cannot be
tagged.

## Health

| EC2 instance state | `state` | `healthy` | `reasons` |
| --- | --- | --- | --- |
| `pending` | `pending` | `false` | `InstancePending` |
| `running` | `running` | `true` | `[]` |
| `stopping` | `stopped` | `false` | `InstanceStopping` |
| `stopped` | `stopped` | `false` | `InstanceStopped` |
| `shutting-down` | `terminated` | `false` | `InstanceShuttingDown` |
| `terminated` | `terminated` | `false` | `InstanceTerminated` |
| instance gone from state | `terminated` | `false` | `InstanceNotFound` |
| anything else | `unknown` | `false` | `UnknownState` |

The provider drops a terminated instance from state on refresh, so a
terminated machine reads `InstanceNotFound` and its `provider_id` turns
null; the controller then marks it terminated after two samples.

## Limitations

- **Node names must be the private DNS names**: cloud-provider-aws finds an
  unregistered node's instance by it.
- **The AMI and user data are fixed per machine.** A looked-up image is
  chosen at creation, and later changes to the image or the user-data stub
  (a module release) are ignored rather than stopping the instance; they
  reach the cluster through new machines. If a
  looked-up image is later deregistered, refreshes still work, but a drift
  plan fails its precondition.
- **No drain on Spot interruption** beyond what a termination handler in
  the cluster does; Spot is refused for control-plane machines.
- **Inline delivery** exposes the payload, control-plane CA keys included,
  through instance metadata and `DescribeInstanceAttribute`.
- **The payload stays on the node** as
  `/etc/cloud/cloud.cfg.d/99-captf-bootstrap.cfg` (root, mode 0600), as
  the files it writes stay anyway.
- **The payload stays in Terraform state** (`content_base64` of the S3
  object), as every input does in CAPTF's state and inputs Secrets.

## Exceptions

None: `tfcapi-lint module --strict` passes without allowed warnings.

## Examples

[`examples/cluster-kubeadm.yaml`](examples/cluster-kubeadm.yaml) uses
this image for the control plane and a MachineDeployment:

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1alpha1
kind: TerraformMachineTemplate
metadata:
  name: demo-md-0
spec:
  template:
    spec:
      source:
        image: ghcr.io/captf-io/aws-machine:v0.1.0-opentofu
      variables:
        instance_type: m6i.large
```

## Development

The host needs `make`, `podman` (or `docker` with `ENGINE=docker`), `jq` and
Go; every other tool runs in a digest-pinned container. `make verify` is the
gate. `tfcapi-lint` is built from `../cluster-api-provider-terraform`
(`PROVIDER_DIR`); without that checkout the target skips.

| Target | What it does |
| --- | --- |
| `make fmt` | Format the module with `terraform fmt` and `tofu fmt`, in place. |
| `make fmt-check` | Fail on any file either formatter would change. |
| `make validate` | `init` and `validate` on both runtimes and on their floors (Terraform 1.5.7, OpenTofu 1.6.3). |
| `make unit-test` | `terraform test` and `tofu test` with mocked providers. |
| `make tflint` | `tflint` with the terraform ruleset (preset all) and the cloud ruleset. |
| `make tfcapi-lint` | `tfcapi-lint module --strict`. |
| `make scan` | `trivy config` over the repository; ignores live in `.trivyignore.yaml`. |
| `make check-conventions` | `hack/check-layout.sh` and `hack/check-tags.sh` (CONVENTIONS.md). |
| `make shellcheck` | `shellcheck` over `hack/` and every shell template, rendered with placeholders. |
| `make check-headers` | Fail on any source file without the Apache-2.0 license header. |
| `make fix-headers` | Add the license header to every source file missing it. |
| `make verify` | Everything above, in parallel groups. |
| `make clean` | Remove `build/`. |

`RUNTIMES=opentofu` limits a run to one runtime.
