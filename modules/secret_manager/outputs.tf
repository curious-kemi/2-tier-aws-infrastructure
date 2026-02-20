

output "database_secret_id"{
    description = "ARN of the VotingApp database secret"
    value = aws_secretsmanager_secret.database_cred.arn

}

output "kms_key" {
    value = aws_kms_key.db_cmk.arn
}

output "secret_arn" {
    value = aws_secretsmanager_secret.database_cred.arn
}