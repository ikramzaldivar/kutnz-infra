# Ambiente Dev de kut.nz (https://dev.kut.nz): mismo módulo que Prod, más chico y con métricas de memoria.
# Prod (https://kut.nz) es el stack existente del repo kutnz (Sistemas Escalables) y no se administra aquí.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.80" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # El bucket lo crea bootstrap/. use_lockfile: bloqueo nativo de S3, sin tabla de DynamoDB.
  backend "s3" {
    bucket       = "kutnz-tfstate-595981034933"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project     = "kutnz-dev"
      Environment = "dev"
      ManagedBy   = "terraform"
      Repo        = "kutnz-infra"
      Course      = "Infraestructura-Desarrollo-Continuo"
    }
  }
}

module "kutnz" {
  source = "../../modules/kutnz"

  name      = "kutnz-dev"
  domain    = "dev.kut.nz"
  zone_name = "kut.nz" # los registros de dev.kut.nz viven en la zona de kut.nz
  vpc_cidr  = "10.30.0.0/16"

  instance_type       = "t3.small"
  asg_min             = 1
  asg_max             = 2
  cache_nodes         = 1
  memory_metrics      = true
  refresh_min_healthy = 100 # la instancia nueva arranca antes de quitar la vieja
  refresh_max_healthy = 200

  extra_env = {
    KUT_APM_DEMO = "1" # rutas /_apm/error y /_apm/message para la demo de APM
  }

  alert_email        = var.alert_email
  monthly_budget_usd = 15
}

variable "alert_email" {
  description = "Correo para alarmas y presupuesto (en GitHub: variable TF_VAR_alert_email)."
  type        = string
}

output "url" {
  value = module.kutnz.url
}

output "asg_name" {
  value = module.kutnz.asg_name
}

output "ecr_repository" {
  value = module.kutnz.ecr_repository
}

output "cloudfront_distribution_id" {
  value = module.kutnz.cloudfront_distribution_id
}

output "static_bucket" {
  value = module.kutnz.static_bucket
}

output "dashboard_url" {
  value = module.kutnz.dashboard_url
}

output "cognito_user_pool_id" {
  value = module.kutnz.cognito_user_pool_id
}
