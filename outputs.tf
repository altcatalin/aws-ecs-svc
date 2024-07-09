output "vpc_name" {
  value = module.vpc.name
}

output "nlb_dns_name" {
  value = module.nlb.dns_name
}

output "ecs_frontend_cluster_name" {
  value = module.ecs_frontend.cluster_name
}

output "ecs_backend_cluster_name" {
  value = module.ecs_backend.cluster_name
}

output "ec2_id" {
  value = module.ec2.id
}

output "frontend_podinfo_dns_name" {
  value = "${aws_service_discovery_service.frontend_podinfo_dns.name}.${aws_service_discovery_private_dns_namespace.this.name}"
}
