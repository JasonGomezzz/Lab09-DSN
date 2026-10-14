{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LeerOriginales",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::__BUCKET__/originales/*"
    },
    {
      "Sid": "EscribirMiniaturas",
      "Effect": "Allow",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::__BUCKET__/miniaturas/*"
    }
  ]
}
