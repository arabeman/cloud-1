# you will use output values to organize data to be easily queried and displayed to the Terraform user

output "resource_group_id" {
  description = "The ID of the Azure Resource Group"
  value       = azurerm_resource_group.rg.id
}