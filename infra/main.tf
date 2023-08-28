##### Set up AWS configuration and role #####
#### Note: test-role should be set up in .aws/config #####

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.3"
    }
  }
}

provider "aws" {
  region  = "us-east-1"
  profile = "test-role"
}


##### Policies #####

# Lambda assumes role
resource "aws_iam_role" "lambda_role" {
  name               = "Lambda_Role"
  assume_role_policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "sts:AssumeRole",
            "Principal": {
                "Service": "lambda.amazonaws.com"
            }
        }
    ]
}
EOF
}

# Lambda permissions - so it can write and read from s3, and delete messages from queue
resource "aws_iam_policy" "iam_policy_for_lambda" {

  name        = "aws_iam_policy_for_terraform_aws_lambda_role"
  path        = "/"
  description = "AWS IAM Policy for managing aws lambda role"
  policy      = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "sqs:ReceiveMessage",
                "sqs:DeleteMessage",
                "sqs:GetQueueAttributes",
                "s3:PutObject",
                "s3:PutObjectAcl",
                "s3:GetObject",
                "s3:GetObjectAcl"
            ],
            "Resource": "*"
        }
    ]
}
EOF
}

# Permission for Lambda to be Invoked by SQS queue
resource "aws_lambda_permission" "lambda-permission" {
  statement_id  = "AllowSQSToInvokeLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.terraform_lambda_func.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_sqs_queue.s3_lambda_queue.arn
}

# SQS allows write from S3 bucket
data "aws_iam_policy_document" "allow-write-to-queue" {
  statement {
    sid    = "AllowWriteToQueue"
    effect = "Allow"

    actions = [
      "sqs:SendMessage",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = [
      "arn:aws:sqs:*:*:s3_lambda_queue"
    ]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_s3_bucket.media-cdn-test-bucket.arn]
    }

  }
}


##### Lambda #####

resource "aws_iam_role_policy_attachment" "attach_iam_policy_to_iam_role" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.iam_policy_for_lambda.arn
}

data "archive_file" "archive_lamba" {
  type        = "zip"
  source_dir  = "../src/"
  output_path = "./out/formatter.zip"
}

resource "aws_lambda_function" "terraform_lambda_func" {
  filename         = "./out/formatter.zip"
  function_name    = "Formatter_Function"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  source_code_hash = data.archive_file.archive_lamba.output_base64sha256
  depends_on       = [aws_iam_role_policy_attachment.attach_iam_policy_to_iam_role]
}



##### S3 Bucket for Testing (not Prod)  ######

resource "aws_s3_bucket" "media-cdn-test-bucket" {
  bucket = "media-cdn-test-bucket"

  tags = {
    Name = "Media Test Bucket"
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [aws_lambda_function.terraform_lambda_func]

}

resource "aws_s3_bucket_lifecycle_configuration" "bucket-config" {
  bucket = aws_s3_bucket.media-cdn-test-bucket.id

  # Clear out the test bucket after one day - we don't need to keep test data around
  rule {
    id = "media-cdn-test-bucket-retention-policy"

    filter {}

    expiration {
      days = 1
    }

    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "bucket-policies" {
  bucket = aws_s3_bucket.media-cdn-test-bucket.id
  policy = data.aws_iam_policy_document.bucket-policies.json

}

data "aws_iam_policy_document" "bucket-policies" {
  statement {
    sid    = "PreventBucketDeletion"
    effect = "Deny"

    actions = [
      "s3:DeleteBucket",
    ]


    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.media-cdn-test-bucket.arn,
      "${aws_s3_bucket.media-cdn-test-bucket.arn}/*",
    ]
  }

  statement {
    sid = "ReadAndWriteObjects"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    resources = [
      aws_s3_bucket.media-cdn-test-bucket.arn,
      "${aws_s3_bucket.media-cdn-test-bucket.arn}/*",
    ]

  }
}


##### SQS Queue #####

resource "aws_sqs_queue" "s3_lambda_queue" {
  name   = "s3_lambda_queue"
  policy = data.aws_iam_policy_document.allow-write-to-queue.json
}

resource "aws_lambda_event_source_mapping" "s3_lambda_event" {
  batch_size       = 1
  event_source_arn = aws_sqs_queue.s3_lambda_queue.arn
  enabled          = true
  function_name    = aws_lambda_function.terraform_lambda_func.arn
}

resource "aws_s3_bucket_notification" "bucket-notification" {
  bucket = aws_s3_bucket.media-cdn-test-bucket.id

  # Add event to queue for each creation
  queue {
    queue_arn = aws_sqs_queue.s3_lambda_queue.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue.s3_lambda_queue]
}
