resource "aws_ebs_volume" "data" {
  availability_zone = var.az
  size              = 20
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "alertstack-aws-data"
  }
}

resource "aws_volume_attachment" "data" {
  device_name  = "/dev/xvdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.alertstack.id
  force_detach = false
}

output "data_volume_id" {
  value = aws_ebs_volume.data.id
}
