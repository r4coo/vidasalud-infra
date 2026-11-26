#!/usr/bin/env bash
# Publica el front Angular en S3 + CloudFront (HTTPS, necesario para MSAL/Entra con URL pública).
# Uso:  ./deploy-frontend.sh <bucket-unico> <TENANT_ID> <SPA_CLIENT_ID> <API_CLIENT_ID> <API_BASE_URL>
# Primera vez crea bucket + distribución; siguientes veces solo sube y invalida caché.
# NO fue ejecutado por quien lo generó: verifícalo en tu cuenta.
set -euo pipefail
BUCKET="${1:?bucket}"; export ENTRA_TENANT_ID="${2:?}" ENTRA_SPA_CLIENT_ID="${3:?}" ENTRA_API_CLIENT_ID="${4:?}" API_BASE_URL="${5:?}"
REGION="${AWS_REGION:-$(aws configure get region)}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

( cd "$ROOT/frontend-vidasalud" && npm install --no-audit --no-fund && npm run build )
DIST="$ROOT/frontend-vidasalud/dist/frontend-vidasalud/browser"

if ! aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  if [ "$REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$BUCKET"
  else aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --create-bucket-configuration "LocationConstraint=$REGION"; fi
  aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi
aws s3 sync "$DIST" "s3://$BUCKET" --delete

DIST_ID=$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='vidasalud-front'].Id | [0]" --output text)
if [ "$DIST_ID" = "None" ] || [ -z "$DIST_ID" ]; then
  OAC=$(aws cloudfront create-origin-access-control --origin-access-control-config \
    "Name=vidasalud-oac,SigningProtocol=sigv4,SigningBehavior=always,OriginAccessControlOriginType=s3" \
    --query OriginAccessControl.Id --output text)
  cat > /tmp/cf.json <<JSON
{
  "CallerReference": "vidasalud-$(date +%s)",
  "Comment": "vidasalud-front", "Enabled": true, "DefaultRootObject": "index.html",
  "Origins": {"Quantity": 1, "Items": [{"Id": "s3", "DomainName": "$BUCKET.s3.$REGION.amazonaws.com",
     "OriginAccessControlId": "$OAC", "S3OriginConfig": {"OriginAccessIdentity": ""}}]},
  "DefaultCacheBehavior": {"TargetOriginId": "s3", "ViewerProtocolPolicy": "redirect-to-https",
     "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6", "Compress": true,
     "AllowedMethods": {"Quantity": 2, "Items": ["GET","HEAD"]}},
  "CustomErrorResponses": {"Quantity": 2, "Items": [
     {"ErrorCode": 403, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 0},
     {"ErrorCode": 404, "ResponsePagePath": "/index.html", "ResponseCode": "200", "ErrorCachingMinTTL": 0}]}
}
JSON
  DIST_ID=$(aws cloudfront create-distribution --distribution-config file:///tmp/cf.json --query Distribution.Id --output text)
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
  cat > /tmp/policy.json <<JSON
{"Version":"2012-10-17","Statement":[{"Sid":"AllowCloudFront","Effect":"Allow","Principal":{"Service":"cloudfront.amazonaws.com"},
 "Action":"s3:GetObject","Resource":"arn:aws:s3:::$BUCKET/*",
 "Condition":{"StringEquals":{"AWS:SourceArn":"arn:aws:cloudfront::$ACCOUNT:distribution/$DIST_ID"}}}]}
JSON
  aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/policy.json
else
  aws cloudfront create-invalidation --distribution-id "$DIST_ID" --paths '/*' >/dev/null
fi
DOMAIN=$(aws cloudfront get-distribution --id "$DIST_ID" --query Distribution.DomainName --output text)
echo "Front en: https://$DOMAIN"
echo "Registra https://$DOMAIN como Redirect URI (SPA) en el registro vidasalud-spa de Entra ID y en FRONT origins del API Gateway/BFF (FRONTEND_URLS)."
