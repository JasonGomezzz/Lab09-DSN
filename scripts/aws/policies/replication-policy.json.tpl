{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "LeerConfiguracionYListarOrigen",
      "Effect": "Allow",
      "Action": [
        "s3:GetReplicationConfiguration",
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::__BUCKET__"
    },
    {
      "Sid": "LeerVersionesDelOrigen",
      "Effect": "Allow",
      "Action": [
        "s3:GetObjectVersionForReplication",
        "s3:GetObjectVersionAcl",
        "s3:GetObjectVersionTagging"
      ],
      "Resource": "arn:aws:s3:::__BUCKET__/*"
    },
    {
      "Sid": "EscribirReplicaEnDestino",
      "Effect": "Allow",
      "Action": [
        "s3:ReplicateObject",
        "s3:ReplicateDelete",
        "s3:ReplicateTags"
      ],
      "Resource": "arn:aws:s3:::__REPLICA_BUCKET__/*"
    }
  ]
}
