terraform {
  backend "azurerm" {
    resource_group_name  = var.tf_backend_resource_group_name
    storage_account_name = var.tf_backend_storage_account_name
    container_name       = "tfstate"
    key                  = "dev-todoapp.tfstate"
  }
}