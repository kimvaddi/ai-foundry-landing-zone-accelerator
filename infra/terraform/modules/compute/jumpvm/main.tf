###############################################################################
# compute/jumpvm — Windows jumpbox (Win11 multi-session)
###############################################################################

variable "base_name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "subnet_id" { type = string }
variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}
variable "admin_username" {
  type    = string
  default = "klzadmin"
}
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_network_interface" "jump" {
  name                = "nic-jump-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "jump" {
  name                  = "vmj-${trim(substr(var.base_name, 0, 11), "-_")}"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.jump.id]
  tags                  = var.tags

  os_disk {
    name                 = "osdisk-jump-${var.base_name}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsDesktop"
    offer     = "Windows-11"
    sku       = "win11-23h2-pro"
    version   = "latest"
  }
}

output "id" { value = azurerm_windows_virtual_machine.jump.id }
output "name" { value = azurerm_windows_virtual_machine.jump.name }
output "private_ip" { value = azurerm_network_interface.jump.private_ip_address }
