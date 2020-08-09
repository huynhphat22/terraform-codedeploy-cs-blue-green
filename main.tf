provider "aws" {
  version = "~> 3.0"
  region  = "us-east-1"
}

data "aws_caller_identity" "current" {}

locals {
  image_id = "${data.aws_caller_identity.current.account_id}.dkr.ecr.us-east-1.amazonaws.com/test-blue-green:latest"
}

variable "image_id" {
  type = string
  default = "551298249230.dkr.ecr.us-east-1.amazonaws.com/test-blue-green:latest"
}

data "aws_ami" "ami-amazon-2-linux"{
    most_recent = true
    filter {
        name = "name"
        values = ["amzn2-ami-ecs-hvm-2.0.20200805-x86_64-ebs"]
    }
    owners = ["591542846629"]
}

resource "aws_iam_instance_profile" "ec2-container-instance-profile" {
  name = "ec2-container-instance-profile"
  role = aws_iam_role.ec2-container-service-ecs.name
}

resource "aws_key_pair" "key-pair" {
  key_name   = "key-pair"
  public_key = file("key-pair.pub")
}

resource "aws_launch_configuration" "as_conf" {
  name_prefix          = "web-config-"
  image_id      = data.aws_ami.ami-amazon-2-linux.id
  instance_type = "t2.micro"
  key_name = aws_key_pair.key-pair.id
  iam_instance_profile = aws_iam_instance_profile.ec2-container-instance-profile.name
  security_groups = [aws_security_group.allow-http.id]
  lifecycle {
    create_before_destroy = true
  }
  user_data = <<EOF
    #!/bin/bash
    echo ECS_DATADIR=/data >> /etc/ecs/ecs.config
    echo ECS_ENABLE_TASK_IAM_ROLE=true >> /etc/ecs/ecs.config
    echo ECS_ENABLE_TASK_IAM_ROLE_NETWORK_HOST=true >> /etc/ecs/ecs.config
    echo ECS_LOGFILE=/log/ecs-agent.log >> /etc/ecs/ecs.config
    echo ECS_AVAILABLE_LOGGING_DRIVERS=["json-file","awslogs"] >> /etc/ecs/ecs.config
    echo ECS_LOGLEVEL=info >> /etc/ecs/ecs.config
    echo ECS_CLUSTER=blue-green-cluster >> /etc/ecs/ecs.config
EOF
}

resource "aws_default_subnet" "default-subnet-us-east-1a" {
  availability_zone = "us-east-1a"
}

resource "aws_default_subnet" "default-subnet-us-east-1b" {
  availability_zone = "us-east-1b"
}

resource "aws_iam_role" "ec2-container-service-ecs" {
  name = "ec2-container-service-ecs"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
  EOF
}

resource "aws_iam_role_policy" "ec2-container-service-ecs-policy"{
  name = "ec2-container-service-ecs-policy"
  role = aws_iam_role.ec2-container-service-ecs.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": "*",
      "Action": [
          "ec2:DescribeTags",
          "ecs:CreateCluster",
          "ecs:DeregisterContainerInstance",
          "ecs:DiscoverPollEndpoint",
          "ecs:Poll",
          "ecs:RegisterContainerInstance",
          "ecs:StartTelemetrySession",
          "ecs:UpdateContainerInstancesState",
          "ecs:Submit*",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
      ]
    }
  ]
}
  EOF
}

resource "aws_autoscaling_group" "blue-green-asg" {
  name_prefix                      = "blue-green-asg-"
  max_size                  = 2
  min_size                  = 1
  health_check_grace_period = 300
  health_check_type         = "ELB"
  desired_capacity          = 2
  launch_configuration      = aws_launch_configuration.as_conf.name
  vpc_zone_identifier       = [aws_default_subnet.default-subnet-us-east-1a.id, aws_default_subnet.default-subnet-us-east-1b.id]

  lifecycle {
    create_before_destroy = true
  }
  timeouts {
    delete = "15m"
  }

  tag {
    key                 = "AmazonECSManaged"
    value = "true"
    propagate_at_launch = true
  }
}

