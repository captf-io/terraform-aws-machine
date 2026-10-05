# Design: terraform-aws-machine

Why this module looks the way it does. Each decision names the evidence it
rests on; anything not yet checked against a real AWS account is listed
under "Unverified" and must be confirmed on the first reviewed apply.

Pins: `hashicorp/aws` 6.67.0. Runtimes: Terraform >= 1.5, OpenTofu >= 1.6.
Conventions: [CONVENTIONS.md](CONVENTIONS.md). Contract:
<https://captf.io/docs/module-author/contract/v1alpha1/>.

Provider facts below were checked against `providers schema -json` of the
pinned provider and its source at the `v6.67.0` tag; file names refer to
`internal/service/<service>/` in `hashicorp/terraform-provider-aws`.

The AWS modules share one design. Decision numbers are the same in every
repository ([cluster](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md), [machine](https://github.com/captf-io/terraform-aws-machine/blob/main/DESIGN.md), [machinepool](https://github.com/captf-io/terraform-aws-machinepool/blob/main/DESIGN.md)), so a reference such as "decision 1" means the same
decision everywhere; a number missing here belongs to another role.

## Scope

- This repository is the `machine` role: one EC2 instance for each Machine, control plane or worker.
- Everything cluster-wide (subnets, security groups, instance profiles, the API
  target groups, the bootstrap bucket) comes from the cluster's exports. The
  cluster role is in [terraform-aws-cluster](https://github.com/captf-io/terraform-aws-cluster), the pool role in
  [terraform-aws-machinepool](https://github.com/captf-io/terraform-aws-machinepool).

## Decisions

### 1. Bootstrap payloads are staged in S3

The contract suggests `aws_launch_template.user_data = var.bootstrap_data`
for pools. Pool bootstrap data rotates about every 7.5 minutes (kubeadm
token refresh), and every user-data change creates a launch template
version. AWS allows 10,000 versions per launch template (EC2 User Guide,
"Restrictions for launch templates"): about 52 days of rotations, after
which every pool apply fails. Terraform has no resource that prunes
versions. Secrets Manager (100 unlabelled versions, none removed within 24
hours) and SSM Parameter Store (4 KB / 8 KB values) do not fit either.

So the cluster creates one S3 bucket per cluster. The machine and pool
roles write the payload to an object (`aws_s3_object`, `content_base64 =
var.bootstrap_data`, which the provider decodes to raw bytes, so gzip is
safe) and give the instance a small user-data stub that fetches it:

- cloud-config: a `#cloud-boothook` script that copies `s3://<bucket>/<key>`
  with the AWS CLI (60 attempts, 5 s apart; once per instance, guarded by
  the file it writes, since boothooks run on every boot), gunzips when the
  bytes start with `1f 8b`, refuses anything that is not cloud-config
  (`#cloud-config`, or `## template: jinja` then `#cloud-config`, as CABPK
  writes), and installs it atomically (`umask 077`, mode 0600, temporary
  file and `mv`) as `/etc/cloud/cloud.cfg.d/99-captf-bootstrap.cfg`. That
  works on stock cloud-init: after the boothooks (`consume_data`,
  `cmd/main.py` 596-608), `stages.py` 828 `_reset()` drops the cached
  configuration and the module stages read it again, `cloud.cfg.d`
  included (`stages.py` 276-311, `util.read_conf_with_confd`), before the
  init, config and final modules run; a `cloud.cfg.d` file that starts
  with `## template: jinja` is rendered (`util.py` 312-350). The payload
  then merges as system configuration: dictionaries merge, lists replace
  (a later file's `runcmd` wins), and `merge_how` is ignored.

  CAPA's pattern, a boothook plus a `text/x-include-url` part naming the
  fetched file, does not work on stock cloud-init: `init.update()`
  resolves includes (`cmd/main.py` 589, `stages.py` 570,
  `sources/__init__.py` 648-650, `user_data.py` 157-159 `_do_include`)
  before boothooks run, and the missing file aborts init because
  `features.ERROR_ON_USER_DATA_FAILURE` is true (`features.py` 21). CAPA
  works only through image-builder patches (CAPA #2757, #4745, #5115).
- Ignition: `{"ignition":{"version":"3.0.0","config":{"replace":{"source":"s3://<bucket>/<key>"}}}}`;
  Ignition fetches `s3://` with the instance role (spec 3.0.0+). Ignition
  cannot fetch compressed S3 objects, so Ignition plus gzip fails a
  precondition.

The pool object is updated in place on every rotation: no launch template
version, no instance refresh. This also meets the control-plane checklist
rule to keep key material out of readable instance metadata. The machine's
instance `depends_on` its object, so the first fetch finds it; the object
is planned only when the exports name a bucket, so incomplete exports are
reported by the instance's precondition rather than by a null `bucket`.

The bucket, its policy and the read access by key prefix are the cluster
role's: see decision 1 of the [terraform-aws-cluster DESIGN.md](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md).

This role also offers `bootstrap_delivery = "inline"` for AMIs
without the AWS CLI: plain cloud-config is gzipped with
`base64gzip(base64decode(...))`, gzip and Ignition payloads pass verbatim,
and a precondition enforces AWS's 16 KiB raw user-data limit. The README
warns that inline control-plane payloads expose CA keys through IMDS and
`DescribeInstanceAttribute`. Pools are S3-only.

Requirement: the AMI has cloud-init and AWS CLI v2. image-builder installs
the CLI on non-Amazon distributions (`roles/providers/tasks/aws.yml`).

### 2. API load balancer

This role does not own this decision: see the [terraform-aws-cluster DESIGN.md](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md).

### 3. Security groups

This role does not own this decision: see the [terraform-aws-cluster DESIGN.md](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md).

### 4. Node identities

This role does not own this decision: see the [terraform-aws-cluster DESIGN.md](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md).

### 5. Machine

- `aws_instance` with `subnet_id` and `availability_zone` set together, so
  a subnet from the wrong zone fails at RunInstances instead of placing the
  node in another failure domain.
- IMDSv2 required, hop limit 1 (`instance_metadata_hop_limit`), and
  `instance_metadata_tags = "disabled"` (IMDS tag keys cannot contain `/`).
- Encrypted gp3 root volume, tagged through `root_block_device.tags`, not
  `volume_tags`: the provider reads `volume_tags` back from every attached
  volume (`ec2/ec2_instance.go` `readVolumeTags`), so the EBS CSI driver's
  tags on attached PersistentVolumes would be drift on every plan.
- AMI: `machine_image.id`, else the CAPA lookup
  (`capa-ami-ubuntu-24.04-?<k8s without v>-*`, owner 819546954734,
  architecture, state available, CAPA `pkg/cloud/services/ec2/ami.go`
  `DefaultAMILookup`) through `data.aws_ami_ids`, which returns no IDs
  rather than failing when nothing matches, so a refresh never fails on a
  deregistered image. A precondition reports a missing image; preconditions
  are not evaluated by `apply -refresh-only`, so health keeps refreshing.
  `ignore_changes = [ami, user_data_base64]`: a user-data change would stop
  and start the instance, for example after a module release changes the
  stub. CAPA calls these AMIs non-production, so production sets
  `machine_image.id`.
- `root_volume_kms_key_id` must be an ARN: AWS reports the key as one, so
  an ID or alias would differ on every plan, and the key is ForceNew.
- Spot for workers only; `interruptible` comes from `instance_lifecycle`.
- Control-plane machines register in every API target group with
  `aws_lb_target_group_attachment`, in their own state, so destroy
  deregisters them.
- Failure domain null: `azs[sha256(machine_name) mod n]` over the sorted
  zones.

### 6. Machine pool

This role does not own this decision: see the [terraform-aws-machinepool DESIGN.md](https://github.com/captf-io/terraform-aws-machinepool/blob/main/DESIGN.md).

### 7. provider_id, addresses, health

- `aws:///<availability-zone>/<instance-id>`: cloud-provider-aws v1.36.1
  `InstanceID()` returns `/<AZ>/<instance-id>` and `getProviderID` prefixes
  `aws://`.
- The CCM finds unregistered nodes by private DNS name, so the node name
  must be the instance's private DNS name (the examples set kubeadm's
  `nodeRegistration.name` to `{{ ds.meta_data.local_hostname }}`, as CAPA's
  templates do).
- Addresses mirror the CCM: InternalIP, InternalDNS and Hostname from the
  private IP and DNS name; ExternalIP and ExternalDNS when public.
- Machine health from `instance_state`: pending → pending; running →
  running; stopping/stopped → stopped; shutting-down/terminated →
  terminated; other → unknown. The provider drops a terminated instance
  from state on refresh, so a missing instance reads `terminated`
  (`InstanceNotFound`) and `provider_id` goes null.

### 8. Tags

- `local.tags` on every taggable resource, explicitly. No provider
  `default_tags`: they do not reach ASG-launched instances, and mocks cannot
  assert them.
- Instances also carry `Name` and `kubernetes.io/cluster/<id> = owned`
  (the CCM discovers the cluster ID from its own instance's tags).
- Limits: 50 tags, keys 128, values 256, `aws:` reserved, empty values
  allowed. S3 objects take at most 10 tags, so objects carry only the
  captf tags (`hack/tags.json`).

### 9. Credentials

The provider block sets only `region` (cluster: `var.region`, null means
`AWS_REGION`; machine and pool: the cluster's exported region). Everything
else comes from the SDK chain:

- static keys: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`;
- assume role: `AWS_CONFIG_FILE=/var/run/captf/credentials/config`,
  `AWS_SHARED_CREDENTIALS_FILE=/var/run/captf/credentials/credentials`,
  `AWS_PROFILE`, with `config` and `credentials` file keys in the Secret.

`HOME` is `/captf/work`, so `~/.aws` never exists. IRSA needs a projected
token the CAPTF Job does not mount.

### 10. Network input

The cluster role reads the VPC and subnets (decision 10 of the
[terraform-aws-cluster DESIGN.md](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md)); the machine takes the zone to subnet map from the exports.

Resources whose disappearance health must report (the bucket, the
instance, the group) use `count = 1`: once a refresh drops a bare
resource from state its references read as unknown, which `try()` cannot
catch, so outputs go null; an empty tuple fails the index and `try()` falls
back (checked with local_file on Terraform 1.16.4 and OpenTofu 1.12.6).

## Cluster exports consumed

Schema `captf.io/aws-cluster/v1`, produced by the cluster role; the full
shape is under "Exports" in the [terraform-aws-cluster DESIGN.md](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md).
It reads `schema`, `region`, `kubernetes_cluster_id`, `failure_domains`,
`security_group_ids`, `instance_profiles`, `api.target_groups` and
`bootstrap_bucket`.

Machines and pools normalize the exports into one shape with `try()` per
field, and select them from `captf_cluster_outputs` or
`external_cluster_exports` with a tuple index: a conditional refuses two
object values of different shapes.

## Unverified

**1.** The `cloud.cfg.d` merge semantics on a real boot: the payload merged
as system configuration (lists replace, so an image's own
`cloud.cfg.d` `runcmd` or `write_files` would be overridden), its Jinja
rendered there, and no image-builder patch interfering; also AWS CLI v2
on the AMIs in use.

**2.** Concerns another role: see the DESIGN.md of [terraform-aws-machinepool](https://github.com/captf-io/terraform-aws-machinepool/blob/main/DESIGN.md).

**3.** Concerns another role: see the DESIGN.md of [terraform-aws-machinepool](https://github.com/captf-io/terraform-aws-machinepool/blob/main/DESIGN.md).

**4.** Deregistering a target whose instance is already terminated, at destroy.

**5.** Concerns another role: see the DESIGN.md of [terraform-aws-cluster](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md).

**6.** Concerns another role: see the DESIGN.md of [terraform-aws-cluster](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md).

**7.** Concerns another role: see the DESIGN.md of [terraform-aws-cluster](https://github.com/captf-io/terraform-aws-cluster/blob/main/DESIGN.md).

**8.** `examples/identity-policy.json` is complete for create, update and
destroy of all three roles.

**9.** An Ignition 3.0.0 stub replacing itself with a newer-spec config.

**10.** Concerns another role: see the DESIGN.md of [terraform-aws-machinepool](https://github.com/captf-io/terraform-aws-machinepool/blob/main/DESIGN.md).

## Rejected alternatives

- Bootstrap in launch template user data (version quota, above).
- A boothook plus an `x-include-url` part naming the fetched file (CAPA's
  pattern): stock cloud-init resolves the include first and aborts
  (decision 1).
- Provider `default_tags` (does not reach ASG launches; untestable).
- `data.aws_ami` for the lookup (fails a refresh once the image is
  deregistered).
- `AmazonEBSCSIDriverPolicy` on the control-plane role and hop limit 2 for
  control-plane nodes by default: the EBS CSI controller does not run on
  control-plane nodes unless scheduled there, and the defaults stay least
  privilege; `node_role_policy_arns` and `instance_metadata_hop_limit` opt
  in.
