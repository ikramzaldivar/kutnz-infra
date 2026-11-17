variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "kutnz"
}

variable "domain" {
  description = "Dominio público de los enlaces cortos."
  type        = string
  default     = "kut.nz"
}

variable "create_hosted_zone" {
  description = "true: Terraform crea la zona de Route 53 (luego hay que apuntar los NS del registrador). false: usa una zona existente."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = "Etiqueta de la imagen en ECR que corren las instancias."
  type        = string
  default     = "latest"
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "asg_min" {
  type    = number
  default = 2
}

variable "asg_max" {
  description = "Tope del ASG: también limita cuánto puede costar un ataque de tráfico."
  type        = number
  default     = 6
}

variable "cache_node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "alert_email" {
  description = "Correo para alarmas de CloudWatch y del presupuesto."
  type        = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 40
}

variable "safe_browsing_api_key" {
  description = "API key de Google Safe Browsing (se guarda en Secrets Manager)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

# IPs exentas SOLO del rate limit global, para pruebas de carga propias (k6). Vacío en operación normal.
variable "loadtest_cidrs" {
  type    = list(string)
  default = []
}

# Eventos con fecha conocida (p. ej. la feria): el ASG sube su mínimo ANTES del pico, porque target tracking
# tarda ≈ 8 min en dar capacidad nueva (medido). Horas en UTC, formato 2026-11-25T15:00:00Z.
variable "eventos" {
  type = list(object({
    nombre = string
    inicio = string
    fin    = string
    minimo = number
  }))
  default = []
}

# ---------- Agregados para los ambientes de Infraestructura para el Desarrollo Continuo ----------
variable "zone_name" {
  description = "Zona de Route 53 donde se crean los registros (p. ej. kut.nz para dev.kut.nz). Vacío = var.domain."
  type        = string
  default     = ""
}

variable "cache_nodes" {
  description = "Nodos de Valkey: 2 = Multi-AZ con failover (Prod); 1 = un solo nodo (Dev, más barato)."
  type        = number
  default     = 2
}

variable "memory_metrics" {
  description = "Instala el agente de CloudWatch para publicar la memoria (CWAgent mem_used_percent)."
  type        = bool
  default     = false
}

variable "extra_env" {
  description = "Variables de entorno adicionales para los contenedores (p. ej. KUT_APM_DEMO en Dev)."
  type        = map(string)
  default     = {}
}

variable "refresh_min_healthy" {
  description = "Instance refresh: porcentaje mínimo sano. 100 + max 200 = crea la instancia nueva antes de quitar la vieja."
  type        = number
  default     = 50
}

variable "refresh_max_healthy" {
  type    = number
  default = 100
}
