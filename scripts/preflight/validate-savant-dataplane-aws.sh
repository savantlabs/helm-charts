#!/usr/bin/env bash
#
# validate-savant-dataplane-aws.sh
#
# Read-only preflight validator for a self-managed Savant dataplane install on
# AWS. Run this BEFORE `helm install` to catch the most common infrastructure
# misconfigurations that surface as cryptic pod errors after the fact.
#
# This script only calls Describe/Get/List APIs. It does not create, modify,
# or delete anything. It makes no network calls outside the AWS API.
#
# It does NOT replace the setup guide — refer to the Savant AWS self-managed
# setup guide for the authoritative requirements. A green run here means
# "AWS-side resources look correct"; it does not mean "ready to serve
# production traffic". Items that can only be verified from inside the cluster
# (default StorageClass, autoscaler health, IRSA round-trip) are listed at the
# end.
#
# Requirements: aws CLI v2, jq. Both are preinstalled in AWS CloudShell.
#
# Usage:
#   ./validate-savant-dataplane-aws.sh <config-file> [--no-color]
#
# The config file is a shell-sourced KEY=value file. A template is provided
# alongside this script as `savant-preflight.conf.example`. Required keys:
#
#   REGION                AWS region containing the EKS cluster (e.g. us-west-2)
#   CLUSTER               EKS cluster name
#   BUCKET                S3 bucket provisioned for the dataplane
#   NAMESPACE             Kubernetes namespace you will helm-install into
#   SUPPORT_EXTERNAL_ID   Value you set as sts:ExternalId on the support role
#
# Optional keys:
#
#   ROLE_NAME           Defaults to savant-dataplane
#   SUPPORT_ROLE_NAME   Defaults to savant-support
#   KMS_KEY_ARN         ARN of customer-managed KMS key (BYOK only)
#
# Exit codes:
#   0  all required checks passed (warnings allowed)
#   1  one or more required checks failed
#   2  usage / preflight error

set -u
set -o pipefail

# ----- args -----------------------------------------------------------------

USE_COLOR=1
CONFIG_FILE=""

usage() {
  sed -n '3,36p' "$0"
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-color)  USE_COLOR=0; shift ;;
    -h|--help)   usage ;;
    -*)          echo "unknown flag: $1" >&2; usage ;;
    *)
      if [[ -n "$CONFIG_FILE" ]]; then
        echo "unexpected extra argument: $1" >&2; usage
      fi
      CONFIG_FILE="$1"; shift ;;
  esac
done

if [[ -z "$CONFIG_FILE" ]]; then
  echo "error: config file path is required" >&2
  usage
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "error: config file not found: $CONFIG_FILE" >&2
  exit 2
fi

# Defaults (may be overridden by the sourced config).
REGION=""
CLUSTER=""
BUCKET=""
NAMESPACE=""
ROLE_NAME="savant-dataplane"
SUPPORT_ROLE_NAME="savant-support"
SUPPORT_EXTERNAL_ID=""
KMS_KEY_ARN=""

# shellcheck disable=SC1090
source "$CONFIG_FILE"

missing=()
for required in REGION CLUSTER BUCKET NAMESPACE SUPPORT_EXTERNAL_ID; do
  if [[ -z "${!required}" ]]; then
    missing+=("$required")
  fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "error: config file is missing required keys: ${missing[*]}" >&2
  echo "see savant-preflight.conf.example for the full template" >&2
  exit 2
fi

# ----- tooling preflight ----------------------------------------------------

command -v aws >/dev/null 2>&1 || { echo "aws CLI not found on PATH" >&2; exit 2; }
command -v jq  >/dev/null 2>&1 || { echo "jq not found on PATH" >&2; exit 2; }

if ! ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null); then
  echo "aws sts get-caller-identity failed — check your credentials" >&2
  exit 2
fi

# ----- output helpers -------------------------------------------------------

