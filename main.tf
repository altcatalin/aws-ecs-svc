locals {
  project = "aws-ecs-svc-${var.project_id}"

  # Predefined CloudWatch log group names to avoid circular dependency
  cloudwatch_log_group_frontend = "/${local.project}/frontend"
  cloudwatch_log_group_backend  = "/${local.project}/backend"

  user_data = <<EOF
#!/bin/bash
yum update -y
EOF
}

data "aws_caller_identity" "this" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = local.project
  cidr = "10.0.0.0/16"

  azs             = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  manage_default_security_group = true
}

module "nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.7"

  name                       = local.project
  load_balancer_type         = "network"
  enable_deletion_protection = false

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  create_security_group = true

  security_group_ingress_rules = {
    caddy = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  security_group_egress_rules = {
    caddy = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = module.vpc.vpc_cidr_block
    }
  }

  target_groups = {
    caddy = {
      port        = 80
      protocol    = "TCP"
      target_type = "ip"

      load_balancing_cross_zone_enabled = true
      create_attachment                 = false
      deregistration_delay              = 30

      health_check = {
        healthy_threshold   = 3
        unhealthy_threshold = 3
        interval            = 10
        protocol            = "TCP"
      }
    }
  }

  listeners = {
    caddy = {
      port     = 80
      protocol = "TCP"

      forward = {
        target_group_key = "caddy"
      }
    }
  }
}

# Create private DNS namespace to provide instance discovery via API calls and DNS queries in VPC
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = local.project
  vpc  = module.vpc.vpc_id
}

# Create separate service for service discovery via DNS queries in VPC
# https://www.garretwilson.com/blog/2023/06/01/aws-ecs-service-connect-service-discovery-together
resource "aws_service_discovery_service" "frontend_podinfo_dns" {
  name = "podinfo-dns"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id

    dns_records {
      ttl  = 60
      type = "A"
    }

    dns_records {
      ttl  = 60
      type = "AAAA"
    }

    dns_records {
      ttl  = 60
      type = "SRV"
    }

    routing_policy = "WEIGHTED"
  }
}

module "ecs_backend" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.11"

  cluster_name = "${local.project}-backend"

  fargate_capacity_providers = {
    FARGATE = {}
  }

  cloudwatch_log_group_name = local.cloudwatch_log_group_backend

  cluster_service_connect_defaults = {
    namespace = aws_service_discovery_private_dns_namespace.this.arn
  }

  services = {
    podinfo = {
      subnet_ids             = module.vpc.private_subnets
      enable_execute_command = true

      security_group_rules = {
        ingress = {
          type        = "ingress"
          from_port   = 9898
          to_port     = 9898
          protocol    = "tcp"
          cidr_blocks = module.vpc.private_subnets_cidr_blocks
        }

        egress = {
          type        = "egress"
          from_port   = 0
          to_port     = 0
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }

      container_definitions = {
        podinfo = {
          image = "stefanprodan/podinfo"

          essential                = true
          readonly_root_filesystem = false

          create_cloudwatch_log_group = false

          log_configuration = {
            options = {
              awslogs-group         = local.cloudwatch_log_group_backend
              awslogs-region        = var.region
              awslogs-stream-prefix = "ecs/podinfo"
            }
          }

          port_mappings = [
            {
              name          = "podinfo"
              containerPort = 9898
              hostPort      = 9898
              protocol      = "tcp"
            }
          ]
        }
      }

      service_registries = {
        registry_arn = aws_service_discovery_service.frontend_podinfo_dns.arn
        port         = 9898
      }

      service_connect_configuration = {
        service = {
          client_alias = {
            port = 9898
          }

          port_name      = "podinfo"
          discovery_name = "podinfo"
        }

        log_configuration = {
          log_driver = "awslogs"

          options = {
            awslogs-region        = var.region
            awslogs-group         = local.cloudwatch_log_group_backend
            awslogs-stream-prefix = "ecs/podinfo"
          }
        }
      }
    }
  }
}

module "ecs_frontend" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "~> 5.11"

  # Sidecar CloudMap proxy container from frontend service must start after the sidecar CloudMap proxy container from backend service
  # Might help with cross-service cross-task definition dependency, otherwise simply restart the frontend service
  # https://github.com/aws/containers-roadmap/issues/482
  depends_on = [module.ecs_backend]

  cluster_name = "${local.project}-frontend"

  fargate_capacity_providers = {
    FARGATE = {}
  }

  cloudwatch_log_group_name = local.cloudwatch_log_group_frontend

  cluster_service_connect_defaults = {
    namespace = aws_service_discovery_private_dns_namespace.this.arn
  }

  services = {
    caddy = {
      subnet_ids             = module.vpc.private_subnets
      enable_execute_command = true

      security_group_rules = {
        ingress = {
          type        = "ingress"
          from_port   = 80
          to_port     = 80
          protocol    = "tcp"
          cidr_blocks = module.vpc.public_subnets_cidr_blocks
        }

        egress = {
          type        = "egress"
          from_port   = 0
          to_port     = 0
          protocol    = "-1"
          cidr_blocks = ["0.0.0.0/0"]
        }
      }

      container_definitions = {
        caddy = {
          image = "caddy"

          essential                = true
          readonly_root_filesystem = false

          create_cloudwatch_log_group = false

          log_configuration = {
            options = {
              awslogs-group         = local.cloudwatch_log_group_frontend
              awslogs-region        = var.region
              awslogs-stream-prefix = "ecs/caddy"
            }
          }

          port_mappings = [
            {
              name          = "caddy"
              containerPort = 80
              hostPort      = 80
              protocol      = "tcp"
            }
          ]

          command = [
            "caddy",
            "reverse-proxy",
            "--from", ":80",
            "--to", "podinfo.${aws_service_discovery_private_dns_namespace.this.name}:9898",
          ]
        }
      }

      load_balancer = {
        service = {
          target_group_arn = module.nlb.target_groups["caddy"].arn
          container_name   = "caddy"
          container_port   = 80
        }
      }

      service_connect_configuration = {
        service = {
          client_alias = {
            port = 80
          }

          port_name      = "caddy"
          discovery_name = "caddy"
        }

        log_configuration = {
          log_driver = "awslogs"

          options = {
            awslogs-region        = var.region
            awslogs-group         = local.cloudwatch_log_group_frontend
            awslogs-stream-prefix = "ecs/caddy"
          }
        }
      }
    }
  }
}

module "security_group_ec2" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.1"

  name   = "${local.project}-ec2"
  vpc_id = module.vpc.vpc_id

  egress_rules = ["all-tcp"]
}

module "ec2" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.6"

  name = local.project

  # Amazon Linux 2 AMI 2.0.20240329.0 x86_64 HVM gp2
  ami                         = "ami-052e38eeff1111db1"
  monitoring                  = false
  user_data_base64            = base64encode(local.user_data)
  create_iam_instance_profile = true
  iam_role_name               = "${local.project}-ec2"

  iam_role_policies = merge({
    AmazonSSMManagedEC2InstanceDefaultPolicy = "arn:aws:iam::aws:policy/AmazonSSMManagedEC2InstanceDefaultPolicy"
    },
    (var.ssm_agent_custom_s3_policy != "" ? {
      SSMAgentS3Access = "arn:aws:iam::${data.aws_caller_identity.this.account_id}:policy/${var.ssm_agent_custom_s3_policy}"
    } : {})
  )

  subnet_id = module.vpc.private_subnets[0]

  vpc_security_group_ids = [
    module.security_group_ec2.security_group_id
  ]
}
