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

  tags = {
    Terraform = "true"
    Environment = "dev"
  }
}


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

  name = "bastion"
  ami = data.aws_ami.latest_amazon_linux.id
  instance_type = "t2.nano"
  key_name = local.pem
  subnet_id = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  vpc_security_group_ids = [module.ssh_security_group.security_group_id, module.egress_security_group.security_group_id]
}


# egress security group creation
module "egress_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name               = "egress-sg"
  description        = "Allow all egress"
  vpc_id             = module.vpc.vpc_id
  egress_cidr_blocks = ["0.0.0.0/0"]
  egress_rules       = ["all-all"]
}


# security group creation
module "web_server_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "web-server-sg"
  description = "Security group for web server"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules = ["http-80-tcp"]
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


# security group creation for ssh into bastion from anywhere
module "ssh_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "ssh-sg"
  description = "Security group for bastion host"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks      = ["0.0.0.0/0"]
  ingress_rules            = ["ssh-tcp"]
}


# security group creation for bastion ssh to be used with auto scaler
module "ssh_bastion_security_group" {
  source = "terraform-aws-modules/security-group/aws"

  name        = "bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks      = ["${module.ec2_instance.private_ip}/32"]
  ingress_rules            = ["ssh-tcp"]
}


# load balancer creation
module "alb" {
	source  = "terraform-aws-modules/alb/aws"

	name               = "placemark-alb"
	load_balancer_type = "application"
	security_groups    = [module.web_server_sg.security_group_id, module.egress_security_group.security_group_id]
	subnets            = module.vpc.public_subnets
	enable_deletion_protection = false
	create_security_group = false
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

