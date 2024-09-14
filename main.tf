terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
  required_version = ">= 0.13"
}

resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

output "private_key" {
  value = tls_private_key.ssh_key.private_key_pem
  sensitive=true
}

output "public_key" {
  value = tls_private_key.ssh_key.public_key_openssh
  sensitive=true
}

resource "local_file" "private_key" {
  content = "${tls_private_key.ssh_key.private_key_pem}"
  filename = "private_key"
}

resource null_resource "pr_key_chmod" {
  provisioner "local-exec" {
    command = "chmod 700 private_key"
  }

  depends_on = [local_file.private_key]
}

provider "yandex" {  
  zone = "ru-central1-a"
  max_retries = "3"
}

resource yandex_vpc_security_group vm_group_sg {
  network_id = "enpm3u225evb8b1al0u7" # default network
  folder_id = "b1g7bgigl09u0nngmfr6" # default folder

   egress {
    protocol       = "ANY"
    description    = "any"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol       = "TCP"
    description    = "ssh"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }

  ingress {
    protocol       = "TCP"
    description    = "squid"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 3128
  }

  ingress {
    protocol       = "TCP"
    description    = "redis"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 6379
  }

  ingress {
    protocol       = "TCP"
    description    = "ext-http"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

  ingress {
    protocol       = "TCP"
    description    = "ext-https"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 443
  }
}

resource "yandex_compute_disk" "boot_disks" {
    count = 4

    name = "boot-disk-${count.index + 1}"
    size = 20
    type = "network-hdd"
    zone = "ru-central1-a"
    image_id = "fd8gqkbp69nel2ibb5pr"  # Ubuntu 24.04 LTS
    folder_id = "b1g7bgigl09u0nngmfr6" # default folder
}

resource "yandex_vpc_address" "ip_address" {
    name = "white-ip"
    folder_id = "b1g7bgigl09u0nngmfr6" # default folder
    external_ipv4_address {
        zone_id = "ru-central1-a"
    }
}

resource "yandex_compute_instance" "nginx-vm" {
    platform_id = "standard-v1"
    zone = "ru-central1-a"
    folder_id = "b1g7bgigl09u0nngmfr6" # default folder

    resources {
        cores = 2
        memory = 2
    }

    boot_disk {
        disk_id = yandex_compute_disk.boot_disks[3].id
    }

    network_interface {
        index = 1
        subnet_id = "e9bik5sca0i62bn5v8ta"
        nat = true
        nat_ip_address = "${yandex_vpc_address.ip_address.external_ipv4_address[0].address}"
        security_group_ids = [yandex_vpc_security_group.vm_group_sg.id]
    }

    metadata = {
        ssh-keys = "vmuser:${tls_private_key.ssh_key.public_key_openssh}"
    }

    depends_on = [yandex_vpc_address.ip_address, yandex_compute_disk.boot_disks]
}

resource "yandex_compute_instance" "hw-vms" {
    count = 3
    platform_id = "standard-v1"
    zone = "ru-central1-a"
    folder_id = "b1g7bgigl09u0nngmfr6" # default folder

    resources {
        cores = 2
        memory = 2
    }

    boot_disk {
        disk_id = yandex_compute_disk.boot_disks[count.index].id
    }

    network_interface {
        index = 1
        subnet_id = "e9bik5sca0i62bn5v8ta" # default-ru-central1-a subnet
        security_group_ids = [yandex_vpc_security_group.vm_group_sg.id]
    }

    metadata = {
        ssh-keys = "vmuser:${tls_private_key.ssh_key.public_key_openssh}"
    }

    depends_on = [yandex_compute_disk.boot_disks]
}

resource "local_file" "palybook-temp" {
    content = templatefile(
        "playbook-template.yml",
        {
            nginx_vm_private_ip = yandex_compute_instance.nginx-vm.network_interface[0].ip_address
        }
    )
    filename = "playbook.yml"

    depends_on = [yandex_compute_instance.hw-vms]
}

resource "local_file" "apt-proxy" {
    content = templatefile(
        "01proxy-template",
        {
            nginx_vm_ip = yandex_compute_instance.nginx-vm.network_interface[0].ip_address
        }
    )
    filename = "01proxy"

    depends_on = [yandex_compute_instance.hw-vms]
}

resource "local_file" "pip-proxy" {
    content = templatefile(
        "pip-template.conf",
        {
            nginx_vm_private_ip = yandex_compute_instance.nginx-vm.network_interface[0].ip_address
        }
    )
    filename = "pip.conf"

    depends_on = [yandex_compute_instance.hw-vms]
}

resource "local_file" "hosts_cfg" {
    content = templatefile(
        "inv_template",
        {
            nginx_vm_ip = yandex_compute_instance.nginx-vm.network_interface[0].nat_ip_address
            redis_vm_ip = yandex_compute_instance.hw-vms[0].network_interface[0].ip_address
            uwsgi_vm_ip = yandex_compute_instance.hw-vms[1].network_interface[0].ip_address
            nginx_back_vm_ip = yandex_compute_instance.hw-vms[2].network_interface[0].ip_address
        }
    )
    filename = "inv"

    depends_on = [yandex_compute_instance.hw-vms]
}

resource "local_file" "flask_app" {
    content = templatefile(
        "uwsgi_back/app_template.py",
        {
            redis_vm_ip = yandex_compute_instance.hw-vms[0].network_interface[0].ip_address
        }
    )
    filename = "uwsgi_back/app.py"

    depends_on = [yandex_compute_instance.hw-vms]
}

resource "local_file" "nginx_conf" {
    content = templatefile(
        "nginx/nginx-template",
        {
            uwsgi_vm_ip = yandex_compute_instance.hw-vms[1].network_interface[0].ip_address
            nginx_back_vm_ip = yandex_compute_instance.hw-vms[2].network_interface[0].ip_address
        }
    )
    filename = "nginx/default"

    depends_on = [yandex_compute_instance.hw-vms]
}

resource null_resource "ansible_nginx" {
  provisioner "local-exec" {
    command = "ansible-playbook -T 300 -i inv playbook-nginx.yml --extra-vars=ansible_ssh_private_key_file=private_key"
  }

  depends_on = [local_file.hosts_cfg]
}

resource null_resource "ansible" {
  provisioner "local-exec" {
    command = "ansible-playbook -T 300 -i inv playbook.yml --extra-vars=ansible_ssh_private_key_file=private_key"
  }

  depends_on = [null_resource.ansible_nginx, local_file.hosts_cfg]
}
