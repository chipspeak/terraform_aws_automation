#----------------------------------------------------------------------------------------------------------------------------------------------------
#-DECLARATIONS/DEFINITIONS---------------------------------------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------------------------------------------------------------

# stating the provider and region
provider "aws" {
  region = local.region
}

# creating the default_tags variable for merging with resource specific tags
variable "default_tags" {
    # helpful suggestion from Kieron Garvey re merging lists
    default = {
        StudentName = "Patrick O Connor"
        StudentNumber = "20040412"
        Assignment = "DevOps Assignment 2"
        Terraform = "true"
        Environment = "dev"
    }
    type = map(string)
}

# creating the locals block for the region, image_id, pem file and user_data script
# script retrieves the instance id, instance type and availability zone and adds it to the about page of the web server
# monitoring script modified from labs and is now created in the user_data script in addition to the cron job
locals {
    region = "us-east-1"
    image_id = "your_ami_id"
    pem = "you_key_pair.pem"
    user_data = <<-EOF
            #!/bin/bash
            TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
            INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
            INSTANCE_TYPE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type)
            AVAILABILITY_ZONE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)
            sed -i "19i <br>\n<br>\nThis version of placemark is running on the following amazon linux ec2-instance: $INSTANCE_ID in the following availability zone: $AVAILABILITY_ZONE" /home/ec2-user/Web-Server/placemark/src/views/about-view.hbs
            EOF
}


#----------------------------------------------------------------------------------------------------------------------------------------------------
#-VPC------------------------------------------------------------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------------------------------------------------------------

# vpc creation
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "assignment2-vpc"
  cidr = "10.0.0.0/16"

  azs = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = merge(
    var.default_tags,
    {
      VPC-Name = "assignment2-vpc"
    }
  )
}


#----------------------------------------------------------------------------------------------------------------------------------------------------
#-BASTION--------------------------------------------------------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------------------------------------------------------------

# retrieving the latest amazon linux ami
data "aws_ami" "latest_amazon_linux" {
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*"]
  }

  filter {
    name   = "owner-alias"
    values = ["amazon"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}


# bastion host creation
module "ec2_instance" {
  source = "terraform-aws-modules/ec2-instance/aws"

  name = "bastion host"
  ami = data.aws_ami.latest_amazon_linux.id
  instance_type = "t2.nano"
  key_name = local.pem
  subnet_id = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  vpc_security_group_ids = [module.ssh_security_group.security_group_id, module.egress_security_group.security_group_id]
  tags = merge(
  var.default_tags,
    {
      Bastion-Name = "assignment2-bastion-host"
    }
  )
}


#----------------------------------------------------------------------------------------------------------------------------------------------------
#-SECURITY-GROUPS------------------------------------------------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------------------------------------------------------------

# egress security group creation
module "egress_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name               = "egress-sg"
  description        = "Allow all egress"
  vpc_id             = module.vpc.vpc_id
  egress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules       = ["all-all"]
  tags = merge(
    var.default_tags,
    {
      Security-Group-Name = "egress-sg"
    }
  )
}


# security group creation
module "web_server_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "web-server-sg"
  description = "Security group for web server"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules = ["http-80-tcp"]
  tags = merge(
    var.default_tags,
    {
      Security-Group-Name = "web-server-sg"
    }
  )
}


# specifying rules for security group to allow inbound traffic on port 3000 for use with health checks
resource "aws_security_group_rule" "allow_inbound_3000" {
  type              = "ingress"
  from_port         = 3000
  to_port           = 3000
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = module.web_server_sg.security_group_id
}


# using icanhazip to retrieve the ip of the machine running the terraform script
data "http" "local_ip" {
  url = "http://ipv4.icanhazip.com"
}


# security group creation for ssh into bastion from local machine, using the above data (chomp removes any /n in the return)
module "ssh_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "ssh-sg"
  description = "Security group to allow ssh into bastion host via ip address of local machine"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks      = ["${chomp(data.http.local_ip.response_body)}/32"]
  ingress_rules            = ["ssh-tcp"]
  tags = merge(
    var.default_tags,
    {
      Security-Group-Name = "ssh-into-bastion-sg"
    }
  )
}


# security group creation for bastion ssh to be used with auto scaler
module "ssh_bastion_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "bastion-sg"
  description = "Security group allowing bastion to ssh into web server instances"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks      = ["${module.ec2_instance.private_ip}/32"]
  ingress_rules            = ["ssh-tcp"]
  tags = merge(
    var.default_tags,
    {
      Security-Group-Name = "ssh-from-bastion-sg"
    }
  )
}


