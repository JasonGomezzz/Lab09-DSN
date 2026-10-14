{
  "LambdaFunctionConfigurations": [
    {
      "Id": "miniaturas-de-originales",
      "LambdaFunctionArn": "arn:aws:lambda:__AWS_REGION__:__ACCOUNT_ID__:function:__LAMBDA_NAME__",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {
              "Name": "prefix",
              "Value": "originales/"
            }
          ]
        }
      }
    }
  ]
}
