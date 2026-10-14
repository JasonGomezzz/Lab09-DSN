{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EtiquetasDeObjetos",
      "Effect": "Allow",
      "Action": [
        "s3:PutObjectTagging",
        "s3:GetObjectTagging"
      ],
      "Resource": "arn:aws:s3:::__BUCKET__/*"
    }
  ]
}
