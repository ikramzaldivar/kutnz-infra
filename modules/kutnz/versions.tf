# Módulo de un ambiente completo de kut.nz. Copia organizada de kutnz/infra (Sistemas Escalables):
# el proveedor y el backend los define cada ambiente en envs/<ambiente>.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.80" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
