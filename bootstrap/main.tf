# Recursos que se crean UNA vez, a mano (terraform apply local), antes de los pipelines:
#   - bucket S3 para el estado de Terraform de los ambientes;
#   - roles IAM que GitHub Actions asume por OIDC (sin llaves guardadas en GitHub).
# El proveedor OIDC de GitHub ya existe en la cuenta: se usa como data source, no se crea.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.80" }
  }
  # Primero se aplicó con estado local (el bucket aún no existía) y luego se migró aquí.
  backend "s3" {
    bucket       = "kutnz-tfstate-595981034933"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = { Project = "kutnz-cicd", ManagedBy = "terraform", Repo = "kutnz-infra", Course = "Infraestructura-Desarrollo-Continuo" }
  }
}

variable "github_owner" {
  type    = string
  default = "ikramzaldivar"
}

variable "github_owner_id" {
  type    = number
  default = 112355542
}

data "aws_caller_identity" "me" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  account = data.aws_caller_identity.me.account_id
  region  = "us-east-1"
  # GitHub firma el claim "sub" con el formato inmutable (usuario@id/repo@id): si alguien borra y vuelve a
  # crear un repo con el mismo nombre, su ID cambia y ya no puede asumir estos roles.
  repo_ids = { "kutnz-backend" = 1461585639, "kutnz-frontend" = 1461585745, "kutnz-infra" = 1461585872 }
  repo     = { for r, id in local.repo_ids : r => "repo:${var.github_owner}@${var.github_owner_id}/${r}@${id}" }

  # Nombre del stack que puede tocar el pipeline en cada ambiente.
  ambientes = {
    dev  = { stack = "kutnz-dev" }
    prod = { stack = "kutnz" } # stack existente de kut.nz (repo kutnz)
  }
}

# ---------- Estado de Terraform ----------
resource "aws_s3_bucket" "tfstate" {
  bucket = "kutnz-tfstate-${local.account}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- Roles de despliegue (backend y frontend), uno por ambiente ----------
data "aws_iam_policy_document" "trust_deploy" {
  for_each = local.ambientes
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Solo los jobs que corren en el environment de GitHub de ese ambiente (dev o prod).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.repo["kutnz-backend"]}:environment:${each.key}",
        "${local.repo["kutnz-frontend"]}:environment:${each.key}",
      ]
    }
  }
}

data "aws_iam_policy_document" "deploy" {
  for_each = local.ambientes
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
    "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"]
    resources = ["arn:aws:ecr:${local.region}:${local.account}:repository/${each.value.stack}"]
  }
  statement {
    sid       = "Leer"
    actions   = ["autoscaling:DescribeAutoScalingGroups", "autoscaling:DescribeInstanceRefreshes", "ec2:DescribeLaunchTemplateVersions"]
    resources = ["*"]
  }
  statement {
    sid       = "InstanceRefresh"
    actions   = ["autoscaling:StartInstanceRefresh"]
    resources = ["arn:aws:autoscaling:${local.region}:${local.account}:autoScalingGroup:*:autoScalingGroupName/${each.value.stack}-app"]
  }
  statement {
    sid       = "CloudFront"
    actions   = ["cloudfront:ListDistributions", "cloudfront:GetDistributionConfig", "cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = ["*"]
  }
  statement {
    sid       = "StaticList"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${each.value.stack}-static-*"]
  }
  statement {
    sid       = "StaticWrite"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:aws:s3:::${each.value.stack}-static-*/static/*"]
  }
}

resource "aws_iam_role" "deploy" {
  for_each             = local.ambientes
  name                 = "kutnz-gh-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.trust_deploy[each.key].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "deploy" {
  for_each = local.ambientes
  role     = aws_iam_role.deploy[each.key].id
  policy   = data.aws_iam_policy_document.deploy[each.key].json
}

# ---------- Roles de Terraform (repo kutnz-infra) ----------
# plan: en los pull requests, solo lectura (+ el estado). apply: environment "infra" con aprobación.
locals {
  infra_sub = { plan = "pull_request", apply = "environment:infra" }
}

data "aws_iam_policy_document" "trust_infra" {
  for_each = local.infra_sub
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.repo["kutnz-infra"]}:${each.value}"]
    }
  }
}

resource "aws_iam_role" "infra" {
  for_each             = local.infra_sub
  name                 = "kutnz-gh-infra-${each.key}"
  assume_role_policy   = data.aws_iam_policy_document.trust_infra[each.key].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "infra_apply" {
  role       = aws_iam_role.infra["apply"].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "infra_plan" {
  role       = aws_iam_role.infra["plan"].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "infra_plan_extra" {
  statement {
    sid       = "EstadoYBloqueo"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }
  statement {
    sid       = "LeerSecretoDelStack"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:aws:secretsmanager:${local.region}:${local.account}:secret:kutnz-dev/*"]
  }
}

resource "aws_iam_role_policy" "infra_plan_extra" {
  role   = aws_iam_role.infra["plan"].id
  policy = data.aws_iam_policy_document.infra_plan_extra.json
}

output "tfstate_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "roles" {
  value = merge(
    { for k, r in aws_iam_role.deploy : "deploy_${k}" => r.arn },
    { for k, r in aws_iam_role.infra : "infra_${k}" => r.arn },
  )
}
