resource "azurerm_linux_virtual_machine" "vpn" {
  name                  = "myvpn-tf-vm"
  resource_group_name   = azurerm_resource_group.vpn.name
  location              = azurerm_resource_group.vpn.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.vpn.id]

  custom_data = base64encode(replace(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    endpoint      = azurerm_public_ip.vpn.ip_address
    add_client    = file("${path.module}/scripts/add_client.sh")
    remove_client = file("${path.module}/scripts/remove_client.sh")
    list_clients  = file("${path.module}/scripts/list_clients.sh")
    admin_public_key = var.admin_public_key
  }), "\r\n", "\n"))

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  secure_boot_enabled = true
  vtpm_enabled        = true
}

output "ssh_command" {
  value = "ssh ${var.admin_username}@10.8.0.1"
}