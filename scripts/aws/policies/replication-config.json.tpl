{
  "Role": "arn:aws:iam::__ACCOUNT_ID__:role/__REPLICATION_ROLE__",
  "Rules": [
    {
      "ID": "replicar-originales",
      "Priority": 1,
      "Status": "Enabled",
      "Filter": {
        "Prefix": "originales/"
      },
      "DeleteMarkerReplication": {
        "Status": "Disabled"
      },
      "Destination": {
        "Bucket": "arn:aws:s3:::__REPLICA_BUCKET__",
        "StorageClass": "STANDARD"
      }
    }
  ]
}
