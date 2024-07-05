output "vpc_name" {
  value = module.vpc.name
}

output "nlb_dns_name" {
  value = module.nlb.dns_name
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}
