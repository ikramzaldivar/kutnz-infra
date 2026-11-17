# ---------- Cuentas de usuario: Amazon Cognito ----------
resource "random_string" "cognito_suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "aws_cognito_user_pool" "main" {
  name                     = "${var.name}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = "INACTIVE"
  mfa_configuration        = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 10
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = false
    require_uppercase                = false
    temporary_password_validity_days = 3
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.name}-${random_string.cognito_suffix.result}"
  user_pool_id = aws_cognito_user_pool.main.id
}

# Cliente público (SPA): authorization code + PKCE, sin secreto en el navegador.
resource "aws_cognito_user_pool_client" "web" {
  name                                 = "${var.name}-web"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = ["https://${var.domain}/auth/callback", "https://www.${var.domain}/auth/callback"]
  logout_urls                          = ["https://${var.domain}/", "https://www.${var.domain}/"]
  # USER_PASSWORD_AUTH: el login propio de kut.nz manda la contraseña a Cognito por TLS
  # (la página genérica de Cognito no permite igualar la estética del sitio).
  explicit_auth_flows           = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH", "ALLOW_USER_PASSWORD_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  access_token_validity         = 60
  id_token_validity             = 60
  refresh_token_validity        = 7
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

resource "aws_cognito_user_group" "admin" {
  name         = "admin"
  user_pool_id = aws_cognito_user_pool.main.id
  description  = "Moderadores: desactivan enlaces y bloquean cuentas o dominios"
}
