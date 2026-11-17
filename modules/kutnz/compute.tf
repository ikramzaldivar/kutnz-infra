# ---------- Imagen de la aplicación ----------
resource "aws_ecr_repository" "app" {
  name                 = var.name
  image_tag_mutability = "MUTABLE"
  force_delete         = true
  image_scanning_configuration {
    scan_on_push = true # escaneo de vulnerabilidades de la imagen
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1, description = "Conserva las 10 imagenes mas recientes"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 10 }
      action       = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.name}/app"
  retention_in_days = 14
}

# ---------- IAM: mínimo privilegio para las instancias ----------
data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${var.name}-app"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

data "aws_iam_policy_document" "app" {
  statement {
    sid = "DynamoDB"
    actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
    "dynamodb:Query", "dynamodb:BatchWriteItem"]
    resources = [
      aws_dynamodb_table.links.arn, "${aws_dynamodb_table.links.arn}/index/*",
      aws_dynamodb_table.stats.arn, aws_dynamodb_table.moderation.arn,
    ]
  }
  statement {
    sid       = "ClicksQueue"
    actions   = ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.clicks.arn]
  }
  statement {
    sid       = "Secret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.app.arn]
  }
  statement {
    sid       = "PullImage"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.app.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.app.arn}:*"]
  }
}

resource "aws_iam_role_policy" "app" {
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

# Session Manager para entrar a las instancias sin abrir el puerto 22 ni usar llaves SSH.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Agente de CloudWatch (memoria): solo en los ambientes con memory_metrics = true.
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  count      = var.memory_metrics ? 1 : 0
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-app"
  role = aws_iam_role.app.name
}

# ---------- Plantilla de lanzamiento + Auto Scaling Group en dos AZ ----------
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  app_env = merge({
    KUT_PUBLIC_HOST          = var.domain
    KUT_PUBLIC_SCHEME        = "https"
    KUT_EXTRA_SELF_HOSTS     = "${local.origin_host},${aws_cloudfront_distribution.main.domain_name}"
    KUT_AWS_REGION           = var.region
    KUT_TABLE_LINKS          = aws_dynamodb_table.links.name
    KUT_TABLE_STATS          = aws_dynamodb_table.stats.name
    KUT_TABLE_MODERATION     = aws_dynamodb_table.moderation.name
    KUT_CLICKS_QUEUE_URL     = aws_sqs_queue.clicks.url
    KUT_REDIS_URL            = "rediss://${aws_elasticache_replication_group.main.primary_endpoint_address}:6379/0"
    KUT_AUTH_MODE            = "cognito"
    KUT_COGNITO_USER_POOL_ID = aws_cognito_user_pool.main.id
    KUT_COGNITO_CLIENT_ID    = aws_cognito_user_pool_client.web.id
    KUT_COGNITO_DOMAIN       = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
  }, var.extra_env)
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }
  vpc_security_group_ids = [aws_security_group.app.id]
  metadata_options {
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 2
  }
  monitoring {
    enabled = true
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
      volume_type = "gp3"
      encrypted   = true
    }
  }
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    region         = var.region
    registry       = split("/", aws_ecr_repository.app.repository_url)[0]
    image          = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    secret_arn     = aws_secretsmanager_secret.app.arn
    log_group      = aws_cloudwatch_log_group.app.name
    memory_metrics = var.memory_metrics
    env_lines      = join("\n", [for k, v in local.app_env : "${k}=${v}"])
  }))
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-app" }
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${var.name}-app"
  min_size                  = var.asg_min
  max_size                  = var.asg_max
  desired_capacity          = var.asg_min
  vpc_zone_identifier       = aws_subnet.private[*].id
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180
  default_instance_warmup   = 120
  enabled_metrics           = ["GroupInServiceInstances", "GroupDesiredCapacity", "GroupPendingInstances"]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Al cambiar la imagen o la plantilla, reemplaza instancias de a poco sin tirar el servicio.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = var.refresh_min_healthy
      max_healthy_percentage = var.refresh_max_healthy
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-app"
    propagate_at_launch = true
  }

  # Auto Scaling es dueño de la capacidad deseada: sin esto, cada apply la regresaba a asg_min y
  # un despliegue en plena carga le quitaba las instancias recién agregadas (lo vimos en la prueba de carga).
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# Escalado programado para eventos conocidos: sube el mínimo antes del pico y lo regresa al terminar.
resource "aws_autoscaling_schedule" "evento_inicio" {
  for_each               = { for e in var.eventos : e.nombre => e }
  scheduled_action_name  = "${var.name}-${each.key}-inicio"
  autoscaling_group_name = aws_autoscaling_group.app.name
  start_time             = each.value.inicio
  min_size               = each.value.minimo
  max_size               = var.asg_max
  desired_capacity       = -1 # solo sube el mínimo: si ya hay más instancias por carga, no las quita (nos pasó en la prueba)
}

resource "aws_autoscaling_schedule" "evento_fin" {
  for_each               = { for e in var.eventos : e.nombre => e }
  scheduled_action_name  = "${var.name}-${each.key}-fin"
  autoscaling_group_name = aws_autoscaling_group.app.name
  start_time             = each.value.fin
  min_size               = var.asg_min
  max_size               = var.asg_max
  desired_capacity       = -1 # no la fuerza: target tracking la baja sola si ya no hay carga
}

# Escalado por demanda: peticiones por instancia (la métrica que más se parece a la carga real
# de un servicio de redirecciones) y CPU como respaldo.
resource "aws_autoscaling_policy" "requests" {
  name                   = "${var.name}-requests-per-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
    target_value = 3000 # peticiones por instancia por minuto (~50 req/s)
  }
}

resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-cpu"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"
  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}
