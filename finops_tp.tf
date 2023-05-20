###### NETWORK ######
resource "aws_vpc" "request-vpc" {
  cidr_block                      = "10.0.0.0/16"
  enable_dns_hostnames            = true
  enable_dns_support              = true
}

resource "aws_internet_gateway" "request-internet-gateway" {
}

resource "aws_internet_gateway_attachment" "request-attach-ig" {
  vpc_id                          = aws_vpc.request-vpc.id
  internet_gateway_id             = aws_internet_gateway.request-internet-gateway.id
}

# public subnet AZ1
resource "aws_subnet" "request-public-sn-subnet" {
  vpc_id                          = aws_vpc.request-vpc.id
  cidr_block                      = "10.0.1.0/24"
  availability_zone               = "eu-west-3a"
  tags = {
    Name                          = "request-public-sn-subnet"
  }
}

resource "aws_eip" "request-nat-eip-subnet" {
  vpc                             = true
}

resource "aws_nat_gateway" "request-nat-gateway-subnet" {
  depends_on                      = [aws_internet_gateway_attachment.request-attach-ig]
  subnet_id                       = aws_subnet.request-public-sn-subnet.id
  allocation_id                   = aws_eip.request-nat-eip-subnet.allocation_id
}

resource "aws_route_table" "request-rt-public-subnet" {
  vpc_id                          = aws_vpc.request-vpc.id
}

resource "aws_route_table_association" "request-attach-rt-public-subnet" {
  route_table_id                  = aws_route_table.request-rt-public-subnet.id
  subnet_id                       = aws_subnet.request-public-sn-subnet.id
}

resource "aws_route" "request-route-public-subnet" {
  route_table_id                  = aws_route_table.request-rt-public-subnet.id
  gateway_id                      = aws_internet_gateway.request-internet-gateway.id
  destination_cidr_block          = "0.0.0.0/0"
}

# private subnet AZ1
resource "aws_subnet" "request-private-sn-subnet" {
  vpc_id                          = aws_vpc.request-vpc.id
  cidr_block                      = "10.0.2.0/24"
  availability_zone               = "eu-west-3a"
}

resource "aws_route_table" "request-rt-private-subnet" {
  vpc_id                          = aws_vpc.request-vpc.id
}

resource "aws_route_table_association" "request-attach-rt-private-subnet" {
  route_table_id                  = aws_route_table.request-rt-private-subnet.id
  subnet_id                       = aws_subnet.request-private-sn-subnet.id
}

resource "aws_route" "request-route-private-subnet" {
  route_table_id                  = aws_route_table.request-rt-private-subnet.id
  nat_gateway_id                  = aws_nat_gateway.request-nat-gateway-subnet.id
  destination_cidr_block          = "0.0.0.0/0"
}
##################

###### AWS BACKUP ######
resource "aws_kms_key" "request_vault_kms_key" {
  description                   = "KMS key used to encrypt the backup vault."
}

resource "aws_kms_alias" "request_vault_kms_key_alias" {
  name                          = "alias/request_backup_key"
  target_key_id                 = aws_kms_key.request_vault_kms_key.key_id
}

resource "aws_backup_vault" "request_backup_vault" {
  name                          = "request-backup-vault"
  kms_key_arn                   = aws_kms_key.request_vault_kms_key.arn
}

resource "aws_backup_plan" "request_backup_plan" {
  name                          = "Daily-Retention"
  rule {
    rule_name                   = "request-daily-backups"
    target_vault_name           = aws_backup_vault.request_backup_vault.name
    schedule                    = "cron(0 3 ? * * *)"
    lifecycle {
      delete_after              = 30
    }
  }
}
#######################

######### ECR #########
resource "aws_ecr_repository" "request-wordpress-ecr-repository" {
  name = "request-wordpress"
  encryption_configuration {
    encryption_type               = "AES256"
  }
}
#######################

######### ECS #########
resource "aws_ecs_cluster" "request_cluster" {
  name                          = "request_cluster"

  # Enables container insights for the cluster
  setting {
    name                        = "containerInsights"
    value                       = "enabled"
  }
}