if [[ $USE_COLOR -eq 1 && -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_RED=$'\033[0;31m'; C_YELLOW=$'\033[0;33m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_DIM=""; C_RESET=""
fi

PASS=0; FAIL=0; WARN=0

pass() { printf "  ${C_GREEN}[ ✓ ]${C_RESET} %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  ${C_RED}[ ✗ ]${C_RESET} %s${C_DIM}%s${C_RESET}\n" "$1" "${2:+ — $2}"; FAIL=$((FAIL+1)); }
warn() { printf "  ${C_YELLOW}[ ⚠ ]${C_RESET} %s${C_DIM}%s${C_RESET}\n" "$1" "${2:+ — $2}"; WARN=$((WARN+1)); }
section() { printf "\n${C_BOLD}%s${C_RESET}\n" "$1"; }

# Run an aws command silently; print stderr only on unexpected errors.
# Echoes stdout on success. Returns the aws command's exit code.
aws_q() { aws "$@" 2>/dev/null; }

# ----- IAM policy content inspection ----------------------------------------
#
# The setup guide suggests policy *names* like `savant-dataplane-s3`, but also
# says "use these unless your org has a different convention." Rather than
# checking names, we collect the effective Allow statements attached to a
# role (both attached managed policies and inline policies) and verify each
# required (action, resource) pair is granted by at least one statement.
#
# Limitations we're honest about:
#   - Allow statements with Condition are ignored (we can't evaluate
#     arbitrary conditions safely) — if this causes misses, `role_warn_unsupported`
#     emits a warn so the admin can verify manually.
#   - Deny, NotAction, NotResource are ignored with a single warn — a real
#     policy simulation would need iam:SimulatePrincipalPolicy.
#   - Wildcards matched with bash shell-globbing (`*`, `?`), which is how IAM
#     treats them syntactically. Good enough for this preflight.

# Emit NDJSON lines describing Allow statements on $1 (role name).
# Each line: {"actions":[...], "resources":[...], "hasCondition":bool}
role_allow_statements() {
  local role_name=$1
  {
    # Attached managed policies
    local attached_arns
    attached_arns=$(aws_q iam list-attached-role-policies --role-name "$role_name" \
                    | jq -r '.AttachedPolicies[]?.PolicyArn')
    while IFS= read -r arn; do
      [[ -z "$arn" ]] && continue
      local default_ver
      default_ver=$(aws_q iam get-policy --policy-arn "$arn" | jq -r '.Policy.DefaultVersionId')
      aws_q iam get-policy-version --policy-arn "$arn" --version-id "$default_ver" \
        | jq -c '.PolicyVersion.Document.Statement
                 | (if type=="array" then . else [.] end)
                 | .[]'
    done <<< "$attached_arns"

    # Inline policies
    local inline_names
    inline_names=$(aws_q iam list-role-policies --role-name "$role_name" \
                   | jq -r '.PolicyNames[]?')
    while IFS= read -r pn; do
      [[ -z "$pn" ]] && continue
      aws_q iam get-role-policy --role-name "$role_name" --policy-name "$pn" \
        | jq -c '.PolicyDocument.Statement
                 | (if type=="array" then . else [.] end)
                 | .[]'
    done <<< "$inline_names"
  } | jq -c 'select((.Effect // "Allow") == "Allow")
             | {
                 actions: (.Action // []) | (if type=="array" then . else [.] end),
                 resources: (.Resource // []) | (if type=="array" then . else [.] end),
                 hasCondition: (has("Condition") and (.Condition | length > 0))
               }'
}

# Emit a warn if the role has any statements the content check can't reason
# about (Deny / NotAction / NotResource). Also surfaces Allow+Condition count.
role_warn_unsupported() {
  local role_name=$1 label=$2
  local all_stmts
  all_stmts=$({
    local attached_arns
    attached_arns=$(aws_q iam list-attached-role-policies --role-name "$role_name" \
                    | jq -r '.AttachedPolicies[]?.PolicyArn')
    while IFS= read -r arn; do
      [[ -z "$arn" ]] && continue
      local default_ver
      default_ver=$(aws_q iam get-policy --policy-arn "$arn" | jq -r '.Policy.DefaultVersionId')
      aws_q iam get-policy-version --policy-arn "$arn" --version-id "$default_ver" \
        | jq -c '.PolicyVersion.Document.Statement
                 | (if type=="array" then . else [.] end) | .[]'
    done <<< "$attached_arns"

    local inline_names
    inline_names=$(aws_q iam list-role-policies --role-name "$role_name" \
                   | jq -r '.PolicyNames[]?')
    while IFS= read -r pn; do
      [[ -z "$pn" ]] && continue
      aws_q iam get-role-policy --role-name "$role_name" --policy-name "$pn" \
        | jq -c '.PolicyDocument.Statement
                 | (if type=="array" then . else [.] end) | .[]'
    done <<< "$inline_names"
  })

  local denies not_actions not_resources cond_allows
  denies=$(echo "$all_stmts"       | jq -s '[.[] | select(.Effect == "Deny")]            | length')
  not_actions=$(echo "$all_stmts"  | jq -s '[.[] | select(has("NotAction"))]             | length')
  not_resources=$(echo "$all_stmts"| jq -s '[.[] | select(has("NotResource"))]           | length')
  cond_allows=$(echo "$all_stmts"  | jq -s '[.[] | select((.Effect // "Allow")=="Allow" and has("Condition"))] | length')

  local issues=()
  [[ "$denies"        -gt 0 ]] && issues+=("$denies Deny")
  [[ "$not_actions"   -gt 0 ]] && issues+=("$not_actions NotAction")
  [[ "$not_resources" -gt 0 ]] && issues+=("$not_resources NotResource")
  [[ "$cond_allows"   -gt 0 ]] && issues+=("$cond_allows conditional Allow")

  if [[ ${#issues[@]} -gt 0 ]]; then
    warn "$label has advanced policy patterns this check ignores: ${issues[*]}" \
         "use 'aws iam simulate-principal-policy' if you need authoritative evaluation"
  fi
}

# check_role_grants <ndjson-statements> <action> <resource>
# Returns 0 if any statement grants (action, resource); 1 otherwise.
# Uses bash shell-globbing for IAM wildcards (* and ?).
check_role_grants() {
  local stmts=$1 want_action=$2 want_resource=$3
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Skip Allow+Condition: can't safely evaluate
    if [[ $(echo "$line" | jq -r '.hasCondition') == "true" ]]; then
      continue
    fi
    local action_hit=0 resource_hit=0 a r
    while IFS= read -r a; do
      case "$want_action" in $a) action_hit=1; break ;; esac
    done < <(echo "$line" | jq -r '.actions[]?')
    [[ $action_hit -eq 0 ]] && continue
    while IFS= read -r r; do
      case "$want_resource" in $r) resource_hit=1; break ;; esac
    done < <(echo "$line" | jq -r '.resources[]?')
    if [[ $resource_hit -eq 1 ]]; then
      return 0
    fi
  done <<< "$stmts"
  return 1
}

# Shorthand: emit pass/fail for a required (action, resource) on the role.
assert_role_grants() {
  local stmts=$1 action=$2 resource=$3
  if check_role_grants "$stmts" "$action" "$resource"; then
    pass "grants $action on $resource"
  else
    fail "role does not grant $action on $resource"
  fi
}

printf "${C_BOLD}Savant AWS preflight validator${C_RESET}\n"
printf "  account : %s\n" "$ACCOUNT_ID"
printf "  region  : %s\n" "$REGION"
printf "  cluster : %s\n" "$CLUSTER"
printf "  bucket  : %s\n" "$BUCKET"
printf "  ns      : %s\n" "$NAMESPACE"

# ============================================================================
# S3 bucket
# ============================================================================
section "S3 bucket: $BUCKET"

if ! aws_q s3api head-bucket --bucket "$BUCKET" >/dev/null; then
  fail "bucket exists and is accessible from this identity"
  BUCKET_OK=0
else
  pass "bucket exists and is accessible from this identity"
  BUCKET_OK=1
fi

if [[ $BUCKET_OK -eq 1 ]]; then
  # Region (us-east-1 returns null / empty)
  loc=$(aws_q s3api get-bucket-location --bucket "$BUCKET" | jq -r '.LocationConstraint // "us-east-1"')
  if [[ "$loc" == "$REGION" ]]; then
    pass "bucket region matches --region ($REGION)"
  else
    fail "bucket region ($loc) does not match --region ($REGION)"
  fi

  # The only Savant-required bucket-level setting is the tmp/ 7-day lifecycle
  # rule (Savant writes transient scratch data under tmp/ and does not delete
  # it inline). Everything else below is standard S3 hygiene that most orgs
  # already enforce org-wide; we report it as a warn so customers see the
  # state without having the preflight gate the install.

  # Lifecycle rules
  lc=$(aws_q s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" | jq '.Rules // []')
  if [[ "$lc" == "[]" || -z "$lc" ]]; then
    fail "no lifecycle rule expires tmp/ objects after 7 days" "REQUIRED — without this, scratch data accumulates indefinitely"
  else
    tmp_rule=$(echo "$lc" | jq -r '
      [.[]
       | select(.Status == "Enabled")
       | select(((.Filter.Prefix // .Prefix // "") == "tmp/")
                or ((.Filter.And.Prefix // "") == "tmp/"))
       | select((.Expiration.Days // 0) == 7)
      ] | length')
    if [[ "$tmp_rule" -ge 1 ]]; then
      pass "tmp/ prefix lifecycle rule = 7-day expiration"
    else
      fail "no lifecycle rule expires tmp/ objects after 7 days" "REQUIRED — without this, scratch data accumulates indefinitely"
    fi
  fi

  # ---- recommended (standard S3 hygiene; not required by Savant) ----------

  # Versioning
  ver=$(aws_q s3api get-bucket-versioning --bucket "$BUCKET" | jq -r '.Status // "Disabled"')
  if [[ "$ver" == "Enabled" ]]; then
    pass "versioning enabled (recommended)"

    # Noncurrent-version expiration only meaningful when versioning is on.
    if [[ "$lc" != "[]" && -n "$lc" ]]; then
      noncurrent=$(echo "$lc" | jq -r '
        [.[] | select((.Status == "Enabled")
                      and (.NoncurrentVersionExpiration.NoncurrentDays == 7))] | length')
      if [[ "$noncurrent" -ge 1 ]]; then
        pass "noncurrent version expiration rule = 7 days (recommended)"
      else
        warn "no rule expires noncurrent versions at 7 days" "recommended when versioning is enabled"
      fi
    fi
  else
    warn "versioning is $ver" "recommended: Enabled"
  fi

  # Public-access block
  pab=$(aws_q s3api get-public-access-block --bucket "$BUCKET" | jq -r '.PublicAccessBlockConfiguration // empty')
  if [[ -z "$pab" ]]; then
    warn "public-access block not configured" "recommended (default for new buckets since April 2023)"
  else
    all_true=$(echo "$pab" | jq -r '[.BlockPublicAcls, .IgnorePublicAcls, .BlockPublicPolicy, .RestrictPublicBuckets] | all')
    if [[ "$all_true" == "true" ]]; then
      pass "all four public-access blocks enabled (recommended)"
    else
      warn "not all public-access blocks are enabled" "recommended: all four true"
    fi
  fi

  # Ownership
  own=$(aws_q s3api get-bucket-ownership-controls --bucket "$BUCKET" \
        | jq -r '.OwnershipControls.Rules[0].ObjectOwnership // "unknown"')
  if [[ "$own" == "BucketOwnerEnforced" ]]; then
    pass "object ownership = BucketOwnerEnforced (recommended)"
  else
    warn "object ownership = $own" "recommended: BucketOwnerEnforced"
  fi

  # Encryption
  enc=$(aws_q s3api get-bucket-encryption --bucket "$BUCKET" \
        | jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // "none"')
  case "$enc" in
    AES256)   pass "encryption at rest: SSE-S3 (recommended)" ;;
    aws:kms)  pass "encryption at rest: SSE-KMS (recommended)" ;;
    none)     warn "encryption at rest not configured" "recommended (SSE-S3 is the AWS default since January 2023)" ;;
    *)        warn "encryption at rest: unexpected algorithm $enc" ;;
  esac

  # TLS-only bucket policy
  pol=$(aws_q s3api get-bucket-policy --bucket "$BUCKET" | jq -r '.Policy // empty')
  if [[ -z "$pol" ]]; then
    warn "no bucket policy present" "recommended: deny aws:SecureTransport=false"
  else
    tls_deny=$(echo "$pol" | jq -r '
      fromjson? // .
      | .Statement[]?
      | select(.Effect == "Deny"
               and (.Condition.Bool."aws:SecureTransport" // "") == "false")
      | "found"' | head -n1)
    if [[ "$tls_deny" == "found" ]]; then
      pass "bucket policy denies non-TLS access (recommended)"
    else
      warn "bucket policy does not deny aws:SecureTransport=false" "recommended"
    fi
  fi

  # Access logging
  log=$(aws_q s3api get-bucket-logging --bucket "$BUCKET" | jq -r '.LoggingEnabled // empty')
  if [[ -n "$log" ]]; then
    pass "server access logging enabled (recommended)"
  else
    warn "server access logging not enabled" "recommended"
  fi
fi

# ============================================================================
# EKS cluster
# ============================================================================
section "EKS cluster: $CLUSTER"

CLUSTER_JSON=$(aws_q eks describe-cluster --region "$REGION" --name "$CLUSTER" | jq '.cluster // empty')
if [[ -z "$CLUSTER_JSON" ]]; then
  fail "cluster not found in region $REGION"
  CLUSTER_OK=0
  OIDC_ISSUER=""
else
  CLUSTER_OK=1
  pass "cluster exists in $REGION"

  status=$(echo "$CLUSTER_JSON" | jq -r '.status')
  if [[ "$status" == "ACTIVE" ]]; then
    pass "cluster status = ACTIVE"
  else
    fail "cluster status = $status" "expected ACTIVE"
  fi

  version=$(echo "$CLUSTER_JSON" | jq -r '.version')
  # 1.27+ required; compare lexicographically after padding
  major=${version%%.*}
  minor=${version##*.}
  if (( major > 1 || (major == 1 && minor >= 27) )); then
    pass "kubernetes version = $version (>= 1.27)"
  else
    fail "kubernetes version = $version" "required: >= 1.27"
  fi

  OIDC_ISSUER=$(echo "$CLUSTER_JSON" | jq -r '.identity.oidc.issuer // empty')
  if [[ -n "$OIDC_ISSUER" ]]; then
    pass "OIDC issuer URL present on cluster"
  else
    fail "OIDC issuer URL missing"
  fi

  ep_pub=$(echo "$CLUSTER_JSON"  | jq -r '.resourcesVpcConfig.endpointPublicAccess')
  ep_priv=$(echo "$CLUSTER_JSON" | jq -r '.resourcesVpcConfig.endpointPrivateAccess')
  if [[ "$ep_pub" == "true" || "$ep_priv" == "true" ]]; then
    pass "API endpoint access configured (public=$ep_pub, private=$ep_priv)"
  else
    fail "neither public nor private API endpoint access is enabled"
  fi

  # OIDC provider registered in IAM (a common gotcha — issuer URL on cluster,
  # but provider never added to IAM, so IRSA silently never works)
  if [[ -n "$OIDC_ISSUER" ]]; then
    oidc_host_path=${OIDC_ISSUER#https://}
    providers=$(aws_q iam list-open-id-connect-providers | jq -r '.OpenIDConnectProviderList[].Arn')
    if echo "$providers" | grep -qF "$oidc_host_path"; then
      pass "OIDC provider registered in IAM"
    else
      fail "OIDC issuer is not registered as an IAM OIDC provider" \
           "run: eksctl utils associate-iam-oidc-provider"
    fi
  fi
fi

# ============================================================================
# EKS addons
# ============================================================================
section "EKS addons"

if [[ $CLUSTER_OK -eq 1 ]]; then
  installed=$(aws_q eks list-addons --region "$REGION" --cluster-name "$CLUSTER" | jq -r '.addons[]?')

  for required_addon in vpc-cni coredns kube-proxy aws-ebs-csi-driver; do
    if echo "$installed" | grep -qx "$required_addon"; then
      addon_status=$(aws_q eks describe-addon --region "$REGION" \
                     --cluster-name "$CLUSTER" --addon-name "$required_addon" \
                     | jq -r '.addon.status')
      if [[ "$addon_status" == "ACTIVE" ]]; then
        pass "$required_addon installed and ACTIVE"
      else
        fail "$required_addon installed but status = $addon_status"
      fi
    else
      fail "$required_addon not installed"
    fi
  done

  if echo "$installed" | grep -qx "amazon-cloudwatch-observability"; then
    pass "amazon-cloudwatch-observability installed (recommended)"
  else
    warn "amazon-cloudwatch-observability not installed" "recommended, not required"
  fi

  # EBS CSI addon's IRSA role (role name is not fixed; take it from the addon)
  ebs_role_arn=$(aws_q eks describe-addon --region "$REGION" \
                 --cluster-name "$CLUSTER" --addon-name aws-ebs-csi-driver \
                 | jq -r '.addon.serviceAccountRoleArn // empty')
  if [[ -n "$ebs_role_arn" ]]; then
    pass "EBS CSI addon has serviceAccountRoleArn: $ebs_role_arn"
    ebs_role_name=${ebs_role_arn##*/}
    ebs_trust=$(aws_q iam get-role --role-name "$ebs_role_name" \
                | jq -r '.Role.AssumeRolePolicyDocument
                         | .Statement[]?.Condition.StringEquals // empty
                         | to_entries[]? | select(.key | endswith(":sub")) | .value' \
                | head -n1)
    if [[ "$ebs_trust" == "system:serviceaccount:kube-system:ebs-csi-controller-sa" ]]; then
      pass "EBS CSI IRSA trust policy binds to kube-system:ebs-csi-controller-sa"
    else
      fail "EBS CSI IRSA trust policy sub = '$ebs_trust'" \
           "expected system:serviceaccount:kube-system:ebs-csi-controller-sa"
    fi
  else
    warn "EBS CSI addon has no serviceAccountRoleArn" \
         "IRSA not configured; may be using pod identity or node role"
  fi
else
  warn "skipped — cluster not found"
fi

# ============================================================================
# IAM: Savant dataplane role
# ============================================================================
section "IAM dataplane role: $ROLE_NAME"

ROLE_JSON=$(aws_q iam get-role --role-name "$ROLE_NAME" | jq '.Role // empty')
if [[ -z "$ROLE_JSON" ]]; then
  fail "role $ROLE_NAME does not exist"
  ROLE_ARN=""
else
  pass "role $ROLE_NAME exists"
  ROLE_ARN=$(echo "$ROLE_JSON" | jq -r '.Arn')

  # Trust policy: Federated principal + sub + aud
  if [[ -n "$OIDC_ISSUER" ]]; then
    oidc_host_path=${OIDC_ISSUER#https://}
    expected_fed="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${oidc_host_path}"
    expected_sub="system:serviceaccount:${NAMESPACE}:savant-agent"

    fed=$(echo "$ROLE_JSON" | jq -r '.AssumeRolePolicyDocument.Statement[]?.Principal.Federated // empty' | head -n1)
    if [[ "$fed" == "$expected_fed" ]]; then
      pass "trust policy federated to cluster OIDC provider"
    else
      fail "trust policy Federated = '$fed'" "expected $expected_fed"
    fi

    sub=$(echo "$ROLE_JSON" | jq -r '
      .AssumeRolePolicyDocument.Statement[]?.Condition.StringEquals // empty
      | to_entries[]? | select(.key | endswith(":sub")) | .value' | head -n1)
    if [[ "$sub" == "$expected_sub" ]]; then
      pass "trust policy sub = $expected_sub"
    else
      fail "trust policy sub = '$sub'" "expected $expected_sub (namespace mismatch is the #1 WebIdentityErr cause)"
    fi

    aud=$(echo "$ROLE_JSON" | jq -r '
      .AssumeRolePolicyDocument.Statement[]?.Condition.StringEquals // empty
      | to_entries[]? | select(.key | endswith(":aud")) | .value' | head -n1)
    if [[ "$aud" == "sts.amazonaws.com" ]]; then
      pass "trust policy aud = sts.amazonaws.com"
    else
      fail "trust policy aud = '$aud'" "expected sts.amazonaws.com"
    fi
  else
    warn "cannot verify trust policy — OIDC issuer unknown"
  fi

  # Effective permissions — check by content, not by policy name. See the
  # `role_allow_statements` helper comment at the top of the script.
  role_stmts=$(role_allow_statements "$ROLE_NAME")
  role_warn_unsupported "$ROLE_NAME" "role $ROLE_NAME"

  assert_role_grants "$role_stmts" "s3:ListBucket"        "arn:aws:s3:::$BUCKET"
  assert_role_grants "$role_stmts" "s3:GetBucketLocation" "arn:aws:s3:::$BUCKET"
  assert_role_grants "$role_stmts" "s3:GetObject"         "arn:aws:s3:::$BUCKET/*"
  assert_role_grants "$role_stmts" "s3:PutObject"         "arn:aws:s3:::$BUCKET/*"
  assert_role_grants "$role_stmts" "s3:DeleteObject"      "arn:aws:s3:::$BUCKET/*"

  if [[ -n "$KMS_KEY_ARN" ]]; then
    assert_role_grants "$role_stmts" "kms:Decrypt"         "$KMS_KEY_ARN"
    assert_role_grants "$role_stmts" "kms:GenerateDataKey" "$KMS_KEY_ARN"
    assert_role_grants "$role_stmts" "kms:DescribeKey"     "$KMS_KEY_ARN"
  fi
fi

# ============================================================================
# IAM: EKS service-linked roles
# ============================================================================
section "IAM service-linked roles"

for slr in \
  AWSServiceRoleForAmazonEKS \
  AWSServiceRoleForAmazonEKSNodegroup \
  AWSServiceRoleForElasticLoadBalancing \
  AWSServiceRoleForAutoScaling; do
  if aws_q iam get-role --role-name "$slr" >/dev/null; then
    pass "$slr exists"
  else
    fail "$slr does not exist" "usually auto-created on first EKS use"
  fi
done

# ============================================================================
# Savant support role
# ============================================================================
section "IAM support role: $SUPPORT_ROLE_NAME"

SUPPORT_JSON=$(aws_q iam get-role --role-name "$SUPPORT_ROLE_NAME" | jq '.Role // empty')
if [[ -z "$SUPPORT_JSON" ]]; then
  fail "role $SUPPORT_ROLE_NAME does not exist"
  SUPPORT_ROLE_ARN=""
else
  pass "role $SUPPORT_ROLE_NAME exists"
  SUPPORT_ROLE_ARN=$(echo "$SUPPORT_JSON" | jq -r '.Arn')

  principal=$(echo "$SUPPORT_JSON" | jq -r '.AssumeRolePolicyDocument.Statement[]?.Principal.AWS // empty' | head -n1)
  if [[ "$principal" == "arn:aws:iam::681436553836:root" ]]; then
    pass "trust policy principal is Savant's AWS account (681436553836)"
  else
    fail "trust policy principal = '$principal'" "expected arn:aws:iam::681436553836:root"
  fi

  ext_id=$(echo "$SUPPORT_JSON" | jq -r '
    .AssumeRolePolicyDocument.Statement[]?.Condition.StringEquals."sts:ExternalId" // empty' | head -n1)
  if [[ -z "$ext_id" ]]; then
    fail "trust policy is missing sts:ExternalId condition" \
         "without this, ANY principal in Savant's account could assume the role"
  elif [[ "$ext_id" == "$SUPPORT_EXTERNAL_ID" ]]; then
    pass "trust policy ExternalId matches SUPPORT_EXTERNAL_ID in config"
  else
    fail "trust policy ExternalId does not match SUPPORT_EXTERNAL_ID in config" \
         "Savant will be sent the value from config, which AWS will reject"
  fi

  # Effective permissions — representative action from each Sid in the setup
  # doc's support-role policy. If any of these is missing, Savant won't be
  # able to diagnose the corresponding category of issue.
  support_stmts=$(role_allow_statements "$SUPPORT_ROLE_NAME")
  role_warn_unsupported "$SUPPORT_ROLE_NAME" "role $SUPPORT_ROLE_NAME"

  assert_role_grants "$support_stmts" "eks:DescribeCluster" \
    "arn:aws:eks:$REGION:$ACCOUNT_ID:cluster/$CLUSTER"
  assert_role_grants "$support_stmts" "logs:DescribeLogGroups"   "*"
  assert_role_grants "$support_stmts" "logs:FilterLogEvents" \
    "arn:aws:logs:$REGION:$ACCOUNT_ID:log-group:/aws/containerinsights/$CLUSTER/*:*"
  assert_role_grants "$support_stmts" "s3:GetBucketLocation"     "arn:aws:s3:::$BUCKET"
  assert_role_grants "$support_stmts" "s3:ListBucket"            "arn:aws:s3:::$BUCKET"
fi

# ============================================================================
# Node groups
# ============================================================================
section "EKS managed node groups"

if [[ $CLUSTER_OK -eq 1 ]]; then
  ngs=$(aws_q eks list-nodegroups --region "$REGION" --cluster-name "$CLUSTER" | jq -r '.nodegroups[]?')
  if [[ -z "$ngs" ]]; then
    warn "no managed node groups found" \
         "if using self-managed nodes or Karpenter, verify pool labels with kubectl get nodes --show-labels"
  else
    declare -A found_pools=()
    had_unlabeled=0
    while IFS= read -r ng; do
      ng_json=$(aws_q eks describe-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$ng" \
                | jq '.nodegroup')
      pool_label=$(echo "$ng_json" | jq -r '.labels["pool.savant.io/type"] // empty')
      capacity=$(echo "$ng_json" | jq -r '.capacityType // "ON_DEMAND"')
      min=$(echo "$ng_json" | jq -r '.scalingConfig.minSize')
      max=$(echo "$ng_json" | jq -r '.scalingConfig.maxSize')
      itypes_csv=$(echo "$ng_json" | jq -r '.instanceTypes | join(",")')

      if [[ -z "$pool_label" ]]; then
        had_unlabeled=1
        warn "nodegroup $ng: pool.savant.io/type label not visible via AWS CLI" \
             "verify manually: kubectl get nodes -l eks.amazonaws.com/nodegroup=$ng -o 'jsonpath={.items[*].metadata.labels.pool\\.savant\\.io/type}'"
        continue
      fi

      case "$pool_label" in
        service|runtime|spark)
          found_pools[$pool_label]=1
          pass "nodegroup $ng → pool=$pool_label, instances=$itypes_csv, scaling=$min..$max, capacity=$capacity"

          if [[ "$pool_label" == "service" && "$capacity" != "ON_DEMAND" ]]; then
            fail "service pool nodegroup $ng uses $capacity capacity" "must be ON_DEMAND"
          fi

          # Instance-type check — warn if any type is off-family or off-size.
          # Expected: m[67]<variant>.<size>, where <size> depends on pool.
          expected_size=""
          case "$pool_label" in
            service) expected_size="xlarge" ;;
            runtime) expected_size="2xlarge" ;;
            spark)   expected_size="4xlarge" ;;
          esac
          mismatched=""
          IFS=',' read -ra _itypes_arr <<< "$itypes_csv"
          for it in "${_itypes_arr[@]}"; do
            if [[ ! "$it" =~ ^m[67][a-z]+\.${expected_size}$ ]]; then
              mismatched+="${mismatched:+, }$it"
            fi
          done
          if [[ -z "$mismatched" ]]; then
            pass "nodegroup $ng instance types match m-series $expected_size baseline"
          else
            warn "nodegroup $ng has instance types outside m-series $expected_size baseline: $mismatched" \
                 "expected m6i/m6a/m7i/m7a (or similar m-series) at $expected_size; smaller or off-family sizes may under-provision this pool"
          fi

          # Scaling floor/ceiling. Baselines mirror the node-group table above; a
          # min of 0 is the classic "pool never scales, pods stay Pending" trap,
          # since the autoscaler then has no labeled node to template from.
          baseline_min=0
          case "$pool_label" in
            service) baseline_min=4 ;;
            runtime) baseline_min=3 ;;
            spark)   baseline_min=4 ;;
          esac
          if [[ ! "$min" =~ ^[0-9]+$ || ! "$max" =~ ^[0-9]+$ ]]; then
            warn "nodegroup $ng ($pool_label) scaling config unreadable" "min=$min max=$max"
          elif [[ "$max" -eq 0 || "$max" -lt "$min" ]]; then
            fail "nodegroup $ng ($pool_label) scaling is invalid (min=$min, max=$max)" \
                 "max must be > 0 and >= min, or the pool cannot scale"
          elif [[ "$min" -eq 0 ]]; then
            fail "nodegroup $ng ($pool_label) has min size 0" \
                 "set min >= $baseline_min so a labeled node is always present; a 0 floor leaves this pool's pods Pending"
          elif [[ "$min" -lt "$baseline_min" ]]; then
            warn "nodegroup $ng ($pool_label) min size $min is below the baseline of $baseline_min" \
                 "may under-provision this pool under load"
          else
            pass "nodegroup $ng ($pool_label) scaling min=$min/max=$max meets the baseline"
          fi
          ;;
        *)
          # Extra pools (e.g. 'infra') are fine — Savant does not require a
          # dedicated cluster, just that the three pools below are present.
          ;;
      esac
    done <<< "$ngs"

    for p in service runtime spark; do
      if [[ -n "${found_pools[$p]:-}" ]]; then
        pass "pool '$p' present"
      elif [[ $had_unlabeled -eq 1 ]]; then
        warn "pool '$p' not confirmed via AWS CLI" \
             "at least one nodegroup has labels applied outside the MNG API — verify with kubectl get nodes --show-labels"
      else
        fail "no nodegroup labeled pool.savant.io/type=$p"
      fi
    done
  fi
else
  warn "skipped — cluster not found"
fi

# ============================================================================
# Cluster-autoscaler ASG tags
# ============================================================================
section "Cluster-autoscaler ASG tags"

if [[ $CLUSTER_OK -eq 1 ]]; then
  asg_names=$(aws_q autoscaling describe-auto-scaling-groups --region "$REGION" \
              --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
              | jq -r '.AutoScalingGroups[].AutoScalingGroupName')
  if [[ -z "$asg_names" ]]; then
    warn "no ASGs tagged with eks:cluster-name=$CLUSTER" \
         "expected for managed node groups"
  else
    expected_key="k8s.io/cluster-autoscaler/$CLUSTER"
    missing=0
    while IFS= read -r asg; do
      has_tag=$(aws_q autoscaling describe-auto-scaling-groups --region "$REGION" \
                --auto-scaling-group-names "$asg" \
                | jq --arg k "$expected_key" --arg v "owned" '
                  [.AutoScalingGroups[0].Tags[]
                   | select(.Key == $k and .Value == $v)] | length')
      if [[ "$has_tag" -ge 1 ]]; then
        pass "ASG $asg tagged $expected_key=owned"
      else
        fail "ASG $asg missing tag $expected_key=owned" \
             "cluster-autoscaler will not manage this ASG"
        missing=1
      fi
    done <<< "$asg_names"
    [[ $missing -eq 0 ]] || true
  fi
else
  warn "skipped — cluster not found"
fi

# ============================================================================
# Summary
# ============================================================================
section "Summary"
printf "  ${C_GREEN}passed${C_RESET} : %d\n" "$PASS"
printf "  ${C_YELLOW}warn${C_RESET}   : %d\n" "$WARN"
printf "  ${C_RED}failed${C_RESET} : %d\n" "$FAIL"

cat <<'EOF'

Not verified by this script — requires cluster access or runtime probe:
  - Default StorageClass exists with volumeBindingMode=WaitForFirstConsumer
  - Cluster-autoscaler (or Karpenter) is deployed and healthy in the cluster
  - Pool labels applied via launch-template user-data (visible only to kubectl)
  - PodDisruptionBudgets configured (required if using SPOT)
  - aws-node-termination-handler running (required if self-managed + SPOT)
  - Pods can actually complete sts:AssumeRoleWithWebIdentity (IRSA round-trip)
  - Network reachability from pods to Savant SaaS

Refer to the Savant AWS self-managed setup guide for the authoritative list of requirements.
EOF

# ============================================================================
# Onboarding values — copy/paste block for the customer to send to Savant
# ============================================================================
printf "\n${C_BOLD}%s${C_RESET}\n" "────────────────────────────────────────────────────────────"
printf "${C_BOLD} Onboarding values — copy the block below and send it to${C_RESET}\n"
printf "${C_BOLD} your Savant contact through your onboarding channel.${C_RESET}\n"
if [[ $FAIL -gt 0 ]]; then
  printf "\n ${C_RED}⚠ %d required check(s) failed — fix those before sending.${C_RESET}\n" "$FAIL"
fi
printf "${C_BOLD}%s${C_RESET}\n\n" "────────────────────────────────────────────────────────────"

cat <<EOF
# Savant onboarding values — generated $(date -u +"%Y-%m-%dT%H:%M:%SZ")
AWS_REGION="$REGION"
NAMESPACE="$NAMESPACE"
AWS_CLUSTER_NAME="$CLUSTER"
EKS_OIDC_ISSUER="${OIDC_ISSUER:-<missing — cluster not found>}"
AWS_DATAPLANE_ROLE_ARN="${ROLE_ARN:-<missing — role not found>}"
S3_BUCKET_NAME="$BUCKET"
AWS_SUPPORT_ROLE_ARN="${SUPPORT_ROLE_ARN:-<missing — role not found>}"
AWS_SUPPORT_EXTERNAL_ID="$SUPPORT_EXTERNAL_ID"

# Optional — fill in if your Savant contact asked for them
#CUSTOMER_NAME=""
#CONTACT_EMAIL=""
EOF

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
