###############################################################################
# compute/build-agent — Linux self-hosted build agent (Ubuntu 22.04)
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
  default = "klzbuild"
}
variable "ssh_public_key" { type = string }
variable "tags" {
  type    = map(string)
  default = {}
}

resource "azurerm_network_interface" "build" {
  name                = "nic-build-${var.base_name}"
  location            = var.location
  resource_group_name = var.resource_group_name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "build" {
  name                  = "vmb-${trim(substr(var.base_name, 0, 11), "-_")}"
  location              = var.location
  resource_group_name   = var.resource_group_name
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.build.id]
  tags                  = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    name                 = "osdisk-build-${var.base_name}"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}

output "id" { value = azurerm_linux_virtual_machine.build.id }
output "name" { value = azurerm_linux_virtual_machine.build.name }
output "private_ip" { value = azurerm_network_interface.build.private_ip_address }
