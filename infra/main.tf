
variable "container_port" {
  default = 8080
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "go-server-vpc-${terraform.workspace}"
  cidr = "10.0.0.0/16"

  // Double check these are valid for your region. A,B,C subnets don't exist in all regions
  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_vpn_gateway = false # to get around eip quota issue

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "go-server-vpn-${terraform.workspace}"
  }
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

resource "aws_ecs_cluster" "cluster" {
  name = "go-server-cluster-${terraform.workspace}"
}

resource "aws_ecs_cluster_capacity_providers" "cluster" {
  cluster_name       = aws_ecs_cluster.cluster.name
  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

resource "aws_ecr_repository" "ecr" {
  name                 = "go-server-app-${terraform.workspace}"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    prevent_destroy = false
    ignore_changes  = all
  }
}

locals {
  ecr_repo_url = aws_ecr_repository.ecr.repository_url
}

resource "null_resource" "container_creation" {
  triggers = {
    ecr_repo_url    = local.ecr_repo_url,
    dockerfile_hash = filesha256("${path.module}/../app/Dockerfile")
    git_tag_file    = fileexists("${path.module}/tmp/git_tag.json") ? file("${path.module}/tmp/git_tag.json") : "file_not_exist"
  }
  provisioner "local-exec" {
    command    = <<-EOT
        set -e
        # Get the Git tag
        GIT_TAG=$(git describe --tags --long --dirty 2>/dev/null || echo "no-tag")

        # Login to ECR
        aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${local.ecr_repo_url}

        # Build the Docker image with the Git tag
        docker build --platform 'linux/arm64' --build-arg PORT=${var.container_port} -t ${local.ecr_repo_url}:$GIT_TAG ../app

        # Tag the image as latest
        docker tag ${local.ecr_repo_url}:$GIT_TAG ${local.ecr_repo_url}:latest

        # Push both tagged images
        docker push ${local.ecr_repo_url}:$GIT_TAG
        docker push ${local.ecr_repo_url}:latest

        # Ensure the output directory exists
        mkdir -p ${path.module}/tmp

        # Output the Git tag for Terraform to capture
        echo "{\"git_tag\":\"$GIT_TAG\"}" > ${path.module}/tmp/git_tag.json
      EOT
    on_failure = fail
  }
}

# Capture the Git tag from the local-exec output
data "external" "git_tag" {
  program    = ["cat", "${path.module}/tmp/git_tag.json"]
  depends_on = [null_resource.container_creation]
}


resource "aws_iam_role" "task_role" {
  name = "go_server_ecs_task_role_${terraform.workspace}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "task_policy" {
  name = "go_server_ecs_task_policy_${terraform.workspace}"
  role = aws_iam_role.task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "task_execution_policy" {
  role       = aws_iam_role.task_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}


resource "aws_ecs_task_definition" "task" {
  family             = "service"
  network_mode       = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                = "256"
  memory             = "512"
  task_role_arn      = aws_iam_role.task_role.arn
  execution_role_arn = aws_iam_role.task_role.arn
  runtime_platform {
    cpu_architecture = "ARM64"
  }

  container_definitions = jsonencode([{
    name : var.container_name,
    image : "${local.ecr_repo_url}:${data.external.git_tag.result.git_tag}",
    cpu : 256,
    memory : 512,
    essential : true,
    portMappings : [{
      containerPort : var.container_port,
      hostPort : var.container_port,
      protocol : "tcp",
    }],
    logConfiguration : {
      logDriver : "awslogs",
      options : {
        awslogs-create-group : "true",
        awslogs-region : var.region,
        awslogs-stream-prefix : "ecs",
        awslogs-group : "/ecs/go-server-example-${terraform.workspace}",
      }
    },
    healthCheck : {
      command : ["CMD-SHELL", "curl -f http://localhost:8080/health || exit 1"],
      interval : 30,          # seconds between each health check
      timeout : 5,            # seconds before health check times out
      retries : 3,            # retries before the container is considered unhealthy
      startPeriod : 10        # grace period (seconds) before health checks start
    }
  }])
}

resource "aws_security_group" "alb" {
  name        = "alb-security-group-${terraform.workspace}"
  description = "Security group for ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "alb-security-group-${terraform.workspace}"
  }
}

