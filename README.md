# AWS ECS Service Connect

Service discovery with CloudMap for services deployed in multiple ECS clusters.  
[Using AWS ECS Service Connect and Service Discovery Together](https://www.garretwilson.com/blog/2023/06/01/aws-ecs-service-connect-service-discovery-together)

## Public access via NLB
```shell
curl -v $(terraform output --json | jq -r ".nlb_dns_name.value")
```

## Private access via SSM session
[Configure instance permissions required for Systems Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html#instance-profile-custom-s3-policy)
```shell
aws ssm start-session --target $(terraform output --json | jq -r ".ec2_id.value") \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$(terraform output --json | jq -r ".frontend_podinfo_dns_name.value")\"], \"portNumber\":[\"9898\"], \"localPortNumber\":[\"9898\"]}"

curl -v localhost:9898
```
