output "server_ip" {
  description = "Stable public IP (Elastic IP). This is what players connect to."
  value       = aws_eip.server.public_ip
}

output "connect_address" {
  description = "Direct-connect address to paste into Palworld (Join via IP)."
  value       = "${aws_eip.server.public_ip}:8211"
}

output "instance_id" {
  description = "EC2 instance ID — used by the Discord start bot (phase 2) and for manual start/stop."
  value       = aws_instance.server.id
}

output "ssh_command" {
  description = "SSH in for admin / mod uploads."
  value       = "ssh -i secrets/${var.project_name}.pem ubuntu@${aws_eip.server.public_ip}"
}

output "ssm_session_command" {
  description = "Keyless shell via SSM Session Manager (no open SSH port needed)."
  value       = "aws ssm start-session --target ${aws_instance.server.id} --profile ${var.aws_profile} --region ${var.aws_region}"
}

output "manual_start_command" {
  description = "Start the server by hand (until the Discord bot is built)."
  value       = "aws ec2 start-instances --instance-ids ${aws_instance.server.id} --profile ${var.aws_profile} --region ${var.aws_region}"
}

output "manual_stop_command" {
  description = "Stop the server by hand."
  value       = "aws ec2 stop-instances --instance-ids ${aws_instance.server.id} --profile ${var.aws_profile} --region ${var.aws_region}"
}

output "discord_interactions_endpoint_url" {
  description = "Paste this into the Discord developer portal as the Interactions Endpoint URL."
  value       = aws_lambda_function_url.discord_bot.function_url
}

output "discord_bot_log_group" {
  description = "CloudWatch log group for the start-bot."
  value       = aws_cloudwatch_log_group.discord_bot.name
}
