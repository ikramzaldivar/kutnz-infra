output "url" {
  description = "URL pública del ambiente."
  value       = "https://${var.domain}"
}

output "cloudfront_domain" {
  description = "Dominio *.cloudfront.net de la distribución."
  value       = aws_cloudfront_distribution.main.domain_name
}

output "ecr_repository" {
  description = "URL del repositorio de ECR de la imagen del backend."
  value       = aws_ecr_repository.app.repository_url
}

output "cognito_login_domain" {
  description = "Dominio de Cognito para el inicio de sesión."
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "cognito_user_pool_id" {
  description = "ID del user pool de Cognito."
  value       = aws_cognito_user_pool.main.id
}

output "asg_name" {
  description = "Nombre del Auto Scaling Group de la API."
  value       = aws_autoscaling_group.app.name
}

output "dashboard_url" {
  description = "Dashboard de CloudWatch del ambiente."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${var.name}"
}

output "name_servers" {
  description = "Solo si create_hosted_zone = true: pon estos NS en el registrador de kut.nz."
  value       = var.create_hosted_zone ? aws_route53_zone.main[0].name_servers : []
}

output "cloudfront_distribution_id" {
  description = "ID de la distribución de CloudFront."
  value       = aws_cloudfront_distribution.main.id
}

output "static_bucket" {
  description = "Bucket de S3 de los archivos de /static/*."
  value       = aws_s3_bucket.static.bucket
}