resource "aws_lb" "alb" {
  name                       = "go-server-alb-${terraform.workspace}"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = module.vpc.public_subnets
  security_groups            = [aws_security_group.alb.id]
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "https" {
  name        = "go-server-alb-tg-${terraform.workspace}"
  port        = var.container_port
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = module.vpc.vpc_id

  health_check {
    path                = "/health"
    healthy_threshold   = 5
    unhealthy_threshold = 5
  }
}


resource "aws_cognito_user_pool" "user_pool" {
  name = "go-server-user-pool-${terraform.workspace}"
}

resource "aws_cognito_user_pool_client" "user_pool_client" {
  name         = "go-server-user-pool-client-${terraform.workspace}"
  user_pool_id = aws_cognito_user_pool.user_pool.id
  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["profile", "email", "openid"]
  callback_urls                        = ["https://${aws_lb.alb.dns_name}"]
  logout_urls                          = ["https://${aws_lb.alb.dns_name}/logout"]

  depends_on = [aws_cognito_user_pool.user_pool]
}

resource "aws_cognito_user_pool_domain" "user_pool_domain" {
  domain       = "go-server-auth-${terraform.workspace}"
  user_pool_id = aws_cognito_user_pool.user_pool.id
}

data "aws_route53_zones" "all" {}

data "aws_route53_zone" "zone" {
    zone_id = data.aws_route53_zones.all.ids[var.hosted_zone_index]
}

resource "aws_acm_certificate" "cert" {
  domain_name = "${terraform.workspace}.go-example.${data.aws_route53_zone.zone.name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Add DNS records
resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.zone.id
}

resource "aws_acm_certificate_validation" "validation" {
  certificate_arn = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "443"
  protocol          = "HTTPS"

  ssl_policy = "ELBSecurityPolicy-2016-08"
  certificate_arn = aws_acm_certificate_validation.validation.certificate_arn

  default_action {
    type = "authenticate-cognito"
    authenticate_cognito {
      user_pool_arn       = aws_cognito_user_pool.user_pool.arn
      user_pool_client_id = aws_cognito_user_pool_client.user_pool_client.id
      user_pool_domain    = aws_cognito_user_pool_domain.user_pool_domain.domain
    }
  }

  default_action {
    type = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port = 80
  protocol = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      status_code = "HTTP_301"
      protocol = "HTTPS"
      port = "443"
    }
  }
}

resource "aws_lb_listener_rule" "allow_health" {
  listener_arn = aws_lb_listener.https.arn
  priority = 50

  condition {
    path_pattern {
      values = ["/health"]
    }
  }

  action {
    type = "forward"
    target_group_arn = aws_lb_target_group.https.arn
  }
}

resource "aws_route53_record" "api" {
  name    = aws_acm_certificate.cert.domain_name
  type    = "A"
  zone_id = data.aws_route53_zone.zone.id

  alias {
    evaluate_target_health = false
    name                   = aws_lb.alb.dns_name
    zone_id                = aws_lb.alb.zone_id
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "ecs-tasks-sg-${terraform.workspace}"
  description = "Security group for ECS tasks"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Ingress from ALB"
    from_port       = var.container_port
    to_port         = var.container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-tasks-sg-${terraform.workspace}"
  }
}

resource "aws_ecs_service" "cluster" {
  name            = "go-server-app-${terraform.workspace}"
  cluster         = aws_ecs_cluster.cluster.id
  task_definition = aws_ecs_task_definition.task.arn
  desired_count   = 1

  depends_on = [aws_lb_listener.http, aws_lb_listener.https]

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 100
    base              = 1
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.https.arn
    container_name = var.container_name
    container_port = var.container_port
  }
}

output "domain" {
  value = aws_acm_certificate.cert.domain_name
}