resource "aws_ecs_task_definition" "request-wordpress-task" {
  family                          = "request-wordpress-task-definition"
  requires_compatibilities        = ["EC2"]
  task_role_arn                   = var.ecs-task-execution-role-arn
  execution_role_arn              = var.ecs-task-execution-role-arn
  network_mode                    = "awsvpc"
  container_definitions           =  jsonencode([
    {
      name                        = "request-wordpress"
      image                       = var.request-wordpress-image-uri
      cpu                         = 512
      memory                      = 1024
      logConfiguration            = {
        logDriver                 = "awslogs"
        options                   = {
          awslogs-region        = var.aws-region-name
          awslogs-create-group  = "true"
          awslogs-stream-prefix = "request-wordpress"
          awslogs-group         = "request-wordpress-container"
        }
      }
      essential               = true
      portMappings            = [
        {
          containerPort       = 80
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "request-wordpress" {
  name                        = "request-wordpress"
  cluster                     = var.cluster-id
  task_definition             = aws_ecs_task_definition.request-wordpress-task.arn
  desired_count               = 0
  enable_execute_command      = true

  capacity_provider_strategy {
    capacity_provider         = var.capacity-provider-name
    weight                    = 1
  }

  network_configuration {
    subnets                   = [aws_subnet.request-public-sn-subnet.id]
    security_groups           = [var.service-sg-id]
    assign_public_ip          = false
  }
}

resource "aws_ecs_capacity_provider" "request_common_capacity_provider" {
  name                          = "request-common-capacity-provider"
  auto_scaling_group_provider {
    auto_scaling_group_arn      = aws_autoscaling_group.ecs_common_autoscaling_group.arn
    managed_termination_protection = "DISABLED"
    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
    }
  }
}

resource "aws_autoscaling_group" "ecs_common_autoscaling_group" {
  name_prefix                   = "ECS-COMMON-AG"
  launch_configuration          = aws_launch_configuration.ecs_common_launch_configuration.name
  max_size                      = 5
  min_size                      = 0
  desired_capacity              = 0
  vpc_zone_identifier           = [aws_subnet.request-public-sn-subnet.id]
  health_check_grace_period     = 300
  health_check_type             = "EC2"
  lifecycle {
    create_before_destroy       = true
  }

  tag {
    key                         = "Name"
    propagate_at_launch         = true
    value                       = "ECS Node"
  }
  tag {
    key                         = "AmazonECSManaged"
    value                       = true
    propagate_at_launch         = true
  }
}

resource "aws_launch_configuration" "ecs_common_launch_configuration" {
  name_prefix                   = "request-common-lc"
  associate_public_ip_address   = false
  image_id                      = var.ecs-instance-ami
  instance_type                 = "t2.micro"
  key_name                      = var.key-name
  iam_instance_profile          = aws_iam_instance_profile.ecs_profile.name
  security_groups               = [aws_security_group.ec2_sg.id]
  user_data                     = "#!/bin/bash\nsudo yum update -y && echo ECS_CLUSTER=${aws_ecs_cluster.request_cluster.name} >> /etc/ecs/ecs.config"
  lifecycle {
    create_before_destroy       = true
  }
}

######### RDS #########
resource "aws_db_instance" "request-mysql" {
  lifecycle {
    ignore_changes = [password]
  }
  instance_class                = "db.t3.micro"
  engine                        = "mysql"
  engine_version                = "5.0.15"
  vpc_security_group_ids        = [var.mysql-sg-id]
  db_subnet_group_name          = aws_db_subnet_group.request-mysql-subnet-group.name
  publicly_accessible           = false
  identifier                    = "request-mysql"
  db_name                       = "request_mysql"
  allocated_storage             = 20
  backup_retention_period       = 7
  deletion_protection           = false
  backup_window                 = "02:00-03:00"
  maintenance_window            = "Sun:03:00-Sun:04:00"
  username                      = var.request-mysql-master-username
  password                      = var.request-mysql-master-password
  skip_final_snapshot           = true
}

resource "aws_db_subnet_group" "request-mysql-subnet-group" {
  subnet_ids                    = [aws_subnet.request-private-sn-subnet.id]
}
#######################
