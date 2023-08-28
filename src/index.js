const { ListObjectsV2Command, GetObjectCommand, PutObjectCommand, S3Client } = require("@aws-sdk/client-s3");

exports.handler = async (event, context) => {
    console.log('Received event:', JSON.stringify(event, null, 2));

    let contents = await list_bucket_contents().await;

    console.log('Bucket contents event:', JSON.stringify(contents, null, 2));

    return event; // The event we get from the SQS
};

let client = new S3Client({
    region: 'us-east-1',
    credentials: {
        // change to a secret store arn
        accessKeyId: '<Access Key Id>',
        secretAccessKey: '<Access Key>'
    }
});

async function put_to_s3() {

    const params = new PutObjectCommand({
        Bucket: "media-cdn-test-bucket",
        Key: "hello-s3.txt",
        Body: "Hello S3!",
    });

    try {
        const response = await client.send(params);
        console.log(response);
    } catch (err) {
        console.error(err);
    }
}

async function get_from_s3() {

    const params = new GetObjectCommand({
        Bucket: "media-cdn-test-bucket",
        Key: "hello-s3.txt"
    });

    try {
        const response = await client.send(params);
        console.log(response.Body);
        return response;

    } catch (err) {
        console.error(err);
    }
}

async function list_bucket_contents() {
    const params = {
        Bucket: "media-cdn-test-bucket",
        // The default and maximum number of keys returned is 1000
        MaxKeys: 1000,
    };

    try {
        let cycle = true;
        const keys = [];
        while (cycle) {
            const data = await client.send(new ListObjectsV2Command(params));
            const { Contents, IsTruncated, NextContinuationToken } = data;
            if (Contents) {
                Contents.forEach((item) => {
                    keys.push(item.Key);
                });
            }
            if (!IsTruncated || !NextContinuationToken) {
                cycle = false;
            }
            params.ContinuationToken = NextContinuationToken;
        }
        return keys;

    } catch (err) {
        console.error(err);
    }
}
