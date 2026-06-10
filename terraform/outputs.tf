output "account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "caller_arn" {
  description = "ARN of the caller identity used during apply"
  value       = data.aws_caller_identity.current.arn
}

output "alertstack_aws_public_ip" {
  description = "Public Elastic IP of the EC2 instance"
  value       = aws_eip.alertstack.public_ip
}

output "alertstack_aws_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.alertstack.id
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/alertstack-ec2.pem ubuntu@${aws_eip.alertstack.public_ip}"
}

output "deploy_bucket" {
  description = "S3 deploy bucket name"
  value       = aws_s3_bucket.deploy.bucket
}

