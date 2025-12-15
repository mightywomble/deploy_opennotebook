# Primary VM (opennotebook)
vm_id          = "opennotebookserver"
project_id     = "service-test"
boot_disk_size = "250"
vcpus          = 2
memory_gib     = 4
data_center_id = "gb-bournemouth-1"
ssh_key_source = "project"
image_id       = "ubuntu-2404"

# Web VM (opennotebookweb)
# If you omit vcpus_web/memory_gib_web/boot_disk_size_web, they inherit from primary
vm_id_web = "opennotebookweb"
# vcpus_web = 2
# memory_gib_web = 4
# boot_disk_size_web = "50"
