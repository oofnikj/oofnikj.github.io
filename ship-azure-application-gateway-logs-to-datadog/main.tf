data "azurerm_monitor_diagnostic_categories" "app_gw" {
  resource_id = var.azurerm_application_gateway_id
}

data "azurerm_storage_account" "storage" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
}

# Diagnostic setting to push App Gateway access logs to storage
resource "azurerm_monitor_diagnostic_setting" "app_gw_logs" {
  name               = "${var.prefix}-app-gw-logs"
  target_resource_id = var.azurerm_application_gateway_id
  storage_account_id = data.azurerm_storage_account.storage.id

  dynamic log {
    for_each = data.azurerm_monitor_diagnostic_categories.app_gw.logs
    content {
      category = log.key
      retention_policy {
        enabled = true
        days    = 7
      }
    }
  }

  dynamic metric {
    for_each = data.azurerm_monitor_diagnostic_categories.app_gw.metrics
    content {
      category = metric.key
      retention_policy {
        enabled = true
        days    = 7
      }
    }
  }
}

resource "time_rotating" "sas" {
  rotation_days = 365
}

# Obtain Shared Access Signature token for our function to read from our storage account
data "azurerm_storage_account_sas" "sas" {
  connection_string = data.azurerm_storage_account.storage.primary_connection_string
  https_only        = true
  start             = formatdate("YYYY-MM-DD", time_rotating.sas.id)
  expiry = formatdate("YYYY-MM-DD", timeadd(time_rotating.sas.id,
  "${time_rotating.sas.rotation_days * 24}h"))
  resource_types {
    object    = true
    container = false
    service   = false
  }
  services {
    blob  = true
    queue = false
    table = false
    file  = false
  }
  permissions {
    read    = true
    write   = false
    delete  = false
    list    = false
    add     = false
    create  = false
    update  = false
    process = false
  }
}

# Storage container where our function code will be uploaded
resource "azurerm_storage_container" "function_releases" {
  name                  = "function-releases"
  storage_account_name  = data.azurerm_storage_account.storage.name
  container_access_type = "private"
}

# Create our function zip archive
data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/function.zip"
  excludes = [
    "${path.module}/function/local.settings.json",
    "${path.module}/function/.gitignore"
  ]
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

# Actually upload it to storage
resource "azurerm_storage_blob" "datadog_logs_sender" {
  type                   = "Block"
  storage_account_name   = data.azurerm_storage_account.storage.name
  storage_container_name = azurerm_storage_container.function_releases.name
  name                   = format("function_%s.zip", data.archive_file.function.output_sha)
  source                 = data.archive_file.function.output_path
}

# The 'implicit' app service plan discussed earlier
resource "azurerm_app_service_plan" "datadog_logs_sender" {
  name = format(
  "%s-%s", "datadog-logs-sender", data.azurerm_resource_group.rg.name)
  location            = data.azurerm_resource_group.rg.location
  resource_group_name = data.azurerm_resource_group.rg.name
  kind                = "functionapp"
  reserved            = true

  sku {
    tier = "Dynamic" # we're using serverless mode
    size = "Y1"
  }
}

resource "azurerm_function_app" "datadog_logs_sender" {
  name = format(
  "%s-%s", "datadog-logs-sender", data.azurerm_resource_group.rg.name)
  location                   = data.azurerm_resource_group.rg.location
  resource_group_name        = data.azurerm_resource_group.rg.name
  app_service_plan_id        = azurerm_app_service_plan.datadog_logs_sender.id
  storage_account_name       = data.azurerm_storage_account.storage.name
  storage_account_access_key = data.azurerm_storage_account.storage.primary_access_key
  os_type                    = "linux"

  # Environment variables for our function runtime along with some voodoo
  # to tell Azure where to find our function code
  app_settings = {
    DD_SOURCE                    = "azure-application-gateway"
    DD_SERVICE                   = var.azurerm_application_gateway_id
    DD_SOURCE_CATEGORY           = "azure"
    DD_SITE                      = "datadoghq.com"
    DD_TAGS                      = join(",", [for k, v in var.tags : "${k}:${v}"])
    DD_API_KEY                   = var.datadog_api_key
    FUNCTIONS_WORKER_RUNTIME     = "node"
    WEBSITE_NODE_DEFAULT_VERSION = "~12"
    WEBSITE_RUN_FROM_PACKAGE = format(
      "https://%s.blob.core.windows.net/%s/%s%s",
      data.azurerm_storage_account.storage.name,
      azurerm_storage_container.function_releases.name,
      azurerm_storage_blob.datadog_logs_sender.name,
      data.azurerm_storage_account_sas.sas.sas
    )
  }
}