#----------------------------------------------------------------------------------------------------------------------------------------------------
#-LOAD-BALANCER--------------------------------------------------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------------------------------------------------------------

# load balancer creation
module "alb" {
	source  = "terraform-aws-modules/alb/aws"

	name               = "placemark-alb"
	load_balancer_type = "application"
	security_groups    = [module.web_server_sg.security_group_id, module.egress_security_group.security_group_id]
	subnets            = module.vpc.public_subnets
	enable_deletion_protection = false
	create_security_group = false
  tags = merge(
    var.default_tags,
    {
      Auto-Load-Balancer-Name = "assignment2-alb"
    }
  )
}


# target group creation
resource "aws_lb_target_group" "target_group_http" {
  name     = "placemark-tg"
  port     = 3000
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

	# health check
	health_check {
		path                = "/"
		protocol            = "HTTP"
		port                = "3000"
		healthy_threshold   = 3
		unhealthy_threshold = 3
		timeout             = 4
		interval            = 30    
		matcher             = "200-399"
	}
}


# listener rule creation
resource "aws_lb_listener" "load_balancer_http" {
  load_balancer_arn = module.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
	type             = "forward"
	target_group_arn = aws_lb_target_group.target_group_http.arn
  }
}


#----------------------------------------------------------------------------------------------------------------------------------------------------
#-AUTO-SCALING---------------------------------------------------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------------------------------------------------------------

# autoscaling group creation
module "asg" {
	source = "terraform-aws-modules/autoscaling/aws"

	name                 = "placemark-asg"
	vpc_zone_identifier  = module.vpc.private_subnets
	target_group_arns    = [aws_lb_target_group.target_group_http.arn]
	min_size             = 1
	max_size             = 3
	desired_capacity     = 1

    health_check_type = "ELB"
    health_check_grace_period = 30

	launch_template_name = "placemark-launch-template"
	launch_template_description = "Launch template for placemark instances"
	image_id = local.image_id
	instance_type = "t2.nano"
	key_name = local.pem
	security_groups = [module.web_server_sg.security_group_id, module.ssh_bastion_security_group.security_group_id, module.egress_security_group.security_group_id]
	enable_monitoring = true
  user_data = base64encode(local.user_data)
  tags = merge(
    var.default_tags,
    {
      Auto-Scaling-Group-Name = "assignment2-asg"
    }
  )
}


# scale up policy creation
resource "aws_autoscaling_policy" "scale_up_policy" {
	name = "scale-up-policy"
	autoscaling_group_name = module.asg.autoscaling_group_name
	adjustment_type = "ChangeInCapacity"
	scaling_adjustment = "1"
	cooldown = "60"
	policy_type = "SimpleScaling"
}


# scale down policy creation
resource "aws_autoscaling_policy" "scale_down_policy" {
	name = "scale-down-policy"
	autoscaling_group_name = module.asg.autoscaling_group_name
	adjustment_type = "ChangeInCapacity"
	scaling_adjustment = "-1"
	cooldown = "60"
	policy_type = "SimpleScaling"
}


#----------------------------------------------------------------------------------------------------------------------------------------------------
#-CLOUDWATCH-----------------------------------------------------------------------------------------------------------------------------------------
#----------------------------------------------------------------------------------------------------------------------------------------------------

# cloudwatch alarm creation for scaling up
resource "aws_cloudwatch_metric_alarm" "placemark_cpu_scale_up_alarm"{

  alarm_name          = "placemark-excessive-cpu-utilization-alarm"
  alarm_description   = "CPU overload of placemark instances"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 50
  period              = 60
  unit                = "Percent"

  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  dimensions = {
	AutoScalingGroupName = module.asg.autoscaling_group_name
  }
  actions_enabled = true
  alarm_actions   = [aws_autoscaling_policy.scale_up_policy.arn]
}


# cloudwatch alarm creation for scaling down
resource "aws_cloudwatch_metric_alarm" "placemark_cpu_scale_down_alarm"{

  alarm_name          = "placemark-low-cpu-utilization-alarm"
  alarm_description   = "CPU average has moved below threshold, shutting down extra instances"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 25
  period              = 60
  unit                = "Percent"

  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  statistic   = "Average"
  dimensions = {
	AutoScalingGroupName = module.asg.autoscaling_group_name
  }
  actions_enabled = true
  alarm_actions   = [aws_autoscaling_policy.scale_down_policy.arn]
}

