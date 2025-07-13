provider "aws" {
  region  = "ap-northeast-1"
  profile = "exercise-user"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["self", "amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  exercise_tags = {
    Project     = "exercise"
    Environment = "dev"
    Owner       = "exercise-user"
  }

  http_port    = 80
  any_port     = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips      = ["0.0.0.0/0"]
}

resource "aws_launch_template" "example" {
  image_id               = "ami-01ead1eca9a200e01"
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.instance.id]

  # cloudwatchのために追加
  # iam_instance_profile {
  #   name = aws_iam_instance_profile.cloudwatch_profile.name
  # }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    server_port = var.server_port
    db_address  = data.terraform_remote_state.db.outputs.address
    db_port     = data.terraform_remote_state.db.outputs.port
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      local.exercise_tags,
      { Name = "exercise-instance" }
    )
  }

  lifecycle {
    create_before_destroy = true
  }

  # 起動順序制御のために追加
  depends_on = [
    aws_security_group.instance,
    data.aws_subnets.default,
    aws_lb_target_group.asg
  ]
}

resource "aws_autoscaling_group" "example" {
  vpc_zone_identifier = data.aws_subnets.default.ids

  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"

  launch_template {
    id      = aws_launch_template.example.id
    version = "$Latest"
  }

  min_size = var.min_size
  max_size = var.max_size

  tag {
    key                 = "Name"
    value               = var.cluster_name
    propagate_at_launch = true
  }

  # 起動順序の制御のために追加
  depends_on = [aws_launch_template.example]
}

resource "aws_security_group" "instance" {
  name = "${ver.cluster_name}-instance"

  tags = merge(
    local.exercise_tags,
    { Name = format("%s-sg", var.instance_security_group_name) }
  )
}

resource "aws_security_group_rule" "allow_server_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.instance.id

  from_port   = var.server_port
  to_port     = var.server_port
  protocol    = local.tcp_protocol
  cidr_blocks = local.all_ips
}

resource "aws_security_group_rule" "allow_server_ssh_inboud" {
  type              = "ingress"
  security_group_id = aws_security_group.instance.id

  from_port   = var.ssh_port
  to_port     = var.ssh_port
  protocol    = local.tcp_protocol
  cidr_blocks = local.all_ips
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_lb" "example" {
  name               = var.cluster_name
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]

  depends_on = [
    aws_security_group.alb,
    data.aws_subnets.default
  ]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = local.http_port
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_lb_target_group" "asg" {
  name     = var.cluster_name
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }

  # 起動順序制御のために追加
  depends_on = [
    aws_lb_target_group.asg,
    aws_lb_listener.http
  ]
}

resource "aws_security_group" "alb" {
  name = "${var.cluster_name}-alb"
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id

  from_port   = local.http_port
  to_port     = local.http_port
  protocol    = local.tcp_protocol
  cidr_blocks = local.all_ips
}

resource "aws_security_group_rule" "allow_http_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id

  from_port   = local.any_port
  to_port     = local.any_port
  protocol    = local.any_protocol
  cidr_blocks = local.all_ips
}

data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    bucket  = "terraform-up-and-running-state-exercise"
    key     = "stage/data-stores/mysql/terraform.tfstate"
    region  = "ap-northeast-1"
    profile = "exercise-user"
  }
}


# # CloudWatchLogsを追加
# resource "aws_iam_role" "cloudwatch_role" {
#   name = "ec2-cloudwatch-role"

#   assume_role_policy = jsonencode({
#     Version = "2012-10-17",
#     Statement = [{
#       Action = "sts:AssumeRole",
#       Principal = {
#         Service = "ec2.amazonaws.com"
#       },
#       Effect = "Allow",
#     }]
#   })
# }

# resource "aws_iam_role_policy_attachment" "cloudwatch_attach" {
#   role       = aws_iam_role.cloudwatch_role.name
#   policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
# }

# # instance profile
# resource "aws_iam_instance_profile" "cloudwatch_profile" {
#   name = "ec2-cloudwatch_profile"
#   role = aws_iam_role.cloudwatch_role.name
# }

