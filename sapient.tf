provider "aws" {
  region = "us-east-1"
}

terraform {
    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = "~> 3.0"  # Adjust the version as needed
      }
    }
  }

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_subnet" "subnet_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "subnet_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.subnet_a.id
  route_table_id = aws_route_table.main.id
}


resource "aws_security_group" "alb_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
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

# Security Group for Instances
resource "aws_security_group" "web_sg_instance" {
  vpc_id = aws_vpc.main.id

  # Allow traffic from the ALB
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }  

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "role" {
  name = "webserver-role"

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

resource "aws_iam_policy" "policy" {
  name        = "webserver-session-manager-policy"
  description = "session-manager-policy"

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ssm:DescribeAssociation",
                "ssm:GetDeployablePatchSnapshotForInstance",
                "ssm:GetDocument",
                "ssm:DescribeDocument",
                "ssm:GetManifest",
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:ListAssociations",
                "ssm:ListInstanceAssociations",
                "ssm:PutInventory",
                "ssm:PutComplianceItems",
                "ssm:PutConfigurePackageResult",
                "ssm:UpdateAssociationStatus",
                "ssm:UpdateInstanceAssociationStatus",
                "ssm:UpdateInstanceInformation"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ssmmessages:CreateControlChannel",
                "ssmmessages:CreateDataChannel",
                "ssmmessages:OpenControlChannel",
                "ssmmessages:OpenDataChannel"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "ec2messages:AcknowledgeMessage",
                "ec2messages:DeleteMessage",
                "ec2messages:FailMessage",
                "ec2messages:GetEndpoint",
                "ec2messages:GetMessages",
                "ec2messages:SendReply"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "test-attach" {
  role       = aws_iam_role.role.name
  policy_arn = aws_iam_policy.policy.arn
}

resource "aws_iam_instance_profile" "launch_template_profile_role" {
  name = "web-server-iam"
  role = aws_iam_role.role.name
}

# Launch Template
resource "aws_launch_template" "web" {
  name_prefix   = "web-"
  image_id       = "ami-02c21308fed24a8ab"  # Replace with a valid AMI ID
  instance_type  = "t2.micro"
  key_name        = "newkey"
  user_data = base64encode(<<-EOF
                #!/bin/bash
                sudo yum update -y
                sudo yum install httpd -y
                sudo systemctl start httpd
                sudo systemctl enable httpd
                sudo firewall-cmd --permanent --add-service=http
                sudo firewall-cmd --reload
                EOF
  )              
  network_interfaces {
    associate_public_ip_address = true
    security_groups = [aws_security_group.web_sg_instance.id]
    subnet_id = aws_subnet.subnet_a.id
  }
  iam_instance_profile {
    name = aws_iam_instance_profile.launch_template_profile_role.name
  }  
}

# Auto Scaling Group
resource "aws_autoscaling_group" "web_asg" {
  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
  min_size             = 1
  max_size             = 3
  vpc_zone_identifier  = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]
  health_check_type    = "EC2"
  wait_for_capacity_timeout = "0"
  
  tag {
    key                 = "Name"
    value               = "web-server"
    propagate_at_launch = true
  }
}

# Auto Scaling Policies
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "scale-out"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "scale-in"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  autoscaling_group_name = aws_autoscaling_group.web_asg.name
}
#########################################################
# resource "aws_security_group" "web_sg_instance_lb" {
#   vpc_id = aws_vpc.main.id

#   ingress {
#     from_port   = 80
#     to_port     = 80
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }

#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
# }

# Application Load Balancer
resource "aws_lb" "web_alb" {
  name               = "web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.subnet_a.id, aws_subnet.subnet_b.id]

  enable_deletion_protection = false
  idle_timeout               = 400
  enable_http2               = true
  drop_invalid_header_fields = true
}

# ALB Listener
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }  
}

# ALB Target Group
resource "aws_lb_target_group" "web_tg" {
  name     = "web-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Auto Scaling Group to ALB Attachment
resource "aws_autoscaling_attachment" "asg_alb_attachment" {
  autoscaling_group_name = aws_autoscaling_group.web_asg.id
  alb_target_group_arn   = aws_lb_target_group.web_tg.arn
}

############################# USER ADD ##########################
############################# USER ADD ##########################
resource "aws_iam_user" "web_server_user" {
  name = "webserver"
}

# resource "aws_iam_user_login_profile" "web_server_user_profile" {
#   user    = aws_iam_user.web_server_user.name
#   #password = "Welcome@1234"  # Set a strong password
#   password_reset_required = true  # Force the user to reset the password on first login
# }

# resource "aws_iam_user_login_profile" "console_access_profile" {
#   user                  = "test-user"  # Replace with the name of your existing IAM user
#   password_length       = 20
#   pgp_key = ""
#   password_reset_required = true
# }

resource "aws_iam_policy" "web_server_restart_policy" {
  name        = "web_server_restart_policy"
  description = "Policy to allow restarting the web server"
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "ec2:DescribeInstances"
            ],
            "Effect": "Allow",
            "Resource": "*"
        },
        {
            "Action": [
                "ec2:RebootInstances"
            ],
            "Effect": "Allow",
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "ec2:ResourceTag/Name": "web-server"
                }
            }
        }
    ]
})
}

resource "aws_iam_user_policy_attachment" "web_server_policy_attachment" {
  policy_arn = aws_iam_policy.web_server_restart_policy.arn
  user      = aws_iam_user.web_server_user.name
}
