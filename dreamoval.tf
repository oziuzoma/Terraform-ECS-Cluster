# Configure the AWS Provider
provider "aws" {
  region = "us-east-2"
  access_key = "" 
  secret_key = ""
}

# 1.Create Vpc
resource "aws_vpc" "ozivpc" {
  cidr_block = "10.10.0.0/16"

    tags = {
    Name = "OziVPC"
  }

}

# 2.Create Internet Gateway
resource "aws_internet_gateway" "ozigw" {
  vpc_id = aws_vpc.ozivpc.id

}
# 3.Create Custom Route Table

resource "aws_route_table" "ozipublicRT" {
  vpc_id = aws_vpc.ozivpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.ozigw.id
  }  
}
# 4.Create a subnet
resource "aws_subnet" "pubsubnet" {
  vpc_id     = aws_vpc.ozivpc.id
  cidr_block = "10.10.1.0/24"
  availability_zone = "us-east-2a"
  }
resource "aws_subnet" "pubsubnet2" {
  vpc_id     = aws_vpc.ozivpc.id
  cidr_block = "10.10.2.0/24"
  availability_zone = "us-east-2b"
  }

# 5.Associate Subnet with Route Table

resource "aws_route_table_association" "associate" {
  subnet_id      = aws_subnet.pubsubnet.id
  route_table_id = aws_route_table.ozipublicRT.id
}
resource "aws_route_table_association" "associate2" {
  subnet_id      = aws_subnet.pubsubnet2.id
  route_table_id = aws_route_table.ozipublicRT.id
}
# 6.Create Security Group to allow ports

resource "aws_security_group" "allow_web" {
  name        = "allow_web_traffic"
  description = "Allow Web inbound traffic"
  vpc_id      = aws_vpc.ozivpc.id

  ingress {
    description      = "SSH from VPC"
    from_port        = 22
    to_port          = 22
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

ingress {
    description      = "HTTP from VPC"
    from_port        = 80
    to_port          = 80
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }

  ingress {
    description      = "HTTPS from VPC"
    from_port        = 443
    to_port          = 443
    protocol         = "tcp"
    cidr_blocks      = ["0.0.0.0/0"]
  }
  egress {
   protocol         = "-1"
   from_port        = 0
   to_port          = 0
   cidr_blocks      = ["0.0.0.0/0"]
  }
}

#Creating the ECS Cluster
resource "aws_ecs_cluster" "clusterozi" {
  name = "fargatecluster"
}


#Target group for ALB
resource "aws_alb_target_group" "TG" {
  name        = "TG"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.ozivpc.id
  target_type = "ip"
 
  health_check {
   healthy_threshold   = "3"
   interval            = "30"
   protocol            = "HTTP"
   matcher             = "200"
   timeout             = "3"
   path                = "/"
   unhealthy_threshold = "2"
  }
}

#Loadbalancer
resource "aws_alb" "alb" {
  name               = "ECSALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.allow_web.id]
  subnets            = [aws_subnet.pubsubnet.id,aws_subnet.pubsubnet2.id]
 
  enable_deletion_protection = false
  tags = {
    Name = "ECSALB"
  }
}


#ALB HTTP Listener
resource "aws_alb_listener" "http" {
  load_balancer_arn = aws_alb.alb.id
  port              = 80
  protocol          = "HTTP"
 
  default_action {
   target_group_arn = aws_alb_target_group.TG.id
   type = "forward"
  }
}

#Setting desired capacity for autoscaling
resource "aws_appautoscaling_target" "target" {
  max_capacity       = 4
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.clusterozi.name}/${aws_ecs_service.service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

#Configuring a CPU target tracking policy for scaling

resource "aws_appautoscaling_policy" "cpu_policy" {
  name               = "cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.target.resource_id
  scalable_dimension = aws_appautoscaling_target.target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.target.service_namespace
 
  target_tracking_scaling_policy_configuration {
   predefined_metric_specification {
     predefined_metric_type = "ECSServiceAverageCPUUtilization"
   }
 
   target_value       = 80
  }
  depends_on = [aws_appautoscaling_target.target]
}


resource "aws_ecs_task_definition" "taskozi" {
  family = "service"
  requires_compatibilities = ["FARGATE"]
  network_mode = "awsvpc"
  cpu       = 256
  memory    = 512
  container_definitions = jsonencode([
    {
      name      = "wordpressimage"
      image     = "bitnami/wordpress:latest"
      essential = true
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }
      ]
    }
    
  ])
  
}

resource "aws_ecs_service" "service" {
  name            = "service"
  cluster         = aws_ecs_cluster.clusterozi.id
  task_definition = aws_ecs_task_definition.taskozi.arn
  desired_count                      = 1
  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200
  launch_type                        = "FARGATE"
  scheduling_strategy                = "REPLICA"


  load_balancer {
    target_group_arn = aws_alb_target_group.TG.arn
    container_name   = "wordpressimage"
    container_port   = 80
  }
  network_configuration {
   security_groups  = [aws_security_group.allow_web.id]
   subnets          = [aws_subnet.pubsubnet.id,aws_subnet.pubsubnet2.id]
   assign_public_ip = true
 } 
 depends_on = [aws_alb_listener.http]
}



