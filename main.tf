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
  }
}

provider "aws" {
  region = "us-east-1"
}

# Generate a strong, secure password for your MoreLogin proxy authentication
resource "random_password" "proxy_pass" {
  length  = 16
  special = false
}

resource "aws_vpc" "texas_proxy_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "morelogin-texas-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.texas_proxy_vpc.id
}

resource "aws_subnet" "texas_local_zone_subnet" {
  vpc_id            = aws_vpc.texas_proxy_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1-dfw-1a" # Dallas Local Zone
  tags              = { Name = "morelogin-texas-subnet" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.texas_proxy_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.texas_local_zone_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# Security Group: Open ONLY to SOCKS5 port 1080
resource "aws_security_group" "proxy_sg" {
  name   = "morelogin-proxy-sg"
  vpc_id = aws_vpc.texas_proxy_vpc.id

  ingress {
    from_port   = 1080
    to_port     = 1080
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

resource "aws_eip" "vpn_eip" {
  domain = "vpc"
}

resource "aws_eip_association" "eip_assoc" {
  instance_id   = aws_instance.proxy_server.id
  allocation_id = aws_eip.vpn_eip.id
}

# EC2 Instance installing Dante SOCKS5 server
resource "aws_instance" "proxy_server" {
  ami                    = "ami-0e2c8caa4b6378d8c" # Ubuntu 24.04 LTS HVM in us-east-1
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.texas_local_zone_subnet.id
  vpc_security_group_ids = [aws_security_group.proxy_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y dante-server

              # Create a dedicated system user for proxy authentication
              useradd -m -s /usr/sbin/nologin texasuser
              echo "texasuser:${random_password.proxy_pass.result}" | chpasswd

              # Write the Dante server configuration file
              cat <<EOT > /etc/dantearg.conf
              logoutput: syslog
              internal: 0.0.0.0 port = 1080
              external: eth0
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

              mv /etc/dantearg.conf /etc/danted.conf
              systemctl restart danted
              systemctl enable danted
              EOF

  tags = { Name = "texas-socks5-morelogin" }
}

# Outputs needed to plug straight into MoreLogin
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
