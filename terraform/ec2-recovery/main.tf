data "aws_iam_instance_profile" "reader" {
  name = "${var.ec2_role_name_prefix}-reader"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "recovery" {
  cidr_block           = "10.78.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "postgres-dr-recovery" }
}

resource "aws_subnet" "recovery" {
  vpc_id     = aws_vpc.recovery.id
  cidr_block = "10.78.1.0/24"
  tags       = { Name = "postgres-dr-recovery" }
}

resource "aws_internet_gateway" "recovery" {
  vpc_id = aws_vpc.recovery.id
  tags   = { Name = "postgres-dr-recovery" }
}

resource "aws_route_table" "recovery" {
  vpc_id = aws_vpc.recovery.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.recovery.id
  }
  tags = { Name = "postgres-dr-recovery" }
}

resource "aws_route_table_association" "recovery" {
  subnet_id      = aws_subnet.recovery.id
  route_table_id = aws_route_table.recovery.id
}

resource "aws_security_group" "recovery" {
  name_prefix = "postgres-dr-recovery-"
  description = "No inbound access; outbound package, container, SSM and S3 traffic."
  vpc_id      = aws_vpc.recovery.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "postgres-dr-recovery" }
}

# Only this temporary-host state manages the additional SSM attachment.
# Destroying it retains the reader role, instance profile, and S3 permissions.
resource "aws_iam_role_policy_attachment" "reader_ssm" {
  role       = data.aws_iam_instance_profile.reader.role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_instance" "recovery" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.recovery.id
  vpc_security_group_ids      = [aws_security_group.recovery.id]
  associate_public_ip_address = true
  iam_instance_profile        = data.aws_iam_instance_profile.reader.name
  user_data                   = file("${path.module}/user-data.sh")
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 16
    encrypted             = true
    delete_on_termination = true
  }

  credit_specification {
    cpu_credits = "standard"
  }

  tags = { Name = "postgres-dr-recovery" }
  depends_on = [
    aws_iam_role_policy_attachment.reader_ssm,
    aws_route_table_association.recovery,
  ]
}
