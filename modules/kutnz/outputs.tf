output "url" {
  value = "https://${var.domain}"
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.main.domain_name
}

output "ecr_repository" {
  value = aws_ecr_repository.app.repository_url
}

output "cognito_login_domain" {
  value = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "dashboard_url" {
  value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${var.name}"
}

output "name_servers" {
  description = "Solo si create_hosted_zone = true: pon estos NS en el registrador de kut.nz."
  value       = var.create_hosted_zone ? aws_route53_zone.main[0].name_servers : []
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.main.id
}

output "static_bucket" {
  value = aws_s3_bucket.static.bucket
}
