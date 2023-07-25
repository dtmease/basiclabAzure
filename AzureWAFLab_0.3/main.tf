# terraform init, plan, apply, destroy
# Note: Author is still learning Terraform - proceed at own risk...
# Script assumes user is either actively logged in to Azure CLI, or relevant security principal is configured
# Main documentation : https://www.terraform.io/docs/providers/azurerm/index.html

# Specify the provider and access details
provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rgDVWA" {
  name = var.rgname
  location = var.region
}

# Create WAF vNet and sNet
resource "azurerm_virtual_network" "vnet-waf" {
  name = "vnet-waf"
  address_space = ["10.6.0.0/24"]
  location = var.region
  resource_group_name = azurerm_resource_group.rgDVWA.name
}

resource "azurerm_subnet" "snet-waf" {
  name                 = "snet-waf"
  resource_group_name  = azurerm_resource_group.rgDVWA.name
  virtual_network_name = azurerm_virtual_network.vnet-waf.name
  address_prefixes       = ["10.6.0.0/25"]
}

# Create WEB vNet and sNet
resource "azurerm_virtual_network" "vnet-web" {
  name = "vnet-web"
  address_space = ["10.6.1.0/24"]
  location = var.region
  resource_group_name = azurerm_resource_group.rgDVWA.name
}

resource "azurerm_subnet" "snet-web" {
  name                 = "snet-web"
  resource_group_name  = azurerm_resource_group.rgDVWA.name
  virtual_network_name = azurerm_virtual_network.vnet-web.name
  address_prefixes       = ["10.6.1.0/25"]

  delegation {
    name = "delegation"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action", "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action"]
    }
  }
}

# Create the vNet peering
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_peering
resource "azurerm_virtual_network_peering" "peer-dvwa-waf2web" {
  name                      = "peer-dvwa-waf2web"
  resource_group_name       = azurerm_resource_group.rgDVWA.name
  virtual_network_name      = azurerm_virtual_network.vnet-waf.name
  remote_virtual_network_id = azurerm_virtual_network.vnet-web.id
}

resource "azurerm_virtual_network_peering" "peer-dvwa-web2waf" {
  name                      = "peer-dvwa-web2waf"
  resource_group_name       = azurerm_resource_group.rgDVWA.name
  virtual_network_name      = azurerm_virtual_network.vnet-web.name
  remote_virtual_network_id = azurerm_virtual_network.vnet-waf.id
}

# For container instance it looks like container group module needs to be used
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/container_group
# Looking at Azure portal, we have a container named "ci-dvwa" and a container within that instance named "ci-dvwa", so this makes sense
# Container Group (Terraform) = Container Instance (Azure RM)? May be new terminology or quirk of module name - not sure....
# Network Profile added as this is required if IP address type is private.  Network Profiles deprecated in Azure CLI, so not sure how this will go...
resource "azurerm_container_group" "ci-dvwa" {
  name                 = "ci-dvwa"
  location             = azurerm_resource_group.rgDVWA.location
  resource_group_name  = azurerm_resource_group.rgDVWA.name
  ip_address_type      = "Private"
  os_type              = "Linux"
  restart_policy       = "OnFailure"
 # network_profile_id   = azurerm_network_profile.mynetprofile.id
  subnet_ids = [azurerm_subnet.snet-web.id]

  container {
    name   = "ci-dvwa"
    image  = "vulnerables/web-dvwa"
    cpu    = "1"
    memory = "1.5"

    ports {
      port     = 80
      protocol = "TCP"
    }
  }
}

#23/07/23 Use of network profiles deprecated, and use of subnet_ids required instead
#resource "azurerm_network_profile" "mynetprofile" {
#  name                = "mynetprofile"
#  location            = azurerm_resource_group.rgDVWA.location
#  resource_group_name = azurerm_resource_group.rgDVWA.name
#
#  container_network_interface {
#    name = "examplecnic"
#
#    ip_configuration {
#      name      = "exampleipconfig"
#      subnet_id = azurerm_subnet.snet-web.id
#    }
#  }
#}

# Create the Log Analytics Workspace
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace
# Data retention default seems to be 30 days.  For PAYG, there are additional charges is raised above 30 days (90 days with Sentinel)
# Source: https://azure.microsoft.com/en-gb/pricing/details/monitor/#pricing (and noted on Azure Portal on existing Workspace)
# For SKU, 'pricing tier' when creating in Azure Portal seems to default to Pay-as-you-go.  The SKU is optional, so will leave out, and
#  confirm on creation - I doubt that any commitment tiers will be automatically selected.  Other potential is to specify 'free', where the only
#  limitation seems to be 0.5GB
resource "azurerm_log_analytics_workspace" "log-waf" {
  name                = "log-waf"
  location            = azurerm_resource_group.rgDVWA.location
  resource_group_name = azurerm_resource_group.rgDVWA.name
  retention_in_days   = 30
}

# Create Application Gateway
# Coming soon to a tf file near you.  AG listed under network resources section in TF documentation:
# https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_gateway
# (Azure RM provider | Network | Resources) rather than its own section
# For public IP, TF example uses allocation method of dynamic

# what about the waf policy?  what about the log analytics (diagnostic) settings?  Capacity settings may need to be changed to autoscale to reflect initial lab?

resource "azurerm_public_ip" "pip-waf" {
  name                = "pip-waf"
  resource_group_name = azurerm_resource_group.rgDVWA.name
  location            = azurerm_resource_group.rgDVWA.location
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_application_gateway" "dvwa-waf" {
  name                = "dvwa-waf"
  resource_group_name = azurerm_resource_group.rgDVWA.name
  location            = azurerm_resource_group.rgDVWA.location
  firewall_policy_id = azurerm_web_application_firewall_policy.dvwawaf.id

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "waf-gw-ip-config"
    subnet_id = azurerm_subnet.snet-waf.id
  }

  frontend_port {
    name = "feport"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "feip-waf"
    public_ip_address_id = azurerm_public_ip.pip-waf.id
  }  

  backend_address_pool {
    name = "bepool-waf"
  }

  backend_http_settings {
    name                  = "behttpsetting-waf"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 60
  }

  http_listener {
    name                           = "felistener-http"
    frontend_ip_configuration_name = "feip-waf"
    frontend_port_name             = "feport"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "rqrt-waf"
    rule_type                  = "Basic"
    http_listener_name         = "felistener-http"
    backend_address_pool_name  = "bepool-waf"
    backend_http_settings_name = "behttpsetting-waf"
    priority                   = 10
  }
}

#resource "azurerm_frontdoor_firewall_policy" "example" {
#  name                              = "examplefdwafpolicy"
#  resource_group_name               = azurerm_resource_group.rgDVWA.name
#  enabled                           = true
#  mode                              = "Detection"
#}

resource "azurerm_web_application_firewall_policy" "dvwawaf" {
  name                = "example-wafpolicy"
  resource_group_name = azurerm_resource_group.rgDVWA.name
  location            = azurerm_resource_group.rgDVWA.location

  policy_settings {
    enabled                     = true
    mode                        = "Detection"
    request_body_check          = true
    file_upload_limit_in_mb     = 100
    max_request_body_size_in_kb = 128
  }

  managed_rules {

    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
      rule_group_override {
        rule_group_name = "REQUEST-920-PROTOCOL-ENFORCEMENT"
        rule {
          id      = "920300"
          enabled = true
          action  = "Log"
        }

        rule {
          id      = "920440"
          enabled = true
          action  = "Block"
        }
      }
    }
  }
}
