variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "spaincentral"
}

variable "vm_size" {
  type    = string
  default = "Standard_B2ats_v2"
}

variable "admin_username" {
  type    = string
  default = "b-draoui"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "admin_public_key" {
  type = string
}

variable "image_version" {
  type    = string
  default = "24.04.202611170"
}

variable "alert_email" {
  type = string
}
