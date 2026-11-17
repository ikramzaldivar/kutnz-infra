# ---------- DynamoDB (base de datos distribuida, cifrada en reposo) ----------
resource "aws_dynamodb_table" "links" {
  name         = "${var.name}-links"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "code"

  attribute {
    name = "code"
    type = "S"
  }
  attribute {
    name = "owner_id"
    type = "S"
  }
  attribute {
    name = "created_at"
    type = "N"
  }

  # Índice disperso: solo los enlaces con dueño aparecen en el panel.
  global_secondary_index {
    name            = "owner-index"
    hash_key        = "owner_id"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  # Cifrado en reposo: DynamoDB siempre cifra con una llave propiedad de AWS (sin costo).
}

resource "aws_dynamodb_table" "stats" {
  name         = "${var.name}-stats"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "code"
  range_key    = "dim"

  attribute {
    name = "code"
    type = "S"
  }
  attribute {
    name = "dim"
    type = "S"
  }

  # Cifrado en reposo: DynamoDB siempre cifra con una llave propiedad de AWS (sin costo).
}

resource "aws_dynamodb_table" "moderation" {
  name         = "${var.name}-moderation"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "kind"
  range_key    = "value"

  attribute {
    name = "kind"
    type = "S"
  }
  attribute {
    name = "value"
    type = "S"
  }

  # Cifrado en reposo: DynamoDB siempre cifra con una llave propiedad de AWS (sin costo).
}

# ---------- SQS: eventos de clic (asíncrono) con dead-letter queue ----------
resource "aws_sqs_queue" "clicks_dlq" {
  name                      = "${var.name}-clicks-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "clicks" {
  name                       = "${var.name}-clicks"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.clicks_dlq.arn
    maxReceiveCount     = 5
  })
}

# ---------- ElastiCache (Redis/Valkey) Multi-AZ con failover automático ----------
resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name}-cache"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id       = "${var.name}-cache"
  description                = "Cache de redireccion, rate limiting e idempotencia"
  engine                     = "valkey"
  engine_version             = "8.0"
  node_type                  = var.cache_node_type
  num_cache_clusters         = var.cache_nodes
  automatic_failover_enabled = var.cache_nodes > 1
  multi_az_enabled           = var.cache_nodes > 1
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.main.name
  security_group_ids         = [aws_security_group.redis.id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  apply_immediately          = true
}

# ---------- Secretos ----------
resource "random_password" "visitor_salt" {
  length  = 48
  special = false
}

resource "random_password" "origin_secret" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "${var.name}/app"
  recovery_window_in_days = 0 # permite destroy/apply repetidos sin esperar 7 días
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id = aws_secretsmanager_secret.app.id
  secret_string = jsonencode({
    KUT_VISITOR_SALT_SECRET   = random_password.visitor_salt.result
    KUT_SAFE_BROWSING_API_KEY = var.safe_browsing_api_key
  })
}

# ---------- Frontend estático (S3 privado, servido solo por CloudFront) ----------
resource "aws_s3_bucket" "static" {
  bucket_prefix = "${var.name}-static-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "static" {
  bucket                  = aws_s3_bucket.static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  bucket = aws_s3_bucket.static.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Los archivos de /static/* los publica el pipeline del repo kutnz-frontend (aws s3 sync), no Terraform.

resource "aws_s3_bucket_policy" "static" {
  bucket = aws_s3_bucket.static.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.static.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.main.arn } }
    }]
  })
}
