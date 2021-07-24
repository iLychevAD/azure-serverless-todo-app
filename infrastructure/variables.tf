variable "location" {
  type        = string
  description = "Azure region to deploy module to"
}

variable "functionapp" {
  type = string
  default = "../src/main/functions/build/app-130.zip"
}

variable "built_static_files_dir" {
  type = string
  default = "../src/main/frontend/out/"
}

variable "file_extension_to_content_type" {
  type = map(string)
  default = {
    "css" = "text/css"
    "js" = "text/javascript"
    "html" = "text/html"
  }
}

variable "tf_backend_resource_group_name" {
  type = string
}
variable "tf_backend_storage_account_name" {
  type = string
}