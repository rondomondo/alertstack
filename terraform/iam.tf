resource "aws_iam_role" "ec2_instance" {
  name = "alertstack-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "ec2_s3_read" {
  name = "alertstack-ec2-s3-read"
  role = aws_iam_role.ec2_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.deploy.arn,
        "${aws_s3_bucket.deploy.arn}/*",
      ]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_instance" {
  name = "alertstack-ec2-profile"
  role = aws_iam_role.ec2_instance.name
}
