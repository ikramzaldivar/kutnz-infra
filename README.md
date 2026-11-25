# kutnz-infra

Infraestructura como código (Terraform, AWS us-east-1) de **kut.nz**, para el proyecto final de *Infraestructura para el Desarrollo Continuo* (ITESO, 2026).

```
modules/kutnz/   Un ambiente completo: VPC en 2 AZ, ALB, ASG de EC2, Valkey, DynamoDB, SQS, Cognito,
                 CloudFront + WAF + S3, Route 53/ACM, CloudWatch (dashboard, alarmas), presupuesto.
                 Copia organizada de kutnz/infra con variables para un ambiente más chico.
envs/dev/        Ambiente Dev → https://dev.kut.nz (1–2 instancias, Valkey de 1 nodo, agente de CloudWatch).
bootstrap/       Se aplica una vez: bucket del estado de Terraform y roles IAM para GitHub Actions (OIDC).
```

**Prod** (https://kut.nz) es el stack existente del repo [kutnz](https://github.com/ikramzaldivar/kutnz) (Sistemas Escalables), creado con el mismo código. No se administra aquí. Los pipelines de backend y frontend solo le publican imágenes y archivos estáticos con el rol `kutnz-gh-prod`.

## Qué cambia respecto a `kutnz/infra`

| Variable | Prod (`kutnz`) | Dev (`envs/dev`) |
| --- | --- | --- |
| `asg_min` / `asg_max` | 2 / 6 | 1 / 2 |
| `cache_nodes` | 2 (Multi-AZ) | 1 |
| `memory_metrics` | — | `true` (agente de CloudWatch → `CWAgent mem_used_percent`) |
| `refresh_min_healthy` / `max` | 50 / 100 | 100 / 200 (arranca la nueva antes de quitar la vieja) |
| `extra_env` | — | `KUT_APM_DEMO=1` |
| `zone_name` | `kut.nz` | `kut.nz` (registros `dev.kut.nz`) |

Además, los archivos de `/static/*` ya no los sube Terraform: los publica el pipeline de [kutnz-frontend](https://github.com/ikramzaldivar/kutnz-frontend).

## Pipeline (`.github/workflows/terraform.yml`)

| Evento | Qué hace | Rol |
| --- | --- | --- |
| Pull request | `fmt -check`, `validate`, checkov y `terraform plan` comentado en el PR | `kutnz-gh-infra-plan` (solo lectura) |
| Merge a `main` | `terraform apply` de Dev, después de la aprobación del environment `infra` | `kutnz-gh-infra-apply` |
| *Run workflow* → `apply` / `destroy` | Enciende o apaga Dev (cuesta unos 0.10 USD/h encendido) | `kutnz-gh-infra-apply` |

El estado está en `s3://kutnz-tfstate-595981034933`, con bloqueo nativo de S3 (`use_lockfile`).

## Uso local

```bash
aws login --profile kutnz
export AWS_REGION=us-east-1 TF_VAR_alert_email=tu@correo.com
eval "$(aws configure export-credentials --profile kutnz --region us-east-1 --format env)"
terraform -chdir=envs/dev init
terraform -chdir=envs/dev plan
```

Antes de abrir un PR conviene correr lo mismo que revisa el pipeline:

```bash
terraform fmt -check -recursive
terraform -chdir=envs/dev validate
```

Para consultar los datos del ambiente ya creado (URL, ASG, ECR, CloudFront y bucket de estáticos):

```bash
terraform -chdir=envs/dev output
```
