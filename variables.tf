variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "project_id" {
  type    = string
  default = "090e354d"
}

# https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html#instance-profile-custom-s3-policy
variable "ssm_agent_custom_s3_policy" {
  type    = string
  default = ""
}
