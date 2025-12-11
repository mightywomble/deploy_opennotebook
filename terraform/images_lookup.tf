# Temporary helper to list available VM images from the Cudo provider
# Safe to apply; it only queries a data source and outputs the results.

data "cudo_vm_images" "available" {}

output "available_images" {
  description = "List of available images with id, name, description, size_gib"
  value       = data.cudo_vm_images.available.images
}
