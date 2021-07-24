provider "azurerm" {
  features {}
}


locals {
  timestamp = "${timestamp()}"
  static_files =  toset([
    for f in fileset(var.built_static_files_dir, "**"):
      f if f != ".gitkeep"
  ]) 
}


resource "azurerm_resource_group" "rg" {
  name     = "dev-todoapp"
  location = var.location

  tags = {
    displayName = "dev-todoapp"
  }
}

resource "azurerm_cosmosdb_account" "db-account" {
  name                = "dev-todoapp"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  consistency_policy {
    consistency_level = "Session"
  }

  capabilities {
    name = "EnableServerless"
  }

  geo_location {
    location          = azurerm_resource_group.rg.location
    failover_priority = 0
  }

  tags = {
    CosmosAccountType       = "Non-Production"
    defaultExperience       = "Core (SQL)"
    hidden-cosmos-mmspecial = ""
    displayName                   = "dev-todoapp"
  }
}

resource "azurerm_cosmosdb_sql_database" "db" {
  name                = "dev-todoapp"
  resource_group_name = azurerm_cosmosdb_account.db-account.resource_group_name
  account_name        = azurerm_cosmosdb_account.db-account.name
}

resource "azurerm_cosmosdb_sql_container" "db-container" {
  name                = "todo-tasks"
  resource_group_name = azurerm_cosmosdb_account.db-account.resource_group_name
  account_name        = azurerm_cosmosdb_account.db-account.name
  database_name       = azurerm_cosmosdb_sql_database.db.name
}

resource "azurerm_storage_account" "storage-account" {
  name                     = "devtodoapp"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"
  enable_https_traffic_only = true

  static_website {
    index_document     = "index.html"
    error_404_document = "404.html"
  }

  tags = {
    displayName = "dev-todoapp"
    env = "dev"
  }
}

resource "null_resource" "build_static" {  
  triggers = {
    always = local.timestamp
  }
  provisioner "local-exec" {
    command = "cd ../src/main/frontend/ && date && rm -rf out && npm install && npm run build"
  }
}

# Upload static files
resource "azurerm_storage_blob" "upload_static_files" {
  for_each = local.static_files

  depends_on = [ azurerm_storage_account.storage-account, null_resource.build_static ]

  name                   = each.value
  storage_account_name = azurerm_storage_account.storage-account.name
  storage_container_name = "$web"
  type                   = "Block"
  #content_type = "text/html"
  content_type = lookup(var.file_extension_to_content_type, element(split(".", each.value), length(split(".", each.value))-1), "text/plain")
  source                 = "${var.built_static_files_dir}${each.value}"
}

resource "azurerm_signalr_service" "signalr" {
  name                = "dev-todoapp"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  sku {
    name     = "Free_F1"
    capacity = 1
  }

  features {
    flag  = "ServiceMode"
    value = "Serverless"
    }
#  features {
#    flag  = "EnableLiveTrace"
#    value = "False"
#  }

  features {
    flag  = "EnableConnectivityLogs"
    value = "False"
  }

  features {
    flag  = "EnableMessagingLogs"
    value = "False"
  }

  lifecycle {
    ignore_changes = [
      features
    ]
  }

  tags = {
    displayName = "dev-todoapp"
    env = "dev"
  }
}

resource "azurerm_app_service_plan" "service-plan" {
  name                = "dev-todoapp"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  kind                = "FunctionApp"
  reserved            = true //Use Linux OS

  sku {
    tier = "Dynamic"
    size = "Y1"
  }

  tags = {
    displayName = "dev-todoapp"
    env = "dev"
  }
}

# Storage resources for the Function app
data "azurerm_storage_account_sas" "sas" {
    connection_string = "${azurerm_storage_account.storage-account.primary_connection_string}"
    https_only = true
    start = "2021-07-01"
    expiry = "2023-12-31"
    resource_types {
        object = true
        container = false
        service = false
    }
    services {
        blob = true
        queue = false
        table = false
        file = false
    }
    permissions {
        read = true
        write = false
        delete = false
        list = false
        add = false
        create = false
        update = false
        process = false
    }
}

resource "azurerm_storage_container" "deployments" {
    name = "function-releases"
    storage_account_name = "${azurerm_storage_account.storage-account.name}"
    container_access_type = "private"
}

resource "null_resource" "build_function" {  
  triggers = {
    always = local.timestamp
  }
  provisioner "local-exec" {
    command = "cd ../src/main/functions/ && date && npm install && npm run build"
  }
}

resource "azurerm_storage_blob" "appcode" {
    depends_on = [ null_resource.build_function ]
    name = "functionapp.zip"
    storage_account_name = "${azurerm_storage_account.storage-account.name}"
    storage_container_name = "${azurerm_storage_container.deployments.name}"
    type = "Block"
    source = "${var.functionapp}"
}

# The Function App itself
resource "azurerm_function_app" "function-app" {
  depends_on = [ azurerm_storage_blob.appcode ]
  name                       = "dev-todoapp"
  location                   = var.location
  resource_group_name        = azurerm_resource_group.rg.name
  app_service_plan_id        = azurerm_app_service_plan.service-plan.id
  storage_account_name       = azurerm_storage_account.storage-account.name
  storage_account_access_key = azurerm_storage_account.storage-account.primary_access_key
  https_only                 = true
  version                    = "~3"
  os_type                    = "linux"

  site_config {
    always_on                 = false
    linux_fx_version          = "NODE|14-lts"
    use_32_bit_worker_process = false
  }

  app_settings = {
    holitodoappdb_DOCUMENTDB       = azurerm_cosmosdb_account.db-account.connection_strings[0]
    DB_NAME = azurerm_cosmosdb_account.db-account.name
    "STATIC_WEBSITE_URL"           = azurerm_storage_account.storage-account.primary_web_host
    "AzureSignalRConnectionString" = azurerm_signalr_service.signalr.primary_connection_string
    "FUNCTIONS_WORKER_RUNTIME"     = "node"
    #HASH = "${base64encode(filesha256("${var.functionapp}"))}"
    WEBSITE_RUN_FROM_PACKAGE = "https://${azurerm_storage_account.storage-account.name}.blob.core.windows.net/${azurerm_storage_container.deployments.name}/${azurerm_storage_blob.appcode.name}${data.azurerm_storage_account_sas.sas.sas}"
    "APPINSIGHTS_INSTRUMENTATIONKEY" = azurerm_application_insights.application_insights.instrumentation_key
  }

  tags = {
    displayName = "dev-todoapp"
    env = "dev"
  }

  # lifecycle {
  #   ignore_changes = [
  #     app_settings["WEBSITE_RUN_FROM_PACKAGE"]
  #   ]
  # }
}

resource "azurerm_application_insights" "application_insights" {
  name                = "dev-todoapp"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  application_type    = "Node.JS"
}

output "timestamp" {
  value = local.timestamp
  description = "timestamp() function"
}

