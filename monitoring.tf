resource "azurerm_monitor_action_group" "alerts" {
  name                = "myvpn-tf-alerts"
  resource_group_name = azurerm_resource_group.vpn.name
  short_name          = "myvpnalert"

  email_receiver {
    name          = "admin"
    email_address = var.alert_email
  }
}

resource "azurerm_monitor_activity_log_alert" "nsg_changed" {
  name                = "myvpn-tf-nsg-changed"
  resource_group_name = azurerm_resource_group.vpn.name
  location            = "global"
  scopes              = [azurerm_network_security_group.vpn.id]
  description         = "The NSG of the MyVPN server was changed"

  criteria {
    category = "Administrative"
    statuses = ["Succeeded"]
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }
}

resource "azurerm_monitor_activity_log_alert" "run_command" {
  name                = "myvpn-tf-run-command"
  resource_group_name = azurerm_resource_group.vpn.name
  location            = "global"
  scopes              = [azurerm_linux_virtual_machine.vpn.id]
  description         = "Run Command was used on the MyVPN server"

  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.Compute/virtualMachines/runCommand/action"
    statuses       = ["Succeeded"]
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts.id
  }
}
