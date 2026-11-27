# ---------- Alertas ----------
resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  alb_dim = { LoadBalancer = aws_lb.main.arn_suffix }
  tg_dim  = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.app.arn_suffix }
}

resource "aws_cloudwatch_metric_alarm" "p95_latency" {
  alarm_name          = "${var.name}-p95-latencia-alta"
  alarm_description   = "SLO: p95 de respuesta del ALB por encima de 50 ms durante 5 minutos"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  dimensions          = local.alb_dim
  period              = 60
  evaluation_periods  = 5
  threshold           = 0.05
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "errors_5xx" {
  alarm_name          = "${var.name}-errores-5xx"
  alarm_description   = "Más de 1% de respuestas 5xx (presupuesto de error del SLO de 99.9%)"
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  metric_query {
    id          = "rate"
    expression  = "IF(req > 0, 100 * (FILL(e5, 0) + FILL(t5, 0)) / req, 0)"
    label       = "% de 5xx"
    return_data = true
  }
  metric_query {
    id = "e5"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = local.alb_dim
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id = "t5"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = local.alb_dim
      period      = 60
      stat        = "Sum"
    }
  }
  metric_query {
    id = "req"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = local.alb_dim
      period      = 60
      stat        = "Sum"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name  = "${var.name}-instancias-no-sanas"
  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"
  dimensions  = local.tg_dim
  statistic   = "Maximum"
  period      = 60
  # 5 minutos seguidos: una instancia nueva tarda ~2 min en arrancar durante un despliegue
  # (instance refresh); eso es normal y no debe despertar a nadie.
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_description   = "Una instancia lleva 5 minutos sin pasar el health check del ALB (fuera de un despliegue normal)"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = "${var.name}-clics-en-dlq"
  alarm_description   = "Eventos de clic que el worker no pudo procesar"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.clicks_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------- Dashboard para la demo ----------
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.name
  dashboard_body = jsonencode({
    widgets = concat([
      {
        type = "metric", x = 0, y = 18, width = 12, height = 6
        properties = {
          title = "CPU de las instancias (%)", region = var.region, period = 60, view = "timeSeries"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", aws_autoscaling_group.app.name, { stat = "Average" }],
            ["...", { stat = "Maximum" }],
          ]
        }
      },
      ], var.memory_metrics ? [
      {
        type = "metric", x = 12, y = 18, width = 12, height = 6
        properties = {
          title = "Memoria usada de las instancias (%)", region = var.region, period = 60, view = "timeSeries"
          metrics = [
            ["CWAgent", "mem_used_percent", "AutoScalingGroupName", aws_autoscaling_group.app.name, { stat = "Average" }],
            ["...", { stat = "Maximum" }],
          ]
        }
      },
      ] : [], [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "Peticiones por minuto (ALB)", region = var.region, stat = "Sum", period = 60, view = "timeSeries"
          metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.main.arn_suffix]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title = "Latencia p50 / p95 / p99 (s)", region = var.region, period = 60, view = "timeSeries"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.main.arn_suffix, { stat = "p50" }],
            ["...", { stat = "p95" }], ["...", { stat = "p99" }],
          ]
          annotations = { horizontal = [{ label = "SLO p95", value = 0.05 }] }
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 8, height = 6
        properties = {
          title = "Instancias en servicio (ASG)", region = var.region, stat = "Average", period = 60
          metrics = [
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", aws_autoscaling_group.app.name],
            [".", "GroupDesiredCapacity", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 8, y = 6, width = 8, height = 6
        properties = {
          title = "Caché: aciertos vs fallos", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ElastiCache", "CacheHits", "ReplicationGroupId", aws_elasticache_replication_group.main.id],
            [".", "CacheMisses", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 16, y = 6, width = 8, height = 6
        properties = {
          title = "Respuestas por código", region = var.region, stat = "Sum", period = 60
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_3XX_Count", "LoadBalancer", aws_lb.main.arn_suffix],
            [".", "HTTPCode_Target_4XX_Count", ".", "."],
            [".", "HTTPCode_Target_5XX_Count", ".", "."],
            [".", "HTTPCode_ELB_5XX_Count", ".", "."],
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 12, height = 6
        properties = {
          title = "DynamoDB: latencia y throttling", region = var.region, period = 60
          metrics = [
            ["AWS/DynamoDB", "SuccessfulRequestLatency", "TableName", aws_dynamodb_table.links.name, "Operation", "GetItem", { stat = "Average" }],
            [".", "ThrottledRequests", ".", ".", ".", ".", { stat = "Sum" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 12, width = 12, height = 6
        properties = {
          title = "Cola de clics (asíncrono)", region = var.region, period = 60
          metrics = [
            ["AWS/SQS", "NumberOfMessagesSent", "QueueName", aws_sqs_queue.clicks.name, { stat = "Sum" }],
            [".", "ApproximateAgeOfOldestMessage", ".", ".", { stat = "Maximum" }],
          ]
        }
      },
    ])
  })
}

# ---------- Presupuesto: aviso antes de gastar de más ----------
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-mensual"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  cost_filter {
    name = "TagKeyValue"
    # Formato de AWS: "user:<tag>$<valor>". Con "$${...}" HCL escribía "${var.name}" literal y el filtro no coincidía con nada.
    values = [format("user:Project$%s", var.name)]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
