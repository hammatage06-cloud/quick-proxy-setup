terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "random_password" "proxy_pass" {
  length  = 16
  special = false
}

resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "generated_key" {
  key_name   = "texas-proxy-key"
  public_key = tls_private_key.ssh_key.public_key_openssh
}

resource "local_sensitive_file" "pem_file" {
  content         = tls_private_key.ssh_key.private_key_pem
  filename        = "${path.module}/texas-proxy-key.pem"
  file_permission = "0600"
}

# 1. Create the VPC
resource "aws_vpc" "texas_proxy_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "texas-proxy-vpc" }
}

# 2. Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.texas_proxy_vpc.id
  tags   = { Name = "texas-proxy-igw" }
}

# 3. Subnet bound to Dallas Local Zone us-east-1-dfw-2a
resource "aws_subnet" "texas_local_zone_subnet" {
  vpc_id            = aws_vpc.texas_proxy_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1-dfw-2a"
  tags              = { Name = "texas-dallas-subnet" }
}

# 4. Explicit Public Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.texas_proxy_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "texas-proxy-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.texas_local_zone_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 5. Security Group
resource "aws_security_group" "proxy_sg" {
  name        = "morelogin-proxy-sg"
  description = "Open ports for SOCKS5 and SSH"
  vpc_id      = aws_vpc.texas_proxy_vpc.id

  ingress {
    from_port   = 1080
    to_port     = 1080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# NEW FIX: Explicit Dedicated Network Interface inside the Subnet
resource "aws_network_interface" "proxy_nic" {
  subnet_id       = aws_subnet.texas_local_zone_subnet.id
  security_groups = [aws_security_group.proxy_sg.id]
  tags            = { Name = "texas-proxy-nic" }
}

# 6. Anchored Dallas Elastic IP attached explicitly to the ENI
resource "aws_eip" "vpn_eip" {
  domain               = "vpc"
  network_border_group = "us-east-1-dfw-2"
}

resource "aws_eip_association" "eip_assoc" {
  network_interface_id = aws_network_interface.proxy_nic.id
  allocation_id        = aws_eip.vpn_eip.id
}

# 7. EC2 Instance consuming the explicit network interface configuration
resource "aws_instance" "proxy_server" {
  ami           = "ami-0e2c8caa4b6378d8c" # Ubuntu 24.04 LTS
  instance_type = "m6i.large"
  key_name      = aws_key_pair.generated_key.key_name

  network_interface {
    network_interface_id = aws_network_interface.proxy_nic.id
    device_index         = 0
  }

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y dante-server

              # Create application proxy user account 
              useradd -m texasuser
              echo "texasuser:${random_password.proxy_pass.result}" | chpasswd

              # Configure Dante Server Daemon
              cat <<EOT > /etc/danted.conf
              logoutput: syslog
              internal: 0.0.0.0 port = 1080
              external: ens5
              socksmethod: username
              clientmethod: none

              client pass {
                  from: 0.0.0.0/0 to: 0.0.0.0/0
                  log: connect error
              }

              socks pass {
                  from: 0.0.0.0/0 to: 0.0.0.0/0
                  command: bind connect udpassoc
                  log: connect disconnect error
                  socksmethod: username
              }
              EOT

              chown root:shadow /etc/danted.conf
              chmod 640 /etc/danted.conf
              systemctl restart danted
              systemctl enable danted
              EOF

  tags = { Name = "texas-socks5-morelogin" }
}

output "morelogin_proxy_details" {
  value = {
    proxy_type = "SOCKS5"
    ip_address = aws_eip.vpn_eip.public_ip
    port       = 1080
    username   = "texasuser"
    password   = random_password.proxy_pass.result
  }
  sensitive = true
}