resource "aws_security_group" "allow-http" {
  name        = "allow-http"
  description = "Allow TLS inbound traffic"
  vpc_id      = aws_default_vpc.default.id

  ingress {
    description = "HTTP from everywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH from everywhere"
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

resource "aws_lb" "blue-green-lb" {
  name               = "blue-green-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow-http.id]
  subnets            = [aws_default_subnet.default-subnet-us-east-1a.id, aws_default_subnet.default-subnet-us-east-1b.id]
}

data "aws_iam_policy" "codedeploy-iam-role-policy" {
  arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

resource "aws_iam_role_policy" "codedeploy-iam-role-policy"{
  name = "codedeploy-iam-role"
  role = aws_iam_role.codedeploy-iam-role.id
  policy = data.aws_iam_policy.codedeploy-iam-role-policy.policy
}

resource "aws_iam_role" "codedeploy-iam-role"{
  name = "codedeploy-iam-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "codedeploy.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_default_vpc" "default" {
  tags = {
    Name = "Default VPC"
  }
}

resource "aws_lb_target_group" "blue" {
  name     = "blue-lb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_default_vpc.default.id
}

resource "aws_lb_target_group" "green" {
  name     = "green-lb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_default_vpc.default.id
}

resource "aws_lb_listener" "alb-listener" {
  load_balancer_arn = aws_lb.blue-green-lb.arn
  port              = "80"
  protocol          = "HTTP"

  lifecycle{
    ignore_changes = [default_action]
  }

  default_action {
    type             = "forward"
    forward {
      target_group {
        arn = aws_lb_target_group.blue.arn
        weight = 1
      }
      target_group {
        arn = aws_lb_target_group.green.arn
        weight = 0
      }
    }
  }
}

# Main Forward action
resource "aws_lb_listener_rule" "main" {
  listener_arn = aws_lb_listener.alb-listener.arn
  priority     = 1

  lifecycle{
    ignore_changes = [action]
  }
  
  action {
    type             = "forward"
    forward {
      target_group {
        arn = aws_lb_target_group.blue.arn
        weight = 1
      }
      target_group {
        arn = aws_lb_target_group.green.arn
        weight = 0
      }
      stickiness {
        duration = 1
        enabled = false
      }
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

resource "aws_ecs_cluster" "blue-green-cluster" {
  name = "blue-green-cluster"
}

resource "aws_ecs_task_definition" "blue-green-td" {
  family                = "blue-green-td"
  container_definitions = templatefile("blue-green-cd.json", {
      image_id = "${local.image_id}"
  })

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:ecs.availability-zone in [us-east-1a, us-east-1b]"
  }
}

resource "aws_ecs_service" "blue-green-service" {
  name            = "blue-green-service"
  cluster         = aws_ecs_cluster.blue-green-cluster.id
  task_definition = aws_ecs_task_definition.blue-green-td.arn
  desired_count   = 1
  deployment_controller {
    type = "CODE_DEPLOY"
  }

  lifecycle {
    ignore_changes = [load_balancer, task_definition]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = "blue-green-cd"
    container_port   = 80
  }

  launch_type = "EC2"
}

resource "aws_codedeploy_app" "test-blue-green-app" {
  compute_platform = "ECS"
  name = "test-blue-green-app"
}

resource "aws_codedeploy_deployment_group" "test-blue-green-deployment-group" {
  app_name               = aws_codedeploy_app.test-blue-green-app.name
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  deployment_group_name  = "test-blue-green-deployment-group"
  service_role_arn       = aws_iam_role.codedeploy-iam-role.arn

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 1440
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.blue-green-cluster.name
    service_name = aws_ecs_service.blue-green-service.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.alb-listener.arn]
      }

      target_group {
        name = aws_lb_target_group.blue.name
      }

      target_group {
        name = aws_lb_target_group.green.name
      }
    }
  }
}

resource "aws_s3_bucket" "app-deployment-spec" {
  bucket = "codedeploy-spec-${data.aws_caller_identity.current.account_id}"
  acl = "public-read"
}

resource "aws_s3_bucket_object" "appspec" {
  bucket = aws_s3_bucket.app-deployment-spec.id
  key = "appspec.yml"
  content = templatefile("appspec.yml", {
    task-def-arn = aws_ecs_task_definition.blue-green-td.arn
    container-name = "blue-green-cd"
  })
}

output "application-url" {
  value = "http://${aws_lb.blue-green-lb.dns_name}/"
}

output "s3-appspec-path" {
  value = "s3://${aws_s3_bucket.app-deployment-spec.id}/${aws_s3_bucket_object.appspec.id}"
}
