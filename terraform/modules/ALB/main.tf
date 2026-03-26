
#The Load Balancer
resource "aws_lb" "app_lb" {
  name               = "app-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_security_group]
  subnets            = var.alb_subnet_ids

  #enable_deletion_protection = true

  tags = {
    Environment = "production"
  }
}

# the target group for the load balancer
resource "aws_lb_target_group" "app_lb_tg" {
  name     = "tf-app-lb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path     = "/health"
    port     = 80
    protocol = "HTTP"
  }
}

# attach the ec2 instances to the target group
resource "aws_lb_target_group_attachment" "tg_attachment" {
  count             = length(var.target_instance_ids)
  target_group_arn = aws_lb_target_group.app_lb_tg.arn
  target_id        = var.target_instance_ids[count.index]
  port             = 80
}


# Load Balancer Listener
resource "aws_lb_listener" "lb_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_lb_tg.arn
  }
}

