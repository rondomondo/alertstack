resource "aws_security_group" "alertstack" {
  name        = "alertstack-ec2-secgroup"
  description = "Allow SSH, HTTP, HTTPS, and Envoy ports inbound; all outbound"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Envoy HTTP"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Envoy HTTPS"
    from_port   = 8443
    to_port     = 8443
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

resource "aws_instance" "alertstack" {
  ami                    = var.ami
  instance_type          = "t3.large"

  instance_market_options {
    market_type = "spot"

    spot_options {
      max_price                      = "0.04"
      spot_instance_type             = "persistent"
      instance_interruption_behavior = "stop"
    }
  }

  subnet_id              = var.subnet_id
  availability_zone      = var.az
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.alertstack.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_instance.name

  user_data = templatefile("${path.module}/user-data.sh.tpl", {
    region        = var.region
    deploy_bucket = var.deploy_bucket
  })

  user_data_replace_on_change = false

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  depends_on = [null_resource.upload_redeploy_script]

  tags = {
    Name = "alertstack"
  }
}

resource "aws_eip" "alertstack" {
  instance = aws_instance.alertstack.id
  domain   = "vpc"

  tags = {
    Name = "alertstack-eip"
  }
}
