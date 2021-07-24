output "function_app_default_hostname" {
  value = azurerm_function_app.function-app.default_hostname
  description = "Deployed function app hostname"
}